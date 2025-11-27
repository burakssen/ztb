const std = @import("std");

const Edit = @import("edit.zig");
const TextBuffer = @import("text_buffer.zig");
const Piece = @import("piece.zig");

const History = @This();

allocator: std.mem.Allocator,
undo_stack: std.ArrayList(*Edit), // Changed to pointer
redo_stack: std.ArrayList(*Edit), // Changed to pointer

pub fn init(allocator: std.mem.Allocator) History {
    return .{
        .allocator = allocator,
        .undo_stack = .empty,
        .redo_stack = .empty,
    };
}

pub fn deinit(self: *History) void {
    for (self.undo_stack.items) |edit_ptr| { // Loop through pointers
        edit_ptr.deinit(self.allocator);
        self.allocator.destroy(edit_ptr); // Destroy the Edit struct itself
    }
    self.undo_stack.deinit(self.allocator); // Deinit the ArrayList

    for (self.redo_stack.items) |edit_ptr| { // Loop through pointers
        edit_ptr.deinit(self.allocator);
        self.allocator.destroy(edit_ptr); // Destroy the Edit struct itself
    }
    self.redo_stack.deinit(self.allocator); // Deinit the ArrayList
}

pub fn recordEdit(self: *History, edit_ptr: *Edit) !void { // Accepts pointer
    self.clearRedoStack();
    try self.undo_stack.append(self.allocator, edit_ptr);
}

fn clearRedoStack(self: *History) void {
    for (self.redo_stack.items) |edit_ptr| { // Loop through pointers
        edit_ptr.deinit(self.allocator);
        self.allocator.destroy(edit_ptr); // Destroy the Edit struct itself
    }
    self.redo_stack.clearRetainingCapacity();
}

pub fn undo(self: *History, buffer: *TextBuffer) !void {
    if (self.undo_stack.items.len == 0) return;
    const edit_ptr = self.undo_stack.pop().?; // Unwrap the optional pointer

    // Revert the change in the buffer
    var i: usize = 0;
    while (i < edit_ptr.new_pieces.items.len) : (i += 1) { // Use edit_ptr
        _ = buffer.pieces.orderedRemove(edit_ptr.start_piece_index);
    }
    try buffer.pieces.insertSlice(self.allocator, edit_ptr.start_piece_index, edit_ptr.old_pieces.items);

    try self.redo_stack.append(self.allocator, edit_ptr); // Append pointer
}

pub fn redo(self: *History, buffer: *TextBuffer) !void {
    if (self.redo_stack.items.len == 0) return;
    const edit_ptr = self.redo_stack.pop().?; // Unwrap the optional pointer

    // Reapply the change in the buffer
    var i: usize = 0;
    while (i < edit_ptr.old_pieces.items.len) : (i += 1) { // Use edit_ptr
        _ = buffer.pieces.orderedRemove(edit_ptr.start_piece_index);
    }
    try buffer.pieces.insertSlice(self.allocator, edit_ptr.start_piece_index, edit_ptr.new_pieces.items);

    try self.undo_stack.append(self.allocator, edit_ptr); // Append pointer
}
