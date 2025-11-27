const std = @import("std");
const enums = @import("enums.zig");
const BufferType = enums.BufferType;

const Piece = @This();
/// A piece represents a span of text in either the original or add buffer
buffer: BufferType,
start: usize, // Start index in the buffer
length: usize, // Length of this piece
