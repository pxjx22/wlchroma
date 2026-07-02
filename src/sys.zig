//! Thin wrappers over std.os.linux raw syscalls for operations that
//! std.posix stopped exposing in Zig 0.16 (moved behind the std.Io
//! interface). wlchroma is Linux-only (wlr-layer-shell), and its poll-based
//! event loop works on raw fds, so direct syscalls are the right level here.
const std = @import("std");
const linux = std.os.linux;

pub const fd_t = std.posix.fd_t;

pub fn close(fd: fd_t) void {
    _ = linux.close(fd);
}

pub fn unlinkZ(path: [*:0]const u8) !void {
    switch (linux.errno(linux.unlink(path))) {
        .SUCCESS => {},
        .NOENT => return error.FileNotFound,
        else => return error.UnlinkFailed,
    }
}

pub fn socket(domain: u32, sock_type: u32, protocol: u32) !fd_t {
    const rc = linux.socket(domain, sock_type, protocol);
    if (linux.errno(rc) != .SUCCESS) return error.SocketCreateFailed;
    return @intCast(rc);
}

pub fn bind(fd: fd_t, addr: *const std.posix.sockaddr, len: linux.socklen_t) !void {
    if (linux.errno(linux.bind(fd, addr, len)) != .SUCCESS) return error.BindFailed;
}

pub fn listen(fd: fd_t, backlog: u32) !void {
    if (linux.errno(linux.listen(fd, backlog)) != .SUCCESS) return error.ListenFailed;
}

pub fn accept4(fd: fd_t, flags: u32) !fd_t {
    const rc = linux.accept4(fd, null, null, flags);
    if (linux.errno(rc) != .SUCCESS) return error.AcceptFailed;
    return @intCast(rc);
}

pub fn write(fd: fd_t, data: []const u8) !usize {
    const rc = linux.write(fd, data.ptr, data.len);
    if (linux.errno(rc) != .SUCCESS) return error.WriteFailed;
    return rc;
}

pub fn writev(fd: fd_t, iov: []const std.posix.iovec_const) !usize {
    const rc = linux.writev(fd, iov.ptr, iov.len);
    if (linux.errno(rc) != .SUCCESS) return error.WriteFailed;
    return rc;
}

pub fn ftruncate(fd: fd_t, length: u64) !void {
    if (linux.errno(linux.ftruncate(fd, @intCast(length))) != .SUCCESS) return error.TruncateFailed;
}

pub fn timerfdCreate(clockid: linux.timerfd_clockid_t, flags: linux.TFD) !fd_t {
    const rc = linux.timerfd_create(clockid, flags);
    if (linux.errno(rc) != .SUCCESS) return error.TimerFdCreateFailed;
    return @intCast(rc);
}

pub fn timerfdSettime(fd: fd_t, new_value: *const linux.itimerspec) !void {
    if (linux.errno(linux.timerfd_settime(fd, .{}, new_value, null)) != .SUCCESS) {
        return error.TimerFdSetTimeFailed;
    }
}

/// CLOCK_MONOTONIC in nanoseconds. Returns 0 if the clock is unavailable,
/// which callers only use for perf logging and PRNG seeding.
pub fn monotonicNs() u64 {
    var ts: linux.timespec = undefined;
    if (linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}
