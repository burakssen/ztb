const std = @import("std");

const core = @import("core");
const TextBuffer = core.TextBuffer;
const Edit = core.Edit;

const features = @import("features");

const History = features.History;
const Io = features.Io;

test "stress test: load and manipulate 1 million lines" {
    const allocator = std.testing.allocator;

    var buffer = TextBuffer.init(allocator);
    defer buffer.deinit();

    var history = History.init(allocator);
    defer history.deinit();

    // 1. Generate 1 million lines of varying length text
    var raw_content = std.ArrayList(u8).empty;
    defer raw_content.deinit(allocator);

    const count = 1_000_000;
    try raw_content.ensureTotalCapacity(allocator, count * 20); // More space for varying lengths

    std.debug.print("\n=== Stress Test: 1M Lines ===\n", .{});

    var i: usize = 0;
    while (i < count) : (i += 1) {
        var buf: [64]u8 = undefined;
        // Vary line length to test different piece sizes
        const extra = if (i % 100 == 0) " with extra content to vary piece sizes" else "";
        const slice = try std.fmt.bufPrint(&buf, "Line {d}{s}\n", .{ i, extra });
        raw_content.appendSliceAssumeCapacity(slice);
    }

    const total_size = raw_content.items.len;
    std.debug.print("Generated {d} bytes ({d:.2} MB) of test data.\n", .{ total_size, @as(f64, @floatFromInt(total_size)) / 1_048_576.0 });

    // 2. Load content with timing
    const start_load = std.time.nanoTimestamp();
    try Io.loadContent(&buffer, raw_content.items);
    const end_load = std.time.nanoTimestamp();
    const load_time = @divFloor(end_load - start_load, 1_000_000);

    try std.testing.expectEqual(total_size, buffer.length());
    std.debug.print("✓ Loaded 1M lines in {d}ms ({d:.2} MB/s)\n", .{ load_time, @as(f64, @floatFromInt(total_size)) / @as(f64, @floatFromInt(load_time)) / 1000.0 });

    // 3. Random access performance test
    const access_start = std.time.nanoTimestamp();
    const positions = [_]usize{ 0, total_size / 4, total_size / 2, 3 * total_size / 4, total_size - 1 };
    for (positions) |pos| {
        const char = buffer.charAt(pos);
        try std.testing.expect(char != null);
    }
    const access_end = std.time.nanoTimestamp();
    std.debug.print("✓ Random access (5 positions) in {d}μs\n", .{@divFloor(access_end - access_start, 1_000)});

    // 4. Insert at beginning (worst case)
    const insert_start_time = std.time.nanoTimestamp();
    if (try buffer.insert(0, "PREPENDED\n")) |edit_ptr| {
        try history.recordEdit(edit_ptr);
    }
    const insert_start_end = std.time.nanoTimestamp();
    try std.testing.expectEqual(total_size + 10, buffer.length());
    std.debug.print("✓ Insert at start in {d}μs\n", .{@divFloor(insert_start_end - insert_start_time, 1_000)});

    // 5. Insert at end (best case)
    const insert_end_time = std.time.nanoTimestamp();
    if (try buffer.insert(buffer.length(), "APPENDED\n")) |edit_ptr| {
        try history.recordEdit(edit_ptr);
    }
    const insert_end_end = std.time.nanoTimestamp();
    try std.testing.expectEqual(total_size + 19, buffer.length());
    std.debug.print("✓ Insert at end in {d}μs\n", .{@divFloor(insert_end_end - insert_end_time, 1_000)});

    // 6. Multiple inserts in middle (triggers splits)
    const mid_inserts_start = std.time.nanoTimestamp();
    const positions_middle = [_]usize{ total_size / 4, total_size / 2, 3 * total_size / 4 };
    var expected_length: usize = total_size + 19;
    for (positions_middle, 0..) |pos, idx| {
        var buf: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "MID{d}", .{idx});
        if (try buffer.insert(pos, text)) |edit_ptr| {
            try history.recordEdit(edit_ptr);
        }
        expected_length += text.len;
    }
    const mid_inserts_end = std.time.nanoTimestamp();
    try std.testing.expectEqual(expected_length, buffer.length());
    std.debug.print("✓ 3 middle inserts in {d}μs\n", .{@divFloor(mid_inserts_end - mid_inserts_start, 1_000)});

    // 7. Large delete operation
    const delete_start = std.time.nanoTimestamp();
    const delete_size: usize = 10000;
    const delete_pos = total_size / 2;
    if (try buffer.delete(delete_pos, delete_pos + delete_size)) |edit_ptr| {
        try history.recordEdit(edit_ptr);
    }
    const delete_end = std.time.nanoTimestamp();
    expected_length -= delete_size;
    try std.testing.expectEqual(expected_length, buffer.length());
    std.debug.print("✓ Delete 10KB in {d}μs\n", .{@divFloor(delete_end - delete_start, 1_000)});

    // 8. Undo/Redo performance
    const undo_count: usize = 5;
    const undo_start = std.time.nanoTimestamp();
    var j: usize = 0;
    while (j < undo_count) : (j += 1) {
        try history.undo(&buffer);
    }
    const undo_end = std.time.nanoTimestamp();
    std.debug.print("✓ {d} undos in {d}μs\n", .{ undo_count, @divFloor(undo_end - undo_start, 1_000) });

    const redo_start = std.time.nanoTimestamp();
    j = 0;
    while (j < undo_count) : (j += 1) {
        try history.redo(&buffer);
    }
    const redo_end = std.time.nanoTimestamp();
    std.debug.print("✓ {d} redos in {d}μs\n", .{ undo_count, @divFloor(redo_end - redo_start, 1_000) });

    // 9. Verify final state
    try std.testing.expectEqual(expected_length, buffer.length());
    std.debug.print("✓ Final integrity check passed\n", .{});
}

