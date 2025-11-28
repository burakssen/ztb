const std = @import("std");

const types = @import("types.zig");
const Piece = types.Piece;
const Edit = types.Edit;
const LineCol = types.LineCol;

const Buffer = @This();

allocator: std.mem.Allocator,
original_buffer: std.ArrayList(u8),
add_buffer: std.ArrayList(u8),
pieces: std.ArrayList(Piece),

cached_piece_idx: usize,
cached_piece_offset: usize,

pub fn init(allocator: std.mem.Allocator) Buffer {
    return .{
        .allocator = allocator,
        .original_buffer = .empty,
        .add_buffer = .empty,
        .pieces = .empty,
        .cached_piece_idx = 0,
        .cached_piece_offset = 0,
    };
}

pub fn deinit(self: *Buffer) void {
    self.original_buffer.deinit(self.allocator);
    self.add_buffer.deinit(self.allocator);
    self.pieces.deinit(self.allocator);
}

/// Load initial content into the buffer (treated as original/immutable)
/// This should typically be called immediately after init.
pub fn load(self: *Buffer, content: []const u8) !void {
    // Ensure we start clean if this is called
    self.original_buffer.clearRetainingCapacity();
    self.add_buffer.clearRetainingCapacity();
    self.pieces.clearRetainingCapacity();

    try self.original_buffer.appendSlice(self.allocator, content);
    if (content.len > 0) {
        try self.pieces.append(self.allocator, .{
            .buffer_type = .original,
            .start = 0,
            .length = content.len,
        });
    }

    self.cached_piece_idx = 0;
    self.cached_piece_offset = 0;
}

fn findPieceIndexAt(self: *Buffer, pos: usize) struct { index: usize, offset: usize, found: bool } {
    var offset: usize = 0;
    var start_idx: usize = 0;

    // Use cache if valid and useful
    if (pos >= self.cached_piece_offset and self.cached_piece_idx < self.pieces.items.len) {
        offset = self.cached_piece_offset;
        start_idx = self.cached_piece_idx;
    }

    for (self.pieces.items[start_idx..], 0..) |piece, i| {
        const actual_idx = start_idx + i;
        if (offset + piece.length > pos) {
            // Update cache
            self.cached_piece_idx = actual_idx;
            self.cached_piece_offset = offset;
            return . { .index = actual_idx, .offset = offset, .found = true };
        }
        offset += piece.length;
    }
    return . { .index = self.pieces.items.len, .offset = offset, .found = false };
}

