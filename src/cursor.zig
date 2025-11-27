/// A cursor position in the document
const Cursor = @This();

offset: usize, // Absolute position in document

pub fn init(offset: usize) Cursor {
    return .{ .offset = offset };
}
