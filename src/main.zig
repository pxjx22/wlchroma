const std = @import("std");
const App = @import("app.zig").App;
const config_mod = @import("config/config.zig");

pub fn main(init: std.process.Init) !void {
    // init.gpa is a leak-checking debug allocator in Debug builds and the
    // libc allocator in release builds.
    const allocator = init.gpa;

    const config_path = parseArgs(init.minimal.args);

    const load_result = config_mod.loadConfigFull(allocator, init.io, init.minimal.environ, config_path) catch |err| {
        std.debug.print("fatal: failed to load config: {}\n", .{err});
        return err;
    };

    var app = App.init(allocator, init.io, init.minimal.environ, load_result.config, load_result.palettes, config_path) catch |err| {
        allocator.free(load_result.palettes);
        return err;
    };
    defer app.deinit();
    // Listener registration happens here, once `app` is at its final address
    // (App.init returns by value; see App.setup doc comment).
    try app.setup();
    try app.run();
}

fn parseArgs(args_source: std.process.Args) ?[]const u8 {
    // Posix iterator yields slices of static argv memory, so the returned
    // path remains valid for the process lifetime.
    var args = args_source.iterate();
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
