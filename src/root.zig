pub const Piece = @import("piece.zig");
pub const Edit = @import("edit.zig");
pub const TextBuffer = @import("text_buffer.zig");
pub const History = @import("history.zig");
pub const LineCol = @import("line_col.zig");
pub const Cursor = @import("cursor.zig");

pub const search = @import("search.zig");
pub const io = @import("io.zig");

test {
    _ = @import("stress_test.zig");
    _ = @import("test_features.zig");
}
