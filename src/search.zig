const std = @import("std");
const TextBuffer = @import("text_buffer.zig");
const Edit = @import("edit.zig");

/// Search for a pattern in the buffer (correctly handling piece boundaries)
pub fn search(buffer: *TextBuffer, pattern: []const u8) !std.ArrayList(usize) {
    var results: std.ArrayList(usize) = .empty;
    if (pattern.len == 0) return results;
    const len = buffer.length();
    if (len < pattern.len) return results;

    var global_offset: usize = 0;

    for (buffer.pieces.items) |piece| {
        const buf = if (piece.buffer == .original) buffer.original_buffer.items else buffer.add_buffer.items;
        const piece_slice = buf[piece.start .. piece.start + piece.length];

        // 1. Fast search within the piece
        // We can only find matches that are fully contained in this piece.
        if (piece.length >= pattern.len) {
            var local_offset: usize = 0;
            while (std.mem.indexOfPos(u8, piece_slice, local_offset, pattern)) |match_idx| {
                try results.append(buffer.allocator, global_offset + match_idx);
                local_offset = match_idx + 1;
            }
        }

        // 2. Check boundary matches
        // A match could start near the end of this piece and cross into the next.
        // We need to check positions starting from `max(0, piece.length - pattern.len + 1)`
        // up to `piece.length - 1`.
        const boundary_start_local = if (piece.length > pattern.len) piece.length - pattern.len + 1 else 0;

        var k: usize = boundary_start_local;
        while (k < piece.length) : (k += 1) {
            const check_pos = global_offset + k;
            // Don't go out of bounds of the whole buffer
            if (check_pos + pattern.len > len) break;

            // We already checked fully contained matches in step 1, so we can skip them here?
            // Actually, step 1 finds ALL matches fully contained.
            // So here we only care if the match *actually crosses* the boundary.
            // But it's simpler to just check everything in this small strip.
            // Duplicate detection: if `k + pattern.len <= piece.length`, it was covered by step 1.
            if (k + pattern.len <= piece.length) {
                continue;
            }

            var match = true;
            var j: usize = 0;
            while (j < pattern.len) : (j += 1) {
                if (buffer.charAt(check_pos + j) != pattern[j]) {
                    match = false;
                    break;
                }
            }
            if (match) {
                try results.append(buffer.allocator, check_pos);
            }
        }

        global_offset += piece.length;
    }

    return results;
}

pub fn replace(buffer: *TextBuffer, start: usize, end: usize, text: []const u8) !void {
    if (try buffer.delete(start, end)) |edit_ptr| {
        edit_ptr.deinit(buffer.allocator);
        buffer.allocator.destroy(edit_ptr);
    }
    if (try buffer.insert(start, text)) |edit_ptr| {
        edit_ptr.deinit(buffer.allocator);
        buffer.allocator.destroy(edit_ptr);
    }
}

const Piece = @import("piece.zig");

pub fn replaceAll(buffer: *TextBuffer, pattern: []const u8, replacement: []const u8) !void {
    var matches = try search(buffer, pattern);
    defer matches.deinit(buffer.allocator);

    if (matches.items.len == 0) return;

    // Prepare new pieces list
    var new_pieces: std.ArrayList(Piece) = .empty;
    errdefer new_pieces.deinit(buffer.allocator);

    // Add replacement text to add_buffer once
    const replacement_start = buffer.add_buffer.items.len;
    try buffer.add_buffer.appendSlice(buffer.allocator, replacement);
    const replacement_piece = Piece{
        .buffer = .add,
        .start = replacement_start,
        .length = replacement.len,
    };

    var source_piece_idx: usize = 0;
    var source_piece_offset: usize = 0; // Global offset where source_piece starts
    var last_copied_pos: usize = 0;

    for (matches.items) |match_pos| {
        // 1. Copy gap [last_copied_pos, match_pos)
        var len_to_copy = match_pos - last_copied_pos;

        while (len_to_copy > 0) {
            if (source_piece_idx >= buffer.pieces.items.len) break; // Should not happen if logic is correct

            const p = buffer.pieces.items[source_piece_idx];
            const offset_in_piece = last_copied_pos - source_piece_offset;

            // If last_copied_pos is beyond this piece, move to next
            if (offset_in_piece >= p.length) {
                source_piece_offset += p.length;
                source_piece_idx += 1;
                continue;
            }

            const available = p.length - offset_in_piece;
            const take = @min(len_to_copy, available);

            try new_pieces.append(buffer.allocator, Piece{
                .buffer = p.buffer,
                .start = p.start + offset_in_piece,
                .length = take,
            });

            len_to_copy -= take;
            last_copied_pos += take;
        }

        // 2. Add replacement
        try new_pieces.append(buffer.allocator, replacement_piece);

        // 3. Skip pattern in source
        last_copied_pos += pattern.len;
    }

    // 4. Copy remaining tail
    const total_len = buffer.length();
    var len_to_copy = total_len - last_copied_pos;

    while (len_to_copy > 0) {
        if (source_piece_idx >= buffer.pieces.items.len) break;

        const p = buffer.pieces.items[source_piece_idx];
        // Ensure we are pointing to the right place in the current piece
        // We might need to advance source_piece_idx if last_copied_pos jumped far ahead (due to pattern skip)
        if (source_piece_offset + p.length <= last_copied_pos) {
            source_piece_offset += p.length;
            source_piece_idx += 1;
            continue;
        }

        const offset_in_piece = last_copied_pos - source_piece_offset;
        const available = p.length - offset_in_piece;
        const take = @min(len_to_copy, available);

        try new_pieces.append(buffer.allocator, Piece{
            .buffer = p.buffer,
            .start = p.start + offset_in_piece,
            .length = take,
        });

        len_to_copy -= take;
        last_copied_pos += take;
    }

    // Swap pieces
    buffer.pieces.deinit(buffer.allocator);
    buffer.pieces = new_pieces;

    // Invalidate cache
    buffer.cached_piece_idx = 0;
    buffer.cached_piece_offset = 0;
}
