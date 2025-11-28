# ztb (Zig Text Buffer)

A high-performance text buffer implementation in Zig, designed for efficient text editing operations.

## Features

- **Core Text Buffer**: Efficient text storage and manipulation using a piece table structure.
- **Editing**: Support for insertions, deletions, and other text modifications.
- **History**: Built-in support for undo/redo operations.
- **Search & Replace**: Efficient search and replace functionality.
- **File I/O**: Helpers for loading from and saving to files.
- **Cursor Management**: Tools for tracking and moving cursors within the buffer.

## Usage

Here is a basic example of how to use `ztb` to load a file, perform a replace operation, and save it back.

```zig
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

    // Initialize buffer and history
    var buffer = TextBuffer.init(allocator);
    defer buffer.deinit();

    var history = History.init(allocator);
    defer history.deinit();

    // Load content from a file
    const file = try std.fs.cwd().openFile("example.txt", .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(content);

    try Io.loadContent(&buffer, content);

    // Perform a replace operation
    try Search.replaceAll(&buffer, "old_text", "new_text");

    // Save the modified buffer
    try Io.save(&buffer, "example_modified.txt");
}
```

## Building and Running

### Run Example

To run the included example which demonstrates loading a large file and performing operations:

```bash
zig build run
```

The benchmark performs the following steps:

1. Generates a synthetic test file (~142 MB) containing 1 million lines of code snippets and log entries.
2. Loads the entire file into the `TextBuffer`.
3. Performs a global search and replace operation (`"userAuthenticated"` -> `"isUserProperlyAuthenticated"`).
4. Saves the modified content back to disk.

**Benchmark Results:**

- Execution Time: 923 ms
- File size: ~142 MB

### Run Tests

To run the unit tests:

```bash
zig build test
```

## Project Structure

- `src/core/`: Core text buffer implementation (Piece table, Cursor, etc.).
- `src/features/`: Higher-level features like History, Search, and I/O.
- `example/`: Example usage of the library.
