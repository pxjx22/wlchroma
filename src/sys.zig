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

pub const AcceptError = error{
    WouldBlock,
    ConnectionAborted,
    AcceptFailed,
};

pub fn accept4(fd: fd_t, flags: u32) AcceptError!fd_t {
    while (true) {
        const rc = linux.accept4(fd, null, null, flags);
        switch (linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .CONNABORTED => return error.ConnectionAborted,
            else => return error.AcceptFailed,
        }
    }
}

pub const SendError = error{
    WouldBlock,
    BrokenPipe,
    ConnectionResetByPeer,
    SocketNotConnected,
    SendFailed,
};

pub fn sendNoSignal(fd: fd_t, data: []const u8) SendError!usize {
    if (data.len == 0) return 0;
    while (true) {
        const rc = linux.sendto(
            fd,
            data.ptr,
            data.len,
            linux.MSG.NOSIGNAL | linux.MSG.DONTWAIT,
            null,
            0,
        );
        switch (linux.errno(rc)) {
            .SUCCESS => return rc,
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .PIPE => return error.BrokenPipe,
            .CONNRESET => return error.ConnectionResetByPeer,
            .NOTCONN => return error.SocketNotConnected,
            else => return error.SendFailed,
        }
    }
}

pub fn tryLockExclusive(fd: fd_t) error{ AlreadyRunning, LockFailed }!void {
    while (true) {
        const rc = linux.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB);
        switch (linux.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            .AGAIN => return error.AlreadyRunning,
            else => return error.LockFailed,
        }
    }
}

pub fn setFileMode(fd: fd_t, mode: std.posix.mode_t) error{SetFileModeFailed}!void {
    while (true) {
        switch (linux.errno(linux.fchmod(fd, mode))) {
            .SUCCESS => return,
            .INTR => continue,
            else => return error.SetFileModeFailed,
        }
    }
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

/// Checked CLOCK_MONOTONIC nanoseconds for correctness-sensitive deadlines.
pub fn monotonicNsChecked() error{ClockGetTimeFailed}!u64 {
    var ts: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.MONOTONIC, &ts)) != .SUCCESS) {
        return error.ClockGetTimeFailed;
    }
    if (ts.sec < 0 or ts.nsec < 0 or ts.nsec >= std.time.ns_per_s) {
        return error.ClockGetTimeFailed;
    }
    const seconds: u64 = @intCast(ts.sec);
    const nanoseconds: u64 = @intCast(ts.nsec);
    const base = std.math.mul(u64, seconds, std.time.ns_per_s) catch
        return error.ClockGetTimeFailed;
    return std.math.add(u64, base, nanoseconds) catch
        return error.ClockGetTimeFailed;
}

/// Best-effort timestamp retained for performance logging and animation code.
pub fn monotonicNs() u64 {
    return monotonicNsChecked() catch 0;
}
