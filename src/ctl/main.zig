const std = @import("std");
const posix = std.posix;

// Maximum path length for a Unix domain socket.
const SOCK_PATH_MAX = 107;
// Maximum response line length.
const LINE_MAX = 4096;
// Maximum command line length (verb + space + arg).
const CMD_MAX = 256;

fn writeAll(fd: posix.fd_t, data: []const u8) void {
    var sent: usize = 0;
    while (sent < data.len) {
        const n = posix.write(fd, data[sent..]) catch return;
        sent += n;
    }
}

fn writeErr(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    writeAll(2, s);
}

pub fn main() void {
    run() catch {};
}

fn run() !void {
    // --- T023: argument parsing ---
    var args = std.process.args();
    _ = args.next(); // skip argv[0]

    // Build the command line from all remaining args, space-separated.
    var cmd_buf: [CMD_MAX]u8 = undefined;
    var cmd_len: usize = 0;
    var first_arg = true;

    while (args.next()) |arg| {
        if (!first_arg) {
            if (cmd_len >= cmd_buf.len) {
                writeErr("error: command line too long\n", .{});
                std.process.exit(1);
            }
            cmd_buf[cmd_len] = ' ';
            cmd_len += 1;
        }
        if (cmd_len + arg.len > cmd_buf.len) {
            writeErr("error: command line too long\n", .{});
            std.process.exit(1);
        }
        @memcpy(cmd_buf[cmd_len .. cmd_len + arg.len], arg);
        cmd_len += arg.len;
        first_arg = false;
    }

    if (cmd_len == 0) {
        writeErr(
            \\Usage: wlchroma-ctl <command> [args]
            \\
            \\Commands:
            \\  query
            \\  set-fps <fps>
            \\  set-scale <scale>
            \\  set-palette <name>
            \\  reload
            \\  stop
            \\
        , .{});
        std.process.exit(1);
    }

    // Append newline terminator.
    if (cmd_len >= cmd_buf.len) {
        writeErr("error: command line too long\n", .{});
        std.process.exit(1);
    }
    cmd_buf[cmd_len] = '\n';
    cmd_len += 1;
    const cmd_line = cmd_buf[0..cmd_len];

    // --- Resolve socket path from $XDG_RUNTIME_DIR ---
    const runtime_dir = posix.getenv("XDG_RUNTIME_DIR") orelse {
        writeErr("error: $XDG_RUNTIME_DIR is not set\n", .{});
        std.process.exit(1);
    };
    var path_buf: [SOCK_PATH_MAX:0]u8 = std.mem.zeroes([SOCK_PATH_MAX:0]u8);
    const sock_path = std.fmt.bufPrintZ(&path_buf, "{s}/wlchroma.sock", .{runtime_dir}) catch {
        writeErr("error: socket path too long\n", .{});
        std.process.exit(1);
    };

    // --- T024: connect, send, receive ---
    const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch {
        writeErr("error: failed to create socket\n", .{});
        std.process.exit(1);
    };
    defer posix.close(fd);

    var addr = std.mem.zeroes(posix.sockaddr.un);
    addr.family = posix.AF.UNIX;
    @memcpy(addr.path[0..sock_path.len], sock_path);

    posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch |err| {
        switch (err) {
            error.FileNotFound, error.ConnectionRefused => {
                writeErr("error: wlchroma is not running\n", .{});
            },
            else => {
                writeErr("error: connect failed: {}\n", .{err});
            },
        }
        std.process.exit(1);
    };

    // Send command line (includes trailing newline).
    writeAll(fd, cmd_line);

    // Read response lines until a terminal line (ok or error:).
    var line_buf: [LINE_MAX + 1]u8 = undefined;
    var filled: usize = 0;
    var ok = false;
    var had_error = false;

    outer: while (true) {
        const n = posix.read(fd, line_buf[filled..]) catch |err| switch (err) {
            error.WouldBlock => break,
            else => {
                writeErr("error: read failed: {}\n", .{err});
                std.process.exit(1);
            },
        };
        if (n == 0) break; // EOF
        filled += n;

        // Scan for complete lines.
        var start: usize = 0;
        while (std.mem.indexOfScalar(u8, line_buf[start..filled], '\n')) |nl| {
            const end = nl + 1; // consumed bytes including newline
            const raw = line_buf[start .. start + nl];
            // Trim trailing \r if present.
            const line = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;

            if (std.mem.eql(u8, line, "ok")) {
                ok = true;
                break :outer;
            } else if (std.mem.startsWith(u8, line, "error:")) {
                // Print error line to stderr, not stdout.
                writeAll(2, line);
                writeAll(2, "\n");
                had_error = true;
                break :outer;
            } else {
                // Data line (e.g. key=value from query).
                writeAll(1, line);
                writeAll(1, "\n");
            }
            start += end;
        }
        // Shift unconsumed bytes to the front.
        if (start > 0) {
            const remaining = filled - start;
            std.mem.copyForwards(u8, line_buf[0..remaining], line_buf[start..filled]);
            filled = remaining;
        }
        if (filled >= LINE_MAX) break; // safety: line too long
    }

    // --- T025: exit code ---
    if (!ok and !had_error) {
        // Connection closed before a terminal line.
        std.process.exit(1);
    }
    if (had_error) std.process.exit(1);
}
