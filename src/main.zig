const std = @import("std");
const App = @import("app.zig").App;
const config_mod = @import("config/config.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config_path = parseArgs();

    const config = config_mod.loadConfig(allocator, config_path) catch |err| {
        std.debug.print("fatal: failed to load config: {}\n", .{err});
        return err;
    };

    var app = try App.init(allocator, config);
    defer app.deinit();
    try app.run();
}

fn parseArgs() ?[]const u8 {
    var args = std.process.args();
    _ = args.next(); // skip argv[0]

    const first = args.next() orelse return null;

    if (std.mem.eql(u8, first, "--config") or std.mem.eql(u8, first, "-c")) {
        const path = args.next() orelse {
            std.debug.print("error: {s} requires a path argument\n", .{first});
            std.process.exit(1);
        };
        // Reject trailing arguments after --config <path>
        if (args.next()) |extra| {
            std.debug.print("error: unexpected argument '{s}'\n", .{extra});
            std.process.exit(1);
        }
        return path;
    }

    std.debug.print("error: unknown argument '{s}'\n", .{first});
    std.process.exit(1);
}
