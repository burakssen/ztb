const std = @import("std");
const TextBuffer = @import("text_buffer.zig");
const Edit = @import("edit.zig");

/// Search for a pattern in the buffer (correctly handling piece boundaries)
pub fn search(buffer: *const TextBuffer, pattern: []const u8) !std.ArrayList(usize) {
    var results: std.ArrayList(usize) = .empty;
    if (pattern.len == 0) return results;
    const len = buffer.length();
    if (len < pattern.len) return results;
    var i: usize = 0;
    while (i <= len - pattern.len) : (i += 1) {
        var match = true;
        var j: usize = 0;
        while (j < pattern.len) : (j += 1) {
            if (buffer.charAt(i + j) != pattern[j]) {
                match = false;
                break;
            }
        }
        if (match) {
            try results.append(buffer.allocator, i);
        }
    }
    return results;
}

pub fn replace(buffer: *TextBuffer, start: usize, end: usize, text: []const u8) !void {
    if (try buffer.delete(start, end)) |edit_ptr| {
        edit_ptr.deinit(buffer.allocator);
        buffer.allocator.destroy(edit_ptr);
    }
    if (try buffer.insert(start, text)) |edit_ptr| {
        edit_ptr.deinit(buffer.allocator);
        buffer.allocator.destroy(edit_ptr);
    }
}

const ReplaceTask = struct {
    pos: usize,
    pattern_len: usize,
    replacement: []const u8,
};

const ReplaceContext = struct {
    buffer: *TextBuffer,
    tasks: []ReplaceTask,
    mutex: std.Thread.Mutex,
    errors: std.ArrayList(anyerror),

    fn workerFn(self: *ReplaceContext, task_idx: usize) void {
        const task = self.tasks[task_idx];

        self.mutex.lock();
        defer self.mutex.unlock();

        replace(self.buffer, task.pos, task.pos + task.pattern_len, task.replacement) catch |err| {
            self.errors.append(self.buffer.allocator, err) catch {};
        };
    }
};

pub fn replaceAll(buffer: *TextBuffer, pattern: []const u8, replacement: []const u8) !void {
    var matches = try search(buffer, pattern);
    defer matches.deinit(buffer.allocator);

    if (matches.items.len == 0) return;

    // Create tasks array
    var tasks = try buffer.allocator.alloc(ReplaceTask, matches.items.len);
    defer buffer.allocator.free(tasks);

    // Build tasks in reverse order to avoid offset invalidation
    var i = matches.items.len;
    while (i > 0) {
        i -= 1;
        tasks[matches.items.len - 1 - i] = .{
            .pos = matches.items[i],
            .pattern_len = pattern.len,
            .replacement = replacement,
        };
    }

    // Set up context
    var context = ReplaceContext{
        .buffer = buffer,
        .tasks = tasks,
        .mutex = std.Thread.Mutex{},
        .errors = .empty,
    };
    defer context.errors.deinit(buffer.allocator);

    // Determine thread count
    const cpu_count = try std.Thread.getCpuCount();
    const thread_count = @min(cpu_count, tasks.len);

    if (thread_count <= 1) {
        // Sequential fallback
        for (tasks, 0..) |_, idx| {
            context.workerFn(idx);
        }
    } else {
        // Parallel execution
        const threads = try buffer.allocator.alloc(std.Thread, thread_count);
        defer buffer.allocator.free(threads);

        const tasks_per_thread = tasks.len / thread_count;

        for (threads, 0..) |*thread, t_idx| {
            const start_idx = t_idx * tasks_per_thread;
            const end_idx = if (t_idx == thread_count - 1) tasks.len else (t_idx + 1) * tasks_per_thread;

            thread.* = try std.Thread.spawn(.{}, struct {
                fn run(ctx: *ReplaceContext, start: usize, end: usize) void {
                    for (start..end) |idx| {
                        ctx.workerFn(idx);
                    }
                }
            }.run, .{ &context, start_idx, end_idx });
        }

        for (threads) |thread| {
            thread.join();
        }
    }

    // Check for errors
    if (context.errors.items.len > 0) {
        return context.errors.items[0];
    }
}