/// Insert text at a specific position
pub fn insert(self: *Buffer, lc: LineCol, text: []const u8) !?*Edit {
    const pos = try self.getOffset(lc.line, lc.col);
    if (text.len == 0) return null;

    const add_start = self.add_buffer.items.len;
    try self.add_buffer.appendSlice(self.allocator, text);

    const new_piece = Piece{
        .buffer_type = .add,
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

    // Invalidate cache on modification
    self.cached_piece_idx = 0;
    self.cached_piece_offset = 0;

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

        const left = Piece{ .buffer_type = piece.buffer_type, .start = piece.start, .length = split_offset };
        const right = Piece{ .buffer_type = piece.buffer_type, .start = piece.start + split_offset, .length = piece.length - split_offset };

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
pub fn delete(self: *Buffer, lc_start: LineCol, lc_end: LineCol) !?*Edit {
    const start = try self.getOffset(lc_start.line, lc_start.col);
    const end = try self.getOffset(lc_end.line, lc_end.col);
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

    // Invalidate cache on modification
    self.cached_piece_idx = 0;
    self.cached_piece_offset = 0;

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
                .buffer_type = piece.buffer_type,
                .start = piece.start,
                .length = start - piece_start,
            });
        }

        if (piece_start < start and piece_end > end) {
            // Middle deletion, we need the right part too
            const right_start = end - piece_start;
            try edit_ptr.new_pieces.append(self.allocator, .{
                .buffer_type = piece.buffer_type,
                .start = piece.start + right_start,
                .length = piece_end - end,
            });
        } else if (piece_end > end) {
            // Trim start of piece (keep end)
            const trim = end - piece_start;
            try edit_ptr.new_pieces.append(self.allocator, .{
                .buffer_type = piece.buffer_type,
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
pub fn length(self: *const Buffer) usize {
    var total: usize = 0;
    for (self.pieces.items) |piece| total += piece.length;
    return total;
}

/// Get character at position
pub fn charAt(self: *Buffer, pos: usize) ?u8 {
    const loc = self.findPieceIndexAt(pos);
    if (!loc.found) return null;

    const piece = self.pieces.items[loc.index];
    const local_pos = pos - loc.offset;
    const buffer = if (piece.buffer_type == .original) self.original_buffer.items else self.add_buffer.items;
    return buffer[piece.start + local_pos];
}

/// Get a slice of text (allocates)
pub fn getText(self: *const Buffer, start: usize, end: usize) ![]u8 {
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

        const buffer = if (piece.buffer_type == .original) self.original_buffer.items else self.add_buffer.items;
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
pub fn getLineCol(self: *const Buffer, pos: usize) !LineCol {
    if (pos > self.length()) return error.OutOfBounds;

    var current_line: usize = 0;
    var current_col: usize = 0;
    var offset: usize = 0;

    for (self.pieces.items) |piece| {
        const buffer = if (piece.buffer_type == .original) self.original_buffer.items else self.add_buffer.items;
        const piece_len = piece.length;

        // If pos is beyond this piece
        if (offset + piece_len < pos) {
            const slice = buffer[piece.start .. piece.start + piece_len];
            const newlines = std.mem.count(u8, slice, "\n");
            if (newlines > 0) {
                current_line += newlines;
                const last_nl = std.mem.lastIndexOfScalar(u8, slice, '\n').?;
                current_col = slice.len - 1 - last_nl;
            } else {
                current_col += slice.len;
            }
            offset += piece_len;
            continue;
        }

        // Pos is in this piece (or at end of it)
        const target_in_piece = pos - offset;
        const slice = buffer[piece.start .. piece.start + target_in_piece];
        const newlines = std.mem.count(u8, slice, "\n");
        if (newlines > 0) {
            current_line += newlines;
            const last_nl = std.mem.lastIndexOfScalar(u8, slice, '\n').?;
            current_col = slice.len - 1 - last_nl;
        } else {
            current_col += slice.len;
        }
        return LineCol{ .line = current_line, .col = current_col };
    }
    if (pos == 0 and self.pieces.items.len == 0) return LineCol{ .line = 0, .col = 0 };
    return LineCol{ .line = current_line, .col = current_col };
}

/// Get offset from line and column
pub fn getOffset(self: *const Buffer, line: usize, col: usize) !usize {
    var current_line: usize = 0;
    var current_col: usize = 0;
    var offset: usize = 0;

    for (self.pieces.items) |piece| {
        const buffer = if (piece.buffer_type == .original) self.original_buffer.items else self.add_buffer.items;
        const slice = buffer[piece.start .. piece.start + piece.length];

        // Optimization: Check if target line is even in this piece
        const newlines_in_piece = std.mem.count(u8, slice, "\n");
        if (current_line + newlines_in_piece < line) {
            current_line += newlines_in_piece;
            if (newlines_in_piece > 0) {
                const last_nl = std.mem.lastIndexOfScalar(u8, slice, '\n').?;
                current_col = slice.len - 1 - last_nl;
            } else {
                current_col += slice.len;
            }
            offset += piece.length;
            continue;
        }

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
pub fn toString(self: *const Buffer) ![]u8 {
    return try self.getText(0, self.length());
}

test "Buffer: init and deinit" {
    const allocator = std.testing.allocator;
    var buffer = Buffer.init(allocator);
    defer buffer.deinit();

    try std.testing.expectEqual(@as(usize, 0), buffer.length());
}

test "Buffer: load" {
    const allocator = std.testing.allocator;
    var buffer = Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.load("Hello World");
    try std.testing.expectEqual(@as(usize, 11), buffer.length());

    const content = try buffer.toString();
    defer allocator.free(content);
    try std.testing.expectEqualStrings("Hello World", content);
}

test "Buffer: insert" {
    const allocator = std.testing.allocator;
    var buffer = Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.load("Hello");

    // Insert at end
    if (try buffer.insert(LineCol{.line = 0, .col = 5}, " World")) |edit| {
        edit.deinit(allocator);
        allocator.destroy(edit);
    }
    {
        const content = try buffer.toString();
        defer allocator.free(content);
        try std.testing.expectEqualStrings("Hello World", content);
    }

    // Insert in middle
    if (try buffer.insert(LineCol{.line = 0, .col = 5}, ",")) |edit| {
        edit.deinit(allocator);
        allocator.destroy(edit);
    }
    {
        const content = try buffer.toString();
        defer allocator.free(content);
        try std.testing.expectEqualStrings("Hello, World", content);
    }

    // Insert at start
    if (try buffer.insert(LineCol{.line = 0, .col = 0}, "> ")) |edit| {
        edit.deinit(allocator);
        allocator.destroy(edit);
    }
    {
        const content = try buffer.toString();
        defer allocator.free(content);
        try std.testing.expectEqualStrings("> Hello, World", content);
    }
}

test "Buffer: delete" {
    const allocator = std.testing.allocator;
    var buffer = Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.load("Hello, World");

    // Delete ", "
    if (try buffer.delete(LineCol{.line = 0, .col = 5}, LineCol{.line = 0, .col = 7})) |edit| {
        edit.deinit(allocator);
        allocator.destroy(edit);
    }
    {
        const content = try buffer.toString();
        defer allocator.free(content);
        try std.testing.expectEqualStrings("HelloWorld", content);
    }

    // Delete start
    if (try buffer.delete(LineCol{.line = 0, .col = 0}, LineCol{.line = 0, .col = 5})) |edit| {
        edit.deinit(allocator);
        allocator.destroy(edit);
    }
    {
        const content = try buffer.toString();
        defer allocator.free(content);
        try std.testing.expectEqualStrings("World", content);
    }

    // Delete end
    if (try buffer.delete(LineCol{.line = 0, .col = 3}, LineCol{.line = 0, .col = 5})) |edit| {
        edit.deinit(allocator);
        allocator.destroy(edit);
    }
    {
        const content = try buffer.toString();
        defer allocator.free(content);
        try std.testing.expectEqualStrings("Wor", content);
    }
}

test "Buffer: charAt" {
    const allocator = std.testing.allocator;
    var buffer = Buffer.init(allocator);
    defer buffer.deinit();
    try buffer.load("ABC");

    try std.testing.expectEqual(@as(?u8, 'A'), buffer.charAt(0));
    try std.testing.expectEqual(@as(?u8, 'B'), buffer.charAt(1));
    try std.testing.expectEqual(@as(?u8, 'C'), buffer.charAt(2));
    try std.testing.expectEqual(@as(?u8, null), buffer.charAt(3));
}

test "Buffer: getText" {
    const allocator = std.testing.allocator;
    var buffer = Buffer.init(allocator);
    defer buffer.deinit();
    try buffer.load("0123456789");

    const slice = try buffer.getText(3, 7);
    defer allocator.free(slice);
    try std.testing.expectEqualStrings("3456", slice);
}

test "Buffer: getLineCol and getOffset" {
    const allocator = std.testing.allocator;
    var buffer = Buffer.init(allocator);
    defer buffer.deinit();
    try buffer.load("Hello\nWorld\n!");

    // 012345 678901 2
    // Hello\n World\n !

    // 'H' -> 0,0
    var lc = try buffer.getLineCol(0);
    try std.testing.expectEqual(LineCol{ .line = 0, .col = 0 }, lc);
    try std.testing.expectEqual(@as(usize, 0), try buffer.getOffset(0, 0));

    // '\n' after Hello -> 0,5
    lc = try buffer.getLineCol(5);
    try std.testing.expectEqual(LineCol{ .line = 0, .col = 5 }, lc);
    try std.testing.expectEqual(@as(usize, 5), try buffer.getOffset(0, 5));

    // 'W' -> 1,0 (offset 6)
    lc = try buffer.getLineCol(6);
    try std.testing.expectEqual(LineCol{ .line = 1, .col = 0 }, lc);
    try std.testing.expectEqual(@as(usize, 6), try buffer.getOffset(1, 0));

    // '!' -> 2,0 (offset 12)
    lc = try buffer.getLineCol(12);
    try std.testing.expectEqual(LineCol{ .line = 2, .col = 0 }, lc);
    try std.testing.expectEqual(@as(usize, 12), try buffer.getOffset(2, 0));
}