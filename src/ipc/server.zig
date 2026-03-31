const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

/// Maximum path length for a Unix domain socket (sockaddr_un.sun_path is 108 bytes on Linux).
const SOCK_PATH_MAX = 107;

/// Line buffer size for one IPC command (including newline).
pub const LINE_MAX = 4096;

/// Listening Unix domain socket server.
/// Lifecycle: init() → registered in poll loop → deinit() removes the socket file.
pub const IpcServer = struct {
    fd: posix.fd_t,
    path_buf: [SOCK_PATH_MAX:0]u8,
    path_len: usize,

    /// Create the socket, unlink any stale file, bind, and listen.
    /// Returns error if $XDG_RUNTIME_DIR is unset/empty, the path is too long,
    /// or bind/listen fails. Caller degrades gracefully on error.
    pub fn init() !IpcServer {
        const runtime_dir = posix.getenv("XDG_RUNTIME_DIR") orelse
            return error.NoRuntimeDir;
        if (runtime_dir.len == 0) return error.NoRuntimeDir;

        var server = IpcServer{
            .fd = undefined,
            .path_buf = std.mem.zeroes([SOCK_PATH_MAX:0]u8),
            .path_len = 0,
        };

        // Build socket path into the fixed buffer.
        const path = std.fmt.bufPrintZ(&server.path_buf, "{s}/wlchroma.sock", .{runtime_dir}) catch
            return error.PathTooLong;
        server.path_len = path.len;

        // Remove stale socket from a previous crash.
        posix.unlink(path) catch |err| switch (err) {
            error.FileNotFound => {}, // expected — no stale socket
            else => std.debug.print("ipc: warning: unlink({s}) failed: {}\n", .{ path, err }),
        };

        // Create the listening socket.
        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
        errdefer posix.close(fd);

        var addr = std.mem.zeroes(posix.sockaddr.un);
        addr.family = posix.AF.UNIX;
        if (path.len >= addr.path.len) return error.PathTooLong;
        @memcpy(addr.path[0..path.len], path);

        try posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
        try posix.listen(fd, 8);

        server.fd = fd;
        return server;
    }

    /// Close the listening socket and remove the socket file.
    pub fn deinit(self: *IpcServer) void {
        posix.close(self.fd);
        const path = self.path_buf[0..self.path_len :0];
        posix.unlink(path) catch {};
    }

    /// Accept a pending connection. Returns the client fd.
    /// The caller is responsible for closing the client fd.
    pub fn accept(self: *IpcServer) !posix.fd_t {
        const client_fd = try posix.accept(self.fd, null, null, posix.SOCK.CLOEXEC);
        // Set a 200 ms receive timeout so a slow/stalled client cannot block the render loop.
        const timeout = posix.timeval{ .sec = 0, .usec = 200_000 };
        posix.setsockopt(
            client_fd,
            posix.SOL.SOCKET,
            posix.SO.RCVTIMEO,
            std.mem.asBytes(&timeout),
        ) catch {};
        return client_fd;
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
        var iov = [2]posix.iovec_const{
            .{ .base = line.ptr, .len = line.len },
            .{ .base = "\n", .len = 1 },
        };
        _ = posix.writev(fd, &iov) catch {};
    }
};
