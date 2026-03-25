const std = @import("std");
const LockApp = @import("lock_app.zig").LockApp;
const config_mod = @import("config/config.zig");

pub fn main() u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config_path = parseArgs();

    // Resolve config path: --config arg → lock.toml → built-in defaults.
    const resolved_path = resolveLockConfigPath(allocator, config_path);
    defer if (resolved_path) |p| {
        // Only free if we heap-allocated the path (i.e. from resolveLockConfigPath).
        // Paths from --config are slices into argv and must not be freed.
        if (config_path == null) allocator.free(p);
    };

    if (resolved_path) |p| {
        std.debug.print("wlchroma-lock: using config: {s}\n", .{p});
    } else {
        std.debug.print("wlchroma-lock: using built-in defaults\n", .{});
    }

    const config = config_mod.loadConfig(allocator, resolved_path) catch |err| {
        std.debug.print("error: failed to load config: {}\n", .{err});
        return 2;
    };

    var app = LockApp.init(allocator, config) catch |err| {
        switch (err) {
            error.DisplayConnectFailed => std.debug.print("error: failed to connect to Wayland display\n", .{}),
            error.MissingSessionLockManager => {
                // message already printed in LockApp.init
            },
            error.MissingCompositor => std.debug.print("error: wl_compositor not available\n", .{}),
            error.MissingShm => std.debug.print("error: wl_shm not available\n", .{}),
            else => std.debug.print("error: startup failed: {}\n", .{err}),
        }
        return 2;
    };
    defer app.deinit();

    app.run() catch |err| {
        switch (err) {
            error.LockRejected => {
                std.debug.print("error: compositor rejected lock request\n", .{});
                return 1;
            },
            else => {
                std.debug.print("error: lock screen failed: {}\n", .{err});
                return 2;
            },
        }
    };

    return 0;
}

fn parseArgs() ?[]const u8 {
    var args = std.process.args();
    _ = args.next(); // skip argv[0]

    const first = args.next() orelse return null;

    if (std.mem.eql(u8, first, "--config") or std.mem.eql(u8, first, "-c")) {
        const path = args.next() orelse {
            std.debug.print("error: {s} requires a path argument\n", .{first});
            std.process.exit(2);
        };
        if (args.next()) |extra| {
            std.debug.print("error: unexpected argument '{s}'\n", .{extra});
            std.process.exit(2);
        }
        return path;
    }

    std.debug.print("error: unknown argument '{s}'\n", .{first});
    std.process.exit(2);
}

/// Resolve the lock config path:
///   1. --config <path> (passed in as `explicit`)
///   2. $XDG_CONFIG_HOME/wlchroma/lock.toml (or ~/.config/wlchroma/lock.toml)
///   3. null → caller uses built-in defaults
fn resolveLockConfigPath(allocator: std.mem.Allocator, explicit: ?[]const u8) ?[]const u8 {
    if (explicit) |p| return p;

    const path = if (std.posix.getenv("XDG_CONFIG_HOME")) |xdg|
        std.fmt.allocPrint(allocator, "{s}/wlchroma/lock.toml", .{xdg}) catch return null
    else blk: {
        const home = std.posix.getenv("HOME") orelse return null;
        break :blk std.fmt.allocPrint(allocator, "{s}/.config/wlchroma/lock.toml", .{home}) catch return null;
    };

    // Check if the file exists; if not, return null to use defaults.
    std.fs.accessAbsolute(path, .{}) catch {
        allocator.free(path);
        return null;
    };
    return path;
}
