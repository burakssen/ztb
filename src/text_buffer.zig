const std = @import("std");

const Piece = @import("piece.zig");
const Edit = @import("edit.zig");
const LineCol = @import("line_col.zig");

/// High-performance text buffer using Piece Table data structure
const TextBuffer = @This();

allocator: std.mem.Allocator,
original_buffer: std.ArrayList(u8), // Original file content (immutable)
add_buffer: std.ArrayList(u8), // All additions go here
pieces: std.ArrayList(Piece), // Piece table describing document structure

pub fn init(allocator: std.mem.Allocator) TextBuffer {
    return .{
        .allocator = allocator,
        .original_buffer = .empty,
        .add_buffer = .empty,
        .pieces = .empty,
    };
}

pub fn deinit(self: *TextBuffer) void {
    self.original_buffer.deinit(self.allocator);
    self.add_buffer.deinit(self.allocator);
    self.pieces.deinit(self.allocator);
}

fn findPieceIndexAt(self: *const TextBuffer, pos: usize) struct { index: usize, offset: usize, found: bool } {
    var offset: usize = 0;
    for (self.pieces.items, 0..) |piece, i| {
        if (offset + piece.length > pos) {
            return .{ .index = i, .offset = offset, .found = true };
        }
        offset += piece.length;
    }
    return .{ .index = self.pieces.items.len, .offset = offset, .found = false };
}

/// Insert text at a specific position
pub fn insert(self: *TextBuffer, pos: usize, text: []const u8) !?*Edit {
    if (text.len == 0) return null;

    const add_start = self.add_buffer.items.len;
    try self.add_buffer.appendSlice(self.allocator, text);

    const new_piece = Piece{
        .buffer = .add,
        .start = add_start,
        .length = text.len,
    };

    var edit_ptr = try self.allocator.create(Edit); // Allocate Edit on heap
    edit_ptr.* = Edit{
        .cursor = pos,
        .start_piece_index = 0,
        .old_pieces = .empty,
        .new_pieces = .empty,
    };

    // If an error occurs during the operation, ensure the allocated Edit and its internal ArrayLists are deinitialized.
    // This errdefer will only catch errors between here and the return.
    // If the return is successful, the caller takes ownership.
    errdefer {
        edit_ptr.deinit(self.allocator);
        self.allocator.destroy(edit_ptr);
    }

    const loc = self.findPieceIndexAt(pos);

    if (!loc.found or pos == loc.offset + self.pieces.items[loc.index].length) {
        // Insert at piece boundary
        const insert_idx = if (!loc.found) self.pieces.items.len else loc.index + 1;

        try self.pieces.insert(self.allocator, insert_idx, new_piece);

        try edit_ptr.new_pieces.append(self.allocator, new_piece);
        edit_ptr.start_piece_index = insert_idx;
    } else {
        // Split piece
        const piece_idx = loc.index;
        const piece = self.pieces.items[piece_idx];
        const split_offset = pos - loc.offset;

        try edit_ptr.old_pieces.append(self.allocator, piece);

        const left = Piece{ .buffer = piece.buffer, .start = piece.start, .length = split_offset };
        const right = Piece{ .buffer = piece.buffer, .start = piece.start + split_offset, .length = piece.length - split_offset };

        try edit_ptr.new_pieces.append(self.allocator, left);
        try edit_ptr.new_pieces.append(self.allocator, new_piece);
        try edit_ptr.new_pieces.append(self.allocator, right);

        edit_ptr.start_piece_index = piece_idx;

        self.pieces.items[piece_idx] = left;
        try self.pieces.insert(self.allocator, piece_idx + 1, new_piece);
        try self.pieces.insert(self.allocator, piece_idx + 2, right);
    }

    return edit_ptr;
}

/// Delete text from start to end position
pub fn delete(self: *TextBuffer, start: usize, end: usize) !?*Edit {
    if (start >= end) return null;

    var edit_ptr = try self.allocator.create(Edit); // Allocate Edit on heap
    edit_ptr.* = Edit{
        .cursor = start,
        .start_piece_index = 0, // This will be set below
        .old_pieces = .empty,
        .new_pieces = .empty,
    };

    errdefer {
        edit_ptr.deinit(self.allocator);
        self.allocator.destroy(edit_ptr);
    }

    var offset: usize = 0;
    var i: usize = 0;
    var start_piece_idx: ?usize = null;
    var pieces_to_remove_count: usize = 0;

    while (i < self.pieces.items.len) {
        const piece = self.pieces.items[i];
        const piece_start = offset;
        const piece_end = offset + piece.length;

        if (piece_end <= start) {
            offset += piece.length;
            i += 1;
            continue;
        }
        if (piece_start >= end) {
            break;
        }

        if (start_piece_idx == null) start_piece_idx = i;

        try edit_ptr.old_pieces.append(self.allocator, piece);
        pieces_to_remove_count += 1;

        if (piece_start < start) {
            try edit_ptr.new_pieces.append(self.allocator, .{
                .buffer = piece.buffer,
                .start = piece.start,
                .length = start - piece_start,
            });
        }

        if (piece_start < start and piece_end > end) {
            // Middle deletion, we need the right part too
            const right_start = end - piece_start;
            try edit_ptr.new_pieces.append(self.allocator, .{
                .buffer = piece.buffer,
                .start = piece.start + right_start,
                .length = piece_end - end,
            });
        } else if (piece_end > end) {
            // Trim start of piece (keep end)
            const trim = end - piece_start;
            try edit_ptr.new_pieces.append(self.allocator, .{
                .buffer = piece.buffer,
                .start = piece.start + trim,
                .length = piece.length - trim,
            });
        }

        offset += piece.length;
        i += 1;
    }

    if (start_piece_idx) |idx| {
        var r: usize = 0;
        while (r < pieces_to_remove_count) : (r += 1) {
            _ = self.pieces.orderedRemove(idx);
        }

        try self.pieces.insertSlice(self.allocator, idx, edit_ptr.new_pieces.items);
        edit_ptr.start_piece_index = idx;

        return edit_ptr;
    } else {
        // If no pieces were actually removed, deinit the temporary ArrayLists
        edit_ptr.deinit(self.allocator);
        self.allocator.destroy(edit_ptr);
        return null;
    }
}