test "fuzz test: random operations with verification" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x12345678);
    const random = prng.random();

    var buffer = TextBuffer.init(allocator);
    defer buffer.deinit();

    var ztb_history = History.init(allocator);
    defer ztb_history.deinit();

    var shadow: std.ArrayList(u8) = .empty;
    defer shadow.deinit(allocator);

    var history_shadow: std.ArrayList([]u8) = .empty;
    defer {
        for (history_shadow.items) |item| allocator.free(item);
        history_shadow.deinit(allocator);
    }

    var future_shadow: std.ArrayList([]u8) = .empty;
    defer {
        for (future_shadow.items) |item| allocator.free(item);
        future_shadow.deinit(allocator);
    }

    std.debug.print("\n=== Fuzz Test: Random Operations ===\n", .{});

    const iterations = 5000; // Increased from 2000
    var insert_count: usize = 0;
    var delete_count: usize = 0;
    var undo_count: usize = 0;
    var redo_count: usize = 0;
    var max_size: usize = 0;
    var verification_count: usize = 0;

    // Pre-fill with more substantial data
    const initial_data = "Initial Data: The quick brown fox jumps over the lazy dog. ";
    if (try buffer.insert(0, initial_data)) |edit_ptr| {
        try ztb_history.recordEdit(edit_ptr);
    }
    try shadow.appendSlice(allocator, initial_data);

    const fuzz_start = std.time.nanoTimestamp();

    for (0..iterations) |i| {
        // Weight actions based on more realistic usage patterns
        const action = random.intRangeAtMost(u8, 0, 100);

        // 0-49: Insert (50%)
        // 50-74: Delete (25%)
        // 75-89: Undo (15%)
        // 90-100: Redo (10%)

        if (action <= 49) { // INSERT
            const current_copy = try allocator.dupe(u8, shadow.items);
            try history_shadow.append(allocator, current_copy);

            for (future_shadow.items) |item| allocator.free(item);
            future_shadow.clearRetainingCapacity();

            // Generate more varied text
            var buf: [32]u8 = undefined;
            const len = random.intRangeAtMost(usize, 1, 20);
            for (0..len) |j| {
                // Mix of lowercase, uppercase, digits, and spaces
                const char_type = random.intRangeAtMost(u8, 0, 3);
                buf[j] = switch (char_type) {
                    0 => random.intRangeAtMost(u8, 'a', 'z'),
                    1 => random.intRangeAtMost(u8, 'A', 'Z'),
                    2 => random.intRangeAtMost(u8, '0', '9'),
                    else => ' ',
                };
            }
            const text = buf[0..len];

            const pos = if (buffer.length() > 0) random.intRangeAtMost(usize, 0, buffer.length()) else 0;

            if (try buffer.insert(pos, text)) |edit_ptr| {
                try ztb_history.recordEdit(edit_ptr);
            }
            try shadow.insertSlice(allocator, pos, text);
            insert_count += 1;
        } else if (action <= 74) { // DELETE
            if (buffer.length() == 0) continue;

            const current_copy = try allocator.dupe(u8, shadow.items);
            try history_shadow.append(allocator, current_copy);

            for (future_shadow.items) |item| allocator.free(item);
            future_shadow.clearRetainingCapacity();

            const start = random.intRangeAtMost(usize, 0, buffer.length() - 1);
            const max_len = buffer.length() - start;
            // Allow larger deletions occasionally
            const len_choice = random.intRangeAtMost(usize, 0, 9);
            const len = if (len_choice < 7)
                random.intRangeAtMost(usize, 1, @min(10, max_len))
            else
                random.intRangeAtMost(usize, 1, @min(100, max_len));
            const end = start + len;

            if (try buffer.delete(start, end)) |edit_ptr| {
                try ztb_history.recordEdit(edit_ptr);
            }
            try shadow.replaceRange(allocator, start, len, "");
            delete_count += 1;
        } else if (action <= 89) { // UNDO
            if (ztb_history.undo_stack.items.len == 0) continue;

            const current_copy = try allocator.dupe(u8, shadow.items);
            try future_shadow.append(allocator, current_copy);

            const prev_state = history_shadow.pop();
            if (prev_state) |state| {
                defer allocator.free(state);
                shadow.clearRetainingCapacity();
                try shadow.appendSlice(allocator, state);
                try ztb_history.undo(&buffer);
            }
            undo_count += 1;
        } else { // REDO
            if (ztb_history.redo_stack.items.len == 0) continue;

            const current_copy = try allocator.dupe(u8, shadow.items);
            try history_shadow.append(allocator, current_copy);

            const next_state = future_shadow.pop();
            if (next_state) |state| {
                defer allocator.free(state);
                shadow.clearRetainingCapacity();
                try shadow.appendSlice(allocator, state);
                try ztb_history.redo(&buffer);
            }
            redo_count += 1;
        }

        // Track maximum size
        if (shadow.items.len > max_size) {
            max_size = shadow.items.len;
        }

        // VERIFICATION - Always check length
        try std.testing.expectEqual(shadow.items.len, buffer.length());

        // Deep verification with adaptive frequency
        const should_verify = shadow.items.len < 500 or // Small buffers
            i % 200 == 0 or // Periodic
            i == iterations - 1; // Final

        if (should_verify) {
            const buffer_content = try buffer.toString();
            defer allocator.free(buffer_content);

            if (!std.mem.eql(u8, shadow.items, buffer_content)) {
                std.debug.print("\n❌ MISMATCH at iteration {d}\n", .{i});
                std.debug.print("Shadow length: {d}, Buffer length: {d}\n", .{ shadow.items.len, buffer_content.len });
                std.debug.print("Stats: Inserts={d}, Deletes={d}, Undos={d}, Redos={d}\n", .{ insert_count, delete_count, undo_count, redo_count });

                // Show first difference
                const min_len = @min(shadow.items.len, buffer_content.len);
                for (0..min_len) |idx| {
                    if (shadow.items[idx] != buffer_content[idx]) {
                        std.debug.print("First diff at index {d}: shadow={d}, buffer={d}\n", .{ idx, shadow.items[idx], buffer_content[idx] });
                        break;
                    }
                }

                return error.TestExpectedEqual;
            }
            verification_count += 1;
        }
    }

    const fuzz_end = std.time.nanoTimestamp();
    const fuzz_time = @divFloor(fuzz_end - fuzz_start, 1_000_000);

    std.debug.print("✓ Completed {d} iterations in {d}ms\n", .{ iterations, fuzz_time });
    std.debug.print("  Operations: {d} inserts, {d} deletes, {d} undos, {d} redos\n", .{ insert_count, delete_count, undo_count, redo_count });
    std.debug.print("  Max buffer size: {d} bytes\n", .{max_size});
    std.debug.print("  Deep verifications: {d}\n", .{verification_count});
    std.debug.print("  Final buffer size: {d} bytes\n", .{buffer.length()});
}

