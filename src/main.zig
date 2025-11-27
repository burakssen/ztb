const std = @import("std");
const ztb = @import("ztb"); // This will now re-export everything
const TextBuffer = ztb.TextBuffer;
const History = ztb.History;
const io = ztb.io;
const search_mod = ztb.search; // Renamed to avoid conflict with `search` function

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buffer = TextBuffer.init(allocator);
    defer buffer.deinit();

    var history = History.init(allocator);
    defer history.deinit();

    const file = try std.fs.cwd().openFile("test_save.txt", .{});
    defer file.close();

    var file_buffer: [1024]u8 = undefined;
    var file_reader = file.reader(&file_buffer);
    var reader = &file_reader.interface;

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    _ = try reader.stream(&writer.writer, .unlimited);

    try io.loadContent(&buffer, writer.written());

    try search_mod.replaceAll(&buffer, "Line", "Mime");
}