/// Get the total length of the document
pub fn length(self: *const TextBuffer) usize {
    var total: usize = 0;
    for (self.pieces.items) |piece| total += piece.length;
    return total;
}

/// Get character at position
pub fn charAt(self: *const TextBuffer, pos: usize) ?u8 {
    const loc = self.findPieceIndexAt(pos);
    if (!loc.found) return null;

    const piece = self.pieces.items[loc.index];
    const local_pos = pos - loc.offset;
    const buffer = if (piece.buffer == .original) self.original_buffer.items else self.add_buffer.items;
    return buffer[piece.start + local_pos];
}

/// Get a slice of text (allocates)
pub fn getText(self: *const TextBuffer, start: usize, end: usize) ![]u8 {
    if (start >= end) return try self.allocator.alloc(u8, 0);
    var result = try self.allocator.alloc(u8, end - start);
    var result_idx: usize = 0;
    var offset: usize = 0;

    for (self.pieces.items) |piece| {
        const piece_start = offset;
        const piece_end = offset + piece.length;

        if (piece_end <= start or piece_start >= end) {
            offset += piece.length;
            continue;
        }

        const buffer = if (piece.buffer == .original) self.original_buffer.items else self.add_buffer.items;
        const copy_start = if (piece_start < start) start - piece_start else 0;
        const copy_end = if (piece_end > end) end - piece_start else piece.length;
        const copy_len = copy_end - copy_start;

        @memcpy(result[result_idx .. result_idx + copy_len], buffer[piece.start + copy_start .. piece.start + copy_end]);
        result_idx += copy_len;
        offset += piece.length;
    }
    return result;
}

/// Get line and column from offset
pub fn getLineCol(self: *const TextBuffer, pos: usize) !LineCol {
    if (pos > self.length()) return error.OutOfBounds;

    var current_line: usize = 0;
    var current_col: usize = 0;
    var offset: usize = 0;

    for (self.pieces.items) |piece| {
        const buffer = if (piece.buffer == .original) self.original_buffer.items else self.add_buffer.items;
        const piece_len = piece.length;

        // If pos is beyond this piece
        if (offset + piece_len < pos) {
            const slice = buffer[piece.start .. piece.start + piece_len];
            for (slice) |c| {
                if (c == '\n') {
                    current_line += 1;
                    current_col = 0;
                } else {
                    current_col += 1;
                }
            }
            offset += piece_len;
            continue;
        }

        // Pos is in this piece (or at end of it)
        const target_in_piece = pos - offset;
        const slice = buffer[piece.start .. piece.start + target_in_piece];
        for (slice) |c| {
            if (c == '\n') {
                current_line += 1;
                current_col = 0;
            } else {
                current_col += 1;
            }
        }
        return LineCol{ .line = current_line, .col = current_col };
    }
    if (pos == 0 and self.pieces.items.len == 0) return LineCol{ .line = 0, .col = 0 };
    return LineCol{ .line = current_line, .col = current_col };
}

/// Get offset from line and column
pub fn getOffset(self: *const TextBuffer, line: usize, col: usize) !usize {
    var current_line: usize = 0;
    var current_col: usize = 0;
    var offset: usize = 0;

    for (self.pieces.items) |piece| {
        const buffer = if (piece.buffer == .original) self.original_buffer.items else self.add_buffer.items;
        const slice = buffer[piece.start .. piece.start + piece.length];

        for (slice, 0..) |c, i| {
            if (current_line == line and current_col == col) {
                return offset + i;
            }
            if (c == '\n') {
                current_line += 1;
                current_col = 0;
            } else {
                current_col += 1;
            }
        }
        offset += piece.length;
    }

    if (current_line == line and current_col == col) {
        return offset;
    }

    return error.OutOfBounds;
}

/// Get entire buffer content as string (allocates)
pub fn toString(self: *const TextBuffer) ![]u8 {
    return try self.getText(0, self.length());
}
