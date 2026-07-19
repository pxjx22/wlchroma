const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub const ReadResult = union(enum) {
    signal: linux.signalfd_siginfo,
    would_block,
    short_read: usize,
};

pub fn readOne(fd: posix.fd_t) !ReadResult {
    var info: linux.signalfd_siginfo = undefined;
    const n = posix.read(fd, std.mem.asBytes(&info)) catch |err| switch (err) {
        error.WouldBlock => return .would_block,
        else => return err,
    };
    if (n != @sizeOf(linux.signalfd_siginfo)) {
        return .{ .short_read = n };
    }
    return .{ .signal = info };
}
