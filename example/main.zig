const std = @import("std");
const ztb = @import("ztb");
const TextBuffer = ztb.TextBuffer;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buffer = TextBuffer.init(allocator);
    defer buffer.deinit();

    // Load initial content
    try buffer.load("Hello World from ZTB!");
    
    const initial_content = try buffer.toString();
    defer allocator.free(initial_content);
    std.debug.print("Initial: {s}\n", .{initial_content});

    // Insert text
    std.debug.print("Inserting ' Beautiful' at index 5...\n", .{});
    if (try buffer.insert(5, " Beautiful")) |edit| {
        // We are responsible for cleaning up the Edit if we don't use it
        edit.deinit(allocator);
        allocator.destroy(edit);
    }

    const mid_content = try buffer.toString();
    defer allocator.free(mid_content);
    std.debug.print("After Insert: {s}\n", .{mid_content});

    // Delete text
    std.debug.print("Deleting 'World '...\n", .{});
    // "Hello Beautiful World from ZTB!"
    // "Hello Beautiful " is 16 chars. "World " is 6 chars.
    // "Hello" (5) + " Beautiful" (10) + " " (1) = 16
    if (try buffer.delete(16, 22)) |edit| {
        edit.deinit(allocator);
        allocator.destroy(edit);
    }

    const final_content = try buffer.toString();
    defer allocator.free(final_content);
    std.debug.print("After Delete: {s}\n", .{final_content});
}