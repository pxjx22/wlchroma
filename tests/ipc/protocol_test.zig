const std = @import("std");
const dispatch = @import("dispatch");
const IpcCommand = dispatch.IpcCommand;
const parseLine = dispatch.parseLine;
const PALETTE_NAME_MAX = dispatch.PALETTE_NAME_MAX;

// --- reload ---

test "parseLine: reload" {
    const cmd = try parseLine("reload");
    try std.testing.expectEqual(IpcCommand.reload, cmd);
}

test "parseLine: reload with trailing whitespace" {
    const cmd = try parseLine("reload   ");
    try std.testing.expectEqual(IpcCommand.reload, cmd);
}

// --- query ---

test "parseLine: query" {
    const cmd = try parseLine("query");
    try std.testing.expectEqual(IpcCommand.query, cmd);
}

test "parseLine: empty line → query" {
    const cmd = try parseLine("");
    try std.testing.expectEqual(IpcCommand.query, cmd);
}

test "parseLine: whitespace-only line → query" {
    const cmd = try parseLine("   ");
    try std.testing.expectEqual(IpcCommand.query, cmd);
}

// --- stop ---

test "parseLine: stop" {
    const cmd = try parseLine("stop");
    try std.testing.expectEqual(IpcCommand.stop, cmd);
}

// --- set-fps ---

test "parseLine: set-fps valid" {
    const cmd = try parseLine("set-fps 60");
    try std.testing.expectEqual(@as(u32, 60), cmd.set_fps);
}

test "parseLine: set-fps 1" {
    const cmd = try parseLine("set-fps 1");
    try std.testing.expectEqual(@as(u32, 1), cmd.set_fps);
}

test "parseLine: set-fps 240" {
    const cmd = try parseLine("set-fps 240");
    try std.testing.expectEqual(@as(u32, 240), cmd.set_fps);
}

test "parseLine: set-fps missing argument → MissingArgument" {
    const result = parseLine("set-fps");
    try std.testing.expectError(error.MissingArgument, result);
}

test "parseLine: set-fps non-numeric → BadArgument" {
    const result = parseLine("set-fps fast");
    try std.testing.expectError(error.BadArgument, result);
}

test "parseLine: set-fps float → BadArgument" {
    const result = parseLine("set-fps 60.5");
    try std.testing.expectError(error.BadArgument, result);
}

// --- set-scale ---

test "parseLine: set-scale 0.5" {
    const cmd = try parseLine("set-scale 0.5");
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), cmd.set_scale, 1e-6);
}

test "parseLine: set-scale 1.0" {
    const cmd = try parseLine("set-scale 1.0");
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), cmd.set_scale, 1e-6);
}

test "parseLine: set-scale missing argument → MissingArgument" {
    const result = parseLine("set-scale");
    try std.testing.expectError(error.MissingArgument, result);
}

test "parseLine: set-scale non-numeric → BadArgument" {
    const result = parseLine("set-scale big");
    try std.testing.expectError(error.BadArgument, result);
}

// --- set-palette ---

test "parseLine: set-palette valid name" {
    const cmd = try parseLine("set-palette ocean");
    try std.testing.expectEqualStrings("ocean", cmd.set_palette.nameSlice());
}

test "parseLine: set-palette name with hyphens" {
    const cmd = try parseLine("set-palette nord-dark");
    try std.testing.expectEqualStrings("nord-dark", cmd.set_palette.nameSlice());
}

test "parseLine: set-palette 63-char name (max)" {
    const name = "a" ** PALETTE_NAME_MAX;
    var line_buf: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "set-palette {s}", .{name}) catch unreachable;
    const cmd = try parseLine(line);
    try std.testing.expectEqualStrings(name, cmd.set_palette.nameSlice());
}

test "parseLine: set-palette 64-char name (too long) → BadArgument" {
    const name = "a" ** (PALETTE_NAME_MAX + 1);
    var line_buf: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "set-palette {s}", .{name}) catch unreachable;
    const result = parseLine(line);
    try std.testing.expectError(error.BadArgument, result);
}

test "parseLine: set-palette missing argument → MissingArgument" {
    const result = parseLine("set-palette");
    try std.testing.expectError(error.MissingArgument, result);
}

// --- unknown verb ---

test "parseLine: unknown command → UnknownCommand" {
    const result = parseLine("frobnicate");
    try std.testing.expectError(error.UnknownCommand, result);
}

test "parseLine: unknown command with argument → UnknownCommand" {
    const result = parseLine("teleport mars");
    try std.testing.expectError(error.UnknownCommand, result);
}
