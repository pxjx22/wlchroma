const std = @import("std");
const decode = @import("wlchroma_src").timer_expirations.decode;

test "timer expiration decoder requires exactly eight bytes" {
    try std.testing.expectError(error.ShortRead, decode(&.{ 1, 2, 3, 4 }));
    try std.testing.expectError(error.LongRead, decode(&([_]u8{0} ** 9)));
}

test "timer expiration decoder uses native endian u64" {
    const value: u64 = 7;
    const bytes = std.mem.asBytes(&value);
    try std.testing.expectEqual(value, try decode(bytes));
}

test "timer expiration decoder rejects zero expirations" {
    const value: u64 = 0;
    const bytes = std.mem.asBytes(&value);
    try std.testing.expectError(error.ZeroExpirations, decode(bytes));
}
