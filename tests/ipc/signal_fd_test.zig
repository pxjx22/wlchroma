const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const ipc = @import("ipc");
const signal_fd = ipc.signal_fd;
const sys = ipc.sys;

fn socketPair() ![2]posix.fd_t {
    var fds: [2]posix.fd_t = undefined;
    const rc = linux.socketpair(
        posix.AF.UNIX,
        posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
        0,
        &fds,
    );
    if (linux.errno(rc) != .SUCCESS) return error.TestSocketPairFailed;
    return fds;
}

fn sendExact(fd: posix.fd_t, bytes: []const u8) !void {
    try std.testing.expectEqual(bytes.len, try sys.sendNoSignal(fd, bytes));
}

test "readOne decodes only a complete signalfd record" {
    const fds = try socketPair();
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);
    var info = std.mem.zeroes(linux.signalfd_siginfo);
    info.signo = @intFromEnum(posix.SIG.INT);
    try sendExact(fds[1], std.mem.asBytes(&info));
    switch (try signal_fd.readOne(fds[0])) {
        .signal => |actual| try std.testing.expectEqual(info.signo, actual.signo),
        else => return error.TestExpectedSignal,
    }
}

test "readOne rejects a short record before decoding" {
    const fds = try socketPair();
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);
    try sendExact(fds[1], &[_]u8{ 1, 2, 3, 4 });
    switch (try signal_fd.readOne(fds[0])) {
        .short_read => |n| try std.testing.expectEqual(@as(usize, 4), n),
        else => return error.TestExpectedShortRead,
    }
}

test "readOne reports EOF as a zero-byte short record" {
    const fds = try socketPair();
    defer sys.close(fds[0]);
    sys.close(fds[1]);
    switch (try signal_fd.readOne(fds[0])) {
        .short_read => |n| try std.testing.expectEqual(@as(usize, 0), n),
        else => return error.TestExpectedShortRead,
    }
}

test "readOne reports would-block without touching record bytes" {
    const fds = try socketPair();
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);
    try std.testing.expect(try signal_fd.readOne(fds[0]) == .would_block);
}
