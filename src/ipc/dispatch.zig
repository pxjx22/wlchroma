const std = @import("std");
const posix = std.posix;
const server_mod = @import("server.zig");

/// Maximum length of a named palette identifier (bytes, not including null).
pub const PALETTE_NAME_MAX = 63;

/// A parsed IPC command. All variants are stack-allocated (no heap).
pub const IpcCommand = union(enum) {
    reload,
    set_palette: struct {
        name: [PALETTE_NAME_MAX + 1]u8,
        name_len: usize,

        pub fn nameSlice(self: *const @This()) []const u8 {
            return self.name[0..self.name_len];
        }
    },
    set_fps: u32,
    set_scale: f32,
    query,
    stop,
};

pub const ParseError = error{
    UnknownCommand,
    BadArgument,
    MissingArgument,
};

/// Parse a trimmed, newline-stripped command line into an IpcCommand.
/// Returns ParseError on malformed input.
pub fn parseLine(line: []const u8) ParseError!IpcCommand {
    const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);

    // Empty line → treat as no-op; caller can respond ok.
    if (trimmed.len == 0) return .query; // query is the cheapest safe no-op

    // Split into verb + optional argument.
    const space = std.mem.indexOfScalar(u8, trimmed, ' ');
    const verb = if (space) |s| trimmed[0..s] else trimmed;
    const rest = if (space) |s| std.mem.trimLeft(u8, trimmed[s + 1 ..], &std.ascii.whitespace) else "";

    if (std.mem.eql(u8, verb, "reload")) {
        return .reload;
    } else if (std.mem.eql(u8, verb, "query")) {
        return .query;
    } else if (std.mem.eql(u8, verb, "stop")) {
        return .stop;
    } else if (std.mem.eql(u8, verb, "set-fps")) {
        if (rest.len == 0) return error.MissingArgument;
        const fps = std.fmt.parseInt(u32, rest, 10) catch return error.BadArgument;
        return IpcCommand{ .set_fps = fps };
    } else if (std.mem.eql(u8, verb, "set-scale")) {
        if (rest.len == 0) return error.MissingArgument;
        const scale = std.fmt.parseFloat(f32, rest) catch return error.BadArgument;
        return IpcCommand{ .set_scale = scale };
    } else if (std.mem.eql(u8, verb, "set-palette")) {
        if (rest.len == 0) return error.MissingArgument;
        if (rest.len > PALETTE_NAME_MAX) return error.BadArgument;
        var cmd: IpcCommand = .{ .set_palette = .{
            .name = std.mem.zeroes([PALETTE_NAME_MAX + 1]u8),
            .name_len = rest.len,
        } };
        @memcpy(cmd.set_palette.name[0..rest.len], rest);
        return cmd;
    } else {
        return error.UnknownCommand;
    }
}

// --- Response helpers ---

/// Write "ok\n" to the client fd.
pub fn writeOk(fd: posix.fd_t) void {
    server_mod.IpcServer.writeLine(fd, "ok");
}

/// Write "error: <msg>\n" to the client fd.
pub fn writeError(fd: posix.fd_t, msg: []const u8) void {
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "error: {s}", .{msg}) catch "error: internal";
    server_mod.IpcServer.writeLine(fd, line);
}

/// Write "<key>=<value>\n" to the client fd.
pub fn writeKv(fd: posix.fd_t, key: []const u8, value: []const u8) void {
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s}={s}", .{ key, value }) catch return;
    server_mod.IpcServer.writeLine(fd, line);
}

/// Write "error: unknown command \"<verb>\"\n" for an unrecognised verb.
pub fn writeUnknownCommand(fd: posix.fd_t, verb: []const u8) void {
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "unknown command \"{s}\"", .{verb}) catch "unknown command";
    writeError(fd, msg);
}
