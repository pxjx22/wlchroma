const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const sys = @import("sys");

const SUN_PATH_BYTES = @sizeOf(@FieldType(posix.sockaddr.un, "path"));

/// Listening Unix domain socket server.
/// Lifecycle: init() → registered in poll loop → deinit() removes the socket file.
pub const IpcServer = struct {
    fd: posix.fd_t,
    lock_fd: posix.fd_t,
    path_buf: [SUN_PATH_BYTES]u8,
    path_len: usize,

    pub fn init(environ: std.process.Environ) !IpcServer {
        const runtime_dir = environ.getPosix("XDG_RUNTIME_DIR") orelse
            return error.NoRuntimeDir;
        return initAtRuntimeDir(runtime_dir);
    }

    pub fn initAtRuntimeDir(runtime_dir: []const u8) !IpcServer {
        return initAtRuntimeDirWithModeSetter(runtime_dir, sys.setPathModeZ);
    }

    fn initAtRuntimeDirWithModeSetter(
        runtime_dir: []const u8,
        comptime set_mode: fn ([*:0]const u8, posix.mode_t) error{SetFileModeFailed}!void,
    ) !IpcServer {
        if (runtime_dir.len == 0) return error.NoRuntimeDir;

        var server = IpcServer{
            .fd = undefined,
            .lock_fd = undefined,
            .path_buf = std.mem.zeroes([SUN_PATH_BYTES]u8),
            .path_len = 0,
        };
        const socket_path = std.mem.printSentinel(
            &server.path_buf,
            "{s}/wlchroma.sock",
            .{runtime_dir},
            0,
        ) catch return error.PathTooLong;
        server.path_len = socket_path.len;

        var lock_path_buf = std.mem.zeroes([SUN_PATH_BYTES]u8);
        const lock_path = std.mem.printSentinel(
            &lock_path_buf,
            "{s}/wlchroma.lock",
            .{runtime_dir},
            0,
        ) catch return error.PathTooLong;
        const lock_fd = try posix.openatZ(
            posix.AT.FDCWD,
            lock_path.ptr,
            .{
                .ACCMODE = .RDWR,
                .CREAT = true,
                .CLOEXEC = true,
                .NOFOLLOW = true,
            },
            @as(posix.mode_t, 0o600),
        );
        errdefer sys.close(lock_fd);
        try sys.setFileMode(lock_fd, 0o600);
        try sys.tryLockExclusive(lock_fd);

        sys.unlinkZ(socket_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        const fd = try sys.socket(
            posix.AF.UNIX,
            posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
            0,
        );
        var bound = false;
        errdefer {
            sys.close(fd);
            if (bound) sys.unlinkZ(socket_path) catch {};
        }

        var addr = std.mem.zeroes(posix.sockaddr.un);
        addr.family = posix.AF.UNIX;
        if (socket_path.len >= addr.path.len) return error.PathTooLong;
        @memcpy(addr.path[0..socket_path.len], socket_path);
        try sys.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
        bound = true;
        // The XDG runtime directory is private to the user. Restrict the bound
        // pathname before listening, without changing the process-wide umask.
        try set_mode(socket_path, 0o600);
        try sys.listen(fd, 8);

        server.fd = fd;
        server.lock_fd = lock_fd;
        return server;
    }

    pub fn socketPath(self: *const IpcServer) [:0]const u8 {
        return self.path_buf[0..self.path_len :0];
    }

    pub fn accept(self: *IpcServer) sys.AcceptError!posix.fd_t {
        return sys.accept4(
            self.fd,
            posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
        );
    }

    pub fn deinit(self: *IpcServer) void {
        sys.close(self.fd);
        sys.unlinkZ(self.socketPath()) catch {};
        sys.close(self.lock_fd);
    }
};

test "socket mode failure removes the bound path and releases the lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const runtime_dir = path_buf[0..path_len];
    const fail_mode = struct {
        fn set(_: [*:0]const u8, _: posix.mode_t) error{SetFileModeFailed}!void {
            return error.SetFileModeFailed;
        }
    }.set;

    try std.testing.expectError(
        error.SetFileModeFailed,
        IpcServer.initAtRuntimeDirWithModeSetter(runtime_dir, fail_mode),
    );
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(std.testing.io, "wlchroma.sock", .{}),
    );
    var recovered = try IpcServer.initAtRuntimeDir(runtime_dir);
    defer recovered.deinit();
}
