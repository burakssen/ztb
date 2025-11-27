const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Piece = @import("piece.zig");

const Edit = @This();

cursor: usize,
start_piece_index: usize,
old_pieces: ArrayList(Piece),
new_pieces: ArrayList(Piece),

pub fn deinit(self: *Edit, allocator: Allocator) void {
    self.old_pieces.deinit(allocator);
    self.new_pieces.deinit(allocator);
}
