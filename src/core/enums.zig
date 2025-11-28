/// Represents which buffer a piece references
pub const BufferType = enum {
    original, // Read-only original file content
    add, // Mutable added content buffer
};
