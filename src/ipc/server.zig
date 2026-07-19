const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const sys = @import("sys");

const SUN_PATH_BYTES = @sizeOf(@FieldType(posix.sockaddr.un, "path"));

/// Line buffer size for one IPC command (including newline).
pub const LINE_MAX = 4096;

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
        if (runtime_dir.len == 0) return error.NoRuntimeDir;

        var server = IpcServer{
            .fd = undefined,
            .lock_fd = undefined,
            .path_buf = std.mem.zeroes([SUN_PATH_BYTES]u8),
            .path_len = 0,
        };
        const socket_path = std.fmt.bufPrintZ(
            &server.path_buf,
            "{s}/wlchroma.sock",
            .{runtime_dir},
        ) catch return error.PathTooLong;
        server.path_len = socket_path.len;

        var lock_path_buf = std.mem.zeroes([SUN_PATH_BYTES]u8);
        const lock_path = std.fmt.bufPrintZ(
            &lock_path_buf,
            "{s}/wlchroma.lock",
            .{runtime_dir},
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
        try sys.listen(fd, 8);

        server.fd = fd;
        server.lock_fd = lock_fd;
        return server;
    }

    pub fn socketPath(self: *const IpcServer) [:0]const u8 {
        return self.path_buf[0..self.path_len :0];
    }

    pub fn accept(self: *IpcServer) sys.AcceptError!posix.fd_t {
        const client_fd = try sys.accept4(self.fd, posix.SOCK.CLOEXEC);
        const timeout = posix.timeval{ .sec = 0, .usec = 200_000 };
        posix.setsockopt(
            client_fd,
            posix.SOL.SOCKET,
            posix.SO.RCVTIMEO,
            std.mem.asBytes(&timeout),
        ) catch {};
        return client_fd;
    }

    pub fn deinit(self: *IpcServer) void {
        sys.close(self.fd);
        sys.unlinkZ(self.socketPath()) catch {};
        sys.close(self.lock_fd);
    }

    /// Read one newline-terminated line from `fd` into `buf`.
    /// Returns the slice up to (but not including) the newline.
    /// Returns error.LineTooLong if no newline seen within buf.len bytes.
    /// Returns error.ConnectionClosed if the peer closed before sending a newline.
    pub fn readLine(fd: posix.fd_t, buf: []u8) ![]u8 {
        var filled: usize = 0;
        while (filled < buf.len) {
            const n = posix.read(fd, buf[filled..]) catch |err| switch (err) {
                error.WouldBlock => return error.ConnectionClosed,
                else => return err,
            };
            if (n == 0) return error.ConnectionClosed;
            filled += n;
            // Scan for newline in newly received data.
            for (buf[filled - n .. filled], filled - n..) |ch, i| {
                if (ch == '\n') {
                    // Trim any trailing carriage return (robustness for \r\n clients).
                    const end = if (i > 0 and buf[i - 1] == '\r') i - 1 else i;
                    return buf[0..end];
                }
            }
        }
        return error.LineTooLong;
    }

    /// Write `line` followed by a newline to `fd`. Errors are silently swallowed
    /// so a slow client cannot propagate an error into the render loop.
    pub fn writeLine(fd: posix.fd_t, line: []const u8) void {
        const iov = [2]posix.iovec_const{
            .{ .base = line.ptr, .len = line.len },
            .{ .base = "\n", .len = 1 },
        };
        _ = sys.writev(fd, &iov) catch {};
    }
};
