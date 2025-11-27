const std = @import("std");
const TextBuffer = @import("text_buffer.zig");
const io = @import("io.zig");
const search_mod = @import("search.zig"); // Renamed to avoid conflict with `search` function
const History = @import("history.zig"); // Not used directly in this test, but good to have
const Edit = @import("edit.zig"); // Need to import Edit to deinit it

test "save" {
    const allocator = std.testing.allocator;
    var buffer = TextBuffer.init(allocator);
    defer buffer.deinit();

    try io.loadContent(&buffer, "Hello Save!");
    try io.save(&buffer, "test_save.txt");
    defer std.fs.cwd().deleteFile("test_save.txt") catch {};

    const file = try std.fs.cwd().openFile("test_save.txt", .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 1024);
    defer allocator.free(content);

    try std.testing.expectEqualStrings("Hello Save!", content);
}

test "LineCol and Offset" {
    const allocator = std.testing.allocator;
    var buffer = TextBuffer.init(allocator);
    defer buffer.deinit();

    try io.loadContent(&buffer, "Line1\nLine2\nLine3");

    // Check getLineCol
    const lc1 = try buffer.getLineCol(0); // 'L'
    try std.testing.expectEqual(@as(usize, 0), lc1.line);
    try std.testing.expectEqual(@as(usize, 0), lc1.col);

    // Line1 is 5 chars, \n is 1. Total 6. Index 6 is start of Line2.
    const lc2 = try buffer.getLineCol(6);
    try std.testing.expectEqual(@as(usize, 1), lc2.line);
    try std.testing.expectEqual(@as(usize, 0), lc2.col);

    // Check getOffset
    const off1 = try buffer.getOffset(0, 0);
    try std.testing.expectEqual(@as(usize, 0), off1);

    const off2 = try buffer.getOffset(1, 0);
    try std.testing.expectEqual(@as(usize, 6), off2);
}

test "search across pieces" {
    const allocator = std.testing.allocator;
    var buffer = TextBuffer.init(allocator);
    defer buffer.deinit();

    try io.loadContent(&buffer, "Hello");
    if (try buffer.insert(5, " World")) |edit_ptr| { // Handle the ?*Edit return type
        edit_ptr.deinit(allocator);
        allocator.destroy(edit_ptr);
    }

    var results = try search_mod.search(&buffer, "lo Wo");
    defer results.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqual(@as(usize, 3), results.items[0]);
}

test "search boundary conditions" {
    const allocator = std.testing.allocator;
    var buffer = TextBuffer.init(allocator);
    defer buffer.deinit();

    // Create a buffer with two pieces
    try io.loadContent(&buffer, "Part1");
    if (try buffer.insert(5, "Part2")) |edit_ptr| {
        edit_ptr.deinit(allocator);
        allocator.destroy(edit_ptr);
    }

    // "Part1Part2"
    // Search for "1P" which crosses the boundary
    var results = try search_mod.search(&buffer, "1P");
    defer results.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqual(@as(usize, 4), results.items[0]);
}

test "replace and replaceAll" {
    const allocator = std.testing.allocator;
    var buffer = TextBuffer.init(allocator);
    defer buffer.deinit();

    try io.loadContent(&buffer, "foo bar foo");

    // Replace first foo with baz
    try search_mod.replace(&buffer, 0, 3, "baz"); // search_mod.replace already handles deinit/destroy
    {
        const str = try buffer.toString();
        defer allocator.free(str);
        try std.testing.expectEqualStrings("baz bar foo", str);
    }
}

test "replaceAll clean" {
    const allocator = std.testing.allocator;
    var buffer = TextBuffer.init(allocator);
    defer buffer.deinit();

    try io.loadContent(&buffer, "foo bar foo");
    try search_mod.replaceAll(&buffer, "foo", "baz"); // search_mod.replaceAll already handles deinit/destroy

    const str = try buffer.toString();
    defer allocator.free(str);
    try std.testing.expectEqualStrings("baz bar baz", str);
}
