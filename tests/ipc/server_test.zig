const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const ipc = @import("ipc");
const IpcServer = ipc.server.IpcServer;
const sys = ipc.sys;

fn runtimeDir(tmp: *std.testing.TmpDir, path_buf: []u8) ![]const u8 {
    const path_len = try tmp.dir.realPath(std.testing.io, path_buf);
    return path_buf[0..path_len];
}

fn expectNonblocking(fd: posix.fd_t) !void {
    const rc = linux.fcntl(fd, linux.F.GETFL, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
    const flags: linux.O = @bitCast(@as(u32, @intCast(rc)));
    try std.testing.expect(flags.NONBLOCK);
}

fn expectCloseOnExec(fd: posix.fd_t) !void {
    const rc = linux.fcntl(fd, linux.F.GETFD, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
    try std.testing.expect(rc & linux.FD_CLOEXEC != 0);
}

fn connectTo(path: [:0]const u8) !posix.fd_t {
    const fd = try sys.socket(
        posix.AF.UNIX,
        posix.SOCK.STREAM | posix.SOCK.CLOEXEC,
        0,
    );
    errdefer sys.close(fd);
    var addr = std.mem.zeroes(posix.sockaddr.un);
    addr.family = posix.AF.UNIX;
    if (path.len >= addr.path.len) return error.TestPathTooLong;
    @memcpy(addr.path[0..path.len], path);
    const rc = linux.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
    if (linux.errno(rc) != .SUCCESS) return error.TestConnectFailed;
    return fd;
}

test "server listener and lock have atomic fd flags" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const runtime_dir = try runtimeDir(&tmp, &path_buf);
    var server = try IpcServer.initAtRuntimeDir(runtime_dir);
    defer server.deinit();

    try expectNonblocking(server.fd);
    try expectCloseOnExec(server.fd);
    try expectCloseOnExec(server.lock_fd);
    try std.testing.expectError(error.WouldBlock, server.accept());

    const stat = try tmp.dir.statFile(std.testing.io, "wlchroma.lock", .{});
    try std.testing.expectEqual(
        @as(posix.mode_t, 0o600),
        stat.permissions.toMode() & 0o777,
    );
}

test "second server cannot replace the first socket and clean restart works" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const runtime_dir = try runtimeDir(&tmp, &path_buf);

    {
        var first = try IpcServer.initAtRuntimeDir(runtime_dir);
        defer first.deinit();
        if (IpcServer.initAtRuntimeDir(runtime_dir)) |unexpected_value| {
            var unexpected = unexpected_value;
            unexpected.deinit();
            return error.TestExpectedAlreadyRunning;
        } else |err| {
            try std.testing.expect(err == error.AlreadyRunning);
        }
        const client_fd = try connectTo(first.socketPath());
        sys.close(client_fd);
    }

    var restarted = try IpcServer.initAtRuntimeDir(runtime_dir);
    defer restarted.deinit();
    const client_fd = try connectTo(restarted.socketPath());
    sys.close(client_fd);
}

test "server replaces a stale socket when no lock is held" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const runtime_dir = try runtimeDir(&tmp, &path_buf);

    const crashed = try IpcServer.initAtRuntimeDir(runtime_dir);
    sys.close(crashed.fd);
    sys.close(crashed.lock_fd);

    var recovered = try IpcServer.initAtRuntimeDir(runtime_dir);
    defer recovered.deinit();
    const client_fd = try connectTo(recovered.socketPath());
    sys.close(client_fd);
}

test "accepted clients are nonblocking and close-on-exec" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const runtime_dir = try runtimeDir(&tmp, &path_buf);
    var server = try IpcServer.initAtRuntimeDir(runtime_dir);
    defer server.deinit();
    const peer_fd = try connectTo(server.socketPath());
    defer sys.close(peer_fd);
    const client_fd = try server.accept();
    defer sys.close(client_fd);
    try expectNonblocking(client_fd);
    try expectCloseOnExec(client_fd);
}