test "stress test: pathological cases" {
    const allocator = std.testing.allocator;

    std.debug.print("\n=== Stress Test: Pathological Cases ===\n", .{});

    // Test 1: Repeated insert at position 0 (worst case for piece table)
    {
        var buffer = TextBuffer.init(allocator);
        defer buffer.deinit();

        var history = History.init(allocator);
        defer history.deinit();

        const start = std.time.nanoTimestamp();
        var i: usize = 0;
        while (i < 1000) : (i += 1) {
            if (try buffer.insert(0, "X")) |edit_ptr| {
                try history.recordEdit(edit_ptr);
            }
        }
        const end = std.time.nanoTimestamp();

        try std.testing.expectEqual(@as(usize, 1000), buffer.length());
        std.debug.print("✓ 1000 inserts at position 0: {d}ms\n", .{@divFloor(end - start, 1_000_000)});
    }

    // Test 2: Alternating insert/delete at same position
    {
        var buffer = TextBuffer.init(allocator);
        defer buffer.deinit();

        var history = History.init(allocator);
        defer history.deinit();

        if (try buffer.insert(0, "Base")) |edit_ptr| {
            try history.recordEdit(edit_ptr);
        }

        const start = std.time.nanoTimestamp();
        var i: usize = 0;
        while (i < 500) : (i += 1) {
            if (try buffer.insert(2, "XX")) |edit_ptr| {
                try history.recordEdit(edit_ptr);
            }
            if (try buffer.delete(2, 4)) |edit_ptr| {
                try history.recordEdit(edit_ptr);
            }
        }
        const end = std.time.nanoTimestamp();

        try std.testing.expectEqual(@as(usize, 4), buffer.length());
        std.debug.print("✓ 500 insert/delete cycles: {d}ms\n", .{@divFloor(end - start, 1_000_000)});
    }

    // Test 3: Growing buffer with frequent access
    {
        var buffer = TextBuffer.init(allocator);
        defer buffer.deinit();

        var history = History.init(allocator);
        defer history.deinit();

        const start = std.time.nanoTimestamp();
        var i: usize = 0;
        while (i < 1000) : (i += 1) {
            if (try buffer.insert(buffer.length(), "Data")) |edit_ptr| {
                try history.recordEdit(edit_ptr);
            }
            // Access middle repeatedly
            _ = buffer.charAt(buffer.length() / 2);
        }
        const end = std.time.nanoTimestamp();

        try std.testing.expectEqual(@as(usize, 4000), buffer.length());
        std.debug.print("✓ 1000 appends with random access: {d}ms\n", .{@divFloor(end - start, 1_000_000)});
    }

    // Test 4: Deep undo/redo stack
    {
        var buffer = TextBuffer.init(allocator);
        defer buffer.deinit();

        var history = History.init(allocator);
        defer history.deinit();

        // Build deep history
        var i: usize = 0;
        while (i < 100) : (i += 1) {
            if (try buffer.insert(buffer.length(), "X")) |edit_ptr| {
                try history.recordEdit(edit_ptr);
            }
        }

        // Undo all
        const undo_start = std.time.nanoTimestamp();
        i = 0;
        while (i < 100) : (i += 1) {
            try history.undo(&buffer);
        }
        const undo_end = std.time.nanoTimestamp();

        // Redo all
        const redo_start = std.time.nanoTimestamp();
        i = 0;
        while (i < 100) : (i += 1) {
            try history.redo(&buffer);
        }
        const redo_end = std.time.nanoTimestamp();

        try std.testing.expectEqual(@as(usize, 100), buffer.length());
        std.debug.print("✓ 100 undos: {d}μs, 100 redos: {d}μs\n", .{ @divFloor(undo_end - undo_start, 1_000), @divFloor(redo_end - redo_start, 1_000) });
    }
}
