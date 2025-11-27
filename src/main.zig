const std = @import("std");
const ztb = @import("ztb");
const TextBuffer = ztb.TextBuffer;
const History = ztb.History;
const io = ztb.io;
const search_mod = ztb.search;

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

    const content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(content);

    try io.loadContent(&buffer, content);
    try search_mod.replaceAll(&buffer, "Mime", "Line");

    io.save(&buffer, "test_save.txt") catch |err| {
        std.debug.print("Error saving file: {any}\n", .{err});
    };
}
