const std = @import("std");

pub const BufferType = enum {
    original,
    add,
};

pub const Piece = struct {
    buffer_type: BufferType,
    start: usize,
    length: usize,
};

pub const Cursor = struct {
    anchor: usize,
    head: usize,

    pub fn init(offset: usize) Cursor {
        return .{
            .anchor = offset,
            .head = offset,
        };
    }

    pub fn initSelection(anchor: usize, head: usize) Cursor {
        return .{
            .anchor = anchor,
            .head = head,
        };
    }

    pub fn hasSelection(self: Cursor) bool {
        return self.anchor != self.head;
    }

    pub fn start(self: Cursor) usize {
        return @min(self.anchor, self.head);
    }

    pub fn end(self: Cursor) usize {
        return @max(self.anchor, self.head);
    }
};

pub const Edit = struct {
    cursor: usize,
    start_piece_index: usize,
    old_pieces: std.ArrayList(Piece),
    new_pieces: std.ArrayList(Piece),

    pub fn deinit(self: *Edit, allocator: std.mem.Allocator) void {
        self.old_pieces.deinit(allocator);
        self.new_pieces.deinit(allocator);
    }
};

pub const LineCol = struct {
    line: usize,
    col: usize,
};
