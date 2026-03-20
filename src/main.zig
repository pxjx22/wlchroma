const std = @import("std");
const App = @import("app.zig").App;
const config_mod = @import("config/config.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = config_mod.loadConfig(allocator) catch |err| {
        std.debug.print("fatal: failed to load config: {}\n", .{err});
        return err;
    };

    var app = try App.init(allocator, config);
    defer app.deinit();
    try app.run();
}
