const std = @import("std");
const c = @import("wl.zig").c;
const Registry = @import("wayland/registry.zig").Registry;
const OutputInfo = @import("wayland/output.zig").OutputInfo;
const SurfaceState = @import("wayland/surface_state.zig").SurfaceState;
const SolidColorRenderer = @import("render/solid.zig").SolidColorRenderer;
const defaults = @import("config/defaults.zig");

pub const App = struct {
    allocator: std.mem.Allocator,
    display: *c.wl_display,
    registry: Registry,
    outputs: std.ArrayList(OutputInfo),
    surfaces: std.ArrayList(SurfaceState),
    renderer: SolidColorRenderer,
    running: bool,

    pub fn init(allocator: std.mem.Allocator) !App {
        const display = c.wl_display_connect(null) orelse return error.DisplayConnectFailed;

        var app = App{
            .allocator = allocator,
            .display = display,
            .registry = Registry{},
            .outputs = .{},
            .surfaces = .{},
            .renderer = SolidColorRenderer.init(defaults.DEFAULT_COLOR),
            .running = true,
        };

        try app.registry.bind(display, &app.outputs, allocator);

        // 1st roundtrip: bind all globals
        _ = c.wl_display_roundtrip(display);
        // 2nd roundtrip: collect all output done events
        _ = c.wl_display_roundtrip(display);

        std.debug.print("bound: wl_compositor={} wl_shm={} zwlr_layer_shell_v1={}\n", .{
            app.registry.compositor != null,
            app.registry.shm != null,
            app.registry.layer_shell != null,
        });

        if (app.registry.compositor == null) return error.MissingCompositor;
        if (app.registry.shm == null) return error.MissingShm;
        if (app.registry.layer_shell == null) return error.MissingLayerShell;

        for (app.outputs.items) |*out| {
            if (out.done) {
                std.debug.print("output: {s} {}x{}\n", .{ out.name, out.width, out.height });
            }
        }

        return app;
    }

    pub fn run(self: *App) !void {
        // Pre-allocate to prevent ArrayList realloc invalidating SurfaceState pointers
        try self.surfaces.ensureTotalCapacity(self.allocator, self.outputs.items.len);

        for (self.outputs.items) |*out| {
            if (!out.done) continue;

            const surface_state = try SurfaceState.create(
                self.allocator,
                self.registry.compositor.?,
                self.registry.shm.?,
                self.registry.layer_shell.?,
                out,
                self.display,
                &self.renderer,
            );
            try self.surfaces.append(self.allocator, surface_state);
        }

        // Attach listeners after all SurfaceStates are at their final addresses
        for (self.surfaces.items) |*s| {
            s.attach();
        }

        // Roundtrip to trigger configure events
        _ = c.wl_display_roundtrip(self.display);

        // Main event loop
        while (self.running) {
            const ret = c.wl_display_dispatch(self.display);
            if (ret < 0) {
                std.debug.print("wl_display_dispatch error\n", .{});
                break;
            }
        }
    }

    pub fn deinit(self: *App) void {
        for (self.surfaces.items) |*s| {
            s.deinit(self.display);
        }
        self.surfaces.deinit(self.allocator);

        for (self.outputs.items) |*out| {
            out.deinit();
        }
        self.outputs.deinit(self.allocator);

        self.registry.deinit();
        c.wl_display_disconnect(self.display);
    }
};
