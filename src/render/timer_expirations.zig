const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{ ShortRead, LongRead, ZeroExpirations };

pub fn decode(bytes: []const u8) Error!u64 {
    if (bytes.len < @sizeOf(u64)) return error.ShortRead;
    if (bytes.len > @sizeOf(u64)) return error.LongRead;
    const value = std.mem.readInt(u64, bytes[0..8], builtin.cpu.arch.endian());
    if (value == 0) return error.ZeroExpirations;
    return value;
}
