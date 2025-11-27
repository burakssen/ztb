const std = @import("std");
const TextBuffer = @import("text_buffer.zig");

pub fn loadContent(buffer: *TextBuffer, content: []const u8) !void {
    try buffer.original_buffer.appendSlice(buffer.allocator, content);
    if (content.len > 0) {
        try buffer.pieces.append(buffer.allocator, .{
            .buffer = .original,
            .start = 0,
            .length = content.len,
        });
    }
}

pub fn save(buffer: *const TextBuffer, file_path: []const u8) !void {
    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();

    var file_buffer: [1024]u8 = undefined;
    var buffered_writer = file.writer(&file_buffer);
    var writer = &buffered_writer.interface;

    for (buffer.pieces.items) |piece| {
        const buf = if (piece.buffer == .original) buffer.original_buffer.items else buffer.add_buffer.items;
        try writer.writeAll(buf[piece.start .. piece.start + piece.length]);
    }

    try writer.flush();
}
