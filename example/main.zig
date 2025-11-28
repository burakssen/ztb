const std = @import("std");
const ztb = @import("ztb");
const TextBuffer = ztb.TextBuffer;
const History = ztb.History;
const Io = ztb.Io;
const Search = ztb.Search;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    {
        var test_file = try std.fs.cwd().createFile("test_save.txt", .{});
        defer test_file.close();
        var test_buffer: [1024]u8 = undefined;
        var buffered_writer = test_file.writer(&test_buffer);
        var writer = &buffered_writer.interface;

        // Generate 1 Million lines with more complex patterns
        const patterns = [_][]const u8{
            "function processData(input: string): Result {{ return {{status: 'success', data: input}}; }}",
            "const API_ENDPOINT = 'https://api.example.com/v2/users/{id}/profile';",
            "TODO: Refactor this section - the logic here is becoming unwieldy and needs optimization",
            "if (userAuthenticated && hasPermissions('admin') && !isLocked) {{ executeAdminCommand(); }}",
            "SELECT users.name, orders.total FROM users INNER JOIN orders ON users.id = orders.user_id WHERE orders.status = 'pending';",
            "Error: Unable to connect to database - retrying connection attempt {attempt} of {max_attempts}",
            "import {{ Component, OnInit, ViewChild, ElementRef }} from '@angular/core';",
            "[DEBUG] Request received at {timestamp} from IP {ip_address} - Processing payload of size {size}KB",
        };

        const search_targets = [_][]const u8{
            "processData",
            "API_ENDPOINT",
            "TODO",
            "userAuthenticated",
            "SELECT",
            "Error",
            "import",
            "[DEBUG]",
        };

        for (0..1000000) |i| {
            const pattern_idx = @mod(i, patterns.len);
            const line = patterns[pattern_idx];

            // Add varied content with search targets embedded
            try writer.print("{d} | {s} | checksum:{d} | timestamp:{d}\n", .{ i, line, @mod(i * 31337, 999999), i * 1000 });

            // Every 10th line, add a line with multiple occurrences of the target
            if (@mod(i, 10) == 0) {
                const target = search_targets[pattern_idx];
                try writer.print("MULTI: {s} appears {s} here and {s} there, even {s} everywhere!\n", .{ target, target, target, target });
            }
        }
        try writer.flush();
    }

    const start_time = std.time.milliTimestamp();

    var buffer = TextBuffer.init(allocator);
    defer buffer.deinit();

    var history = History.init(allocator);
    defer history.deinit();

    const file = try std.fs.cwd().openFile("test_save.txt", .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(content);

    try Io.loadContent(&buffer, content);

    // Test with a longer, more realistic search/replace
    try Search.replaceAll(&buffer, "userAuthenticated", "isUserProperlyAuthenticated");

    Io.save(&buffer, "test_save.txt") catch |err| {
        std.debug.print("Error saving file: {any}\n", .{err});
    };

    const end_time = std.time.milliTimestamp();
    std.debug.print("Execution Time: {d} ms\n", .{end_time - start_time});
    std.debug.print("File size: ~{d} MB\n", .{(try std.fs.cwd().statFile("test_save.txt")).size / 1024 / 1024});
}
