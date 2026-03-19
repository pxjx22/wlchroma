const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const c = @import("wl.zig").c;
const Registry = @import("wayland/registry.zig").Registry;
const OutputInfo = @import("wayland/output.zig").OutputInfo;
const SurfaceState = @import("wayland/surface_state.zig").SurfaceState;
const ColormixRenderer = @import("render/colormix.zig").ColormixRenderer;
const EglContext = @import("render/egl_context.zig").EglContext;
const defaults = @import("config/defaults.zig");

pub const App = struct {
    allocator: std.mem.Allocator,
    display: *c.wl_display,
    registry: Registry,
    outputs: std.ArrayList(OutputInfo),
    surfaces: std.ArrayList(SurfaceState),
    renderer: ColormixRenderer,
    egl_ctx: ?EglContext,
    running: bool,

    pub fn init(allocator: std.mem.Allocator) !App {
        const display = c.wl_display_connect(null) orelse return error.DisplayConnectFailed;

        var app = App{
            .allocator = allocator,
            .display = display,
            .registry = Registry{},
            .outputs = .{},
            .surfaces = .{},
            .renderer = ColormixRenderer.init(defaults.DEFAULT_COL1, defaults.DEFAULT_COL2, defaults.DEFAULT_COL3),
            .egl_ctx = null,
            .running = true,
        };

        try app.registry.bind(display, &app.outputs, allocator);

        // 1st roundtrip: bind all globals (outputs appended to ArrayList)
        _ = c.wl_display_roundtrip(display);

        // Attach wl_output listeners now that the ArrayList is stable --
        // no more appends will invalidate item pointers.
        for (app.outputs.items) |*out| {
            if (out.wl_output) |wl_out| {
                _ = c.wl_output_add_listener(wl_out, &@import("wayland/output.zig").output_listener, out);
            }
        }

        // 2nd roundtrip: collect all output done events
        _ = c.wl_display_roundtrip(display);

        std.debug.print("bound: wl_compositor={} wl_shm={} zwlr_layer_shell_v1={}\n", .{
            app.registry.compositor != null,
            app.registry.shm != null,
            app.registry.layer_shell != null,
        });

        app.egl_ctx = EglContext.init(display) catch |err| blk: {
            std.debug.print("EGL init failed: {}, falling back to CPU path\n", .{err});
            break :blk null;
        };

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
                &self.running,
            );
            try self.surfaces.append(self.allocator, surface_state);
        }

        // Attach listeners after all SurfaceStates are at their final addresses
        for (self.surfaces.items) |*s| {
            s.attach();
        }

        // Roundtrip to trigger configure events
        _ = c.wl_display_roundtrip(self.display);

        // --- poll+timerfd main loop ---
        // Create a timerfd that fires every 33ms (~30fps) using CLOCK_MONOTONIC.
        // This replaces vblank-rate wakeups with render-rate wakeups.
        const tfd_rc = linux.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true });
        const tfd_errno = linux.E.init(tfd_rc);
        if (tfd_errno != .SUCCESS) {
            std.debug.print("timerfd_create failed: {}\n", .{tfd_errno});
            return error.TimerfdCreateFailed;
        }
        const tfd: posix.fd_t = @intCast(tfd_rc);
        defer posix.close(tfd);

        // Arm: first fire in 33ms, repeat every 33ms
        const interval = linux.itimerspec{
            .it_value = .{ .sec = 0, .nsec = 33_333_333 },
            .it_interval = .{ .sec = 0, .nsec = 33_333_333 },
        };
        const set_rc = linux.timerfd_settime(tfd, .{}, &interval, null);
        const set_errno = linux.E.init(set_rc);
        if (set_errno != .SUCCESS) {
            std.debug.print("timerfd_settime failed: {}\n", .{set_errno});
            return error.TimerfdSetTimeFailed;
        }

        const wl_fd: posix.fd_t = c.wl_display_get_fd(self.display);

        var fds = [2]posix.pollfd{
            .{ .fd = wl_fd, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = tfd, .events = linux.POLL.IN, .revents = 0 },
        };

        while (self.running) {
            // Flush outgoing Wayland requests before sleeping in poll.
            // wl_display_flush returns -1 on fatal error (e.g. broken pipe).
            if (c.wl_display_flush(self.display) < 0) {
                std.debug.print("wl_display_flush error, exiting\n", .{});
                break;
            }

            // Prepare to read Wayland events. This must be done before
            // poll() to avoid a race where events arrive between the last
            // dispatch and the poll call. If prepare_read fails (-1), there
            // are already queued events -- dispatch them immediately.
            const prep = c.wl_display_prepare_read(self.display);
            if (prep != 0) {
                // Events already queued, dispatch without blocking
                _ = c.wl_display_dispatch_pending(self.display);
                continue;
            }

            // Block until the Wayland socket or timerfd is readable.
            fds[0].revents = 0;
            fds[1].revents = 0;
            _ = posix.poll(&fds, -1) catch |err| {
                c.wl_display_cancel_read(self.display);
                std.debug.print("poll error: {}\n", .{err});
                break;
            };

            // Read Wayland events if the socket is readable
            if (fds[0].revents & linux.POLL.IN != 0) {
                if (c.wl_display_read_events(self.display) < 0) {
                    std.debug.print("wl_display_read_events error\n", .{});
                    break;
                }
            } else {
                // No Wayland data -- cancel the prepared read
                c.wl_display_cancel_read(self.display);
            }

            // Dispatch any pending Wayland events (frame callbacks,
            // configure, buffer release, etc.)
            _ = c.wl_display_dispatch_pending(self.display);

            // Timer tick -- attempt render on all surfaces
            if (fds[1].revents & linux.POLL.IN != 0) {
                // Drain the timerfd (8-byte expiration count)
                var buf: [8]u8 = undefined;
                _ = posix.read(tfd, &buf) catch {};

                for (self.surfaces.items) |*s| {
                    s.renderTick();
                }
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

        if (self.egl_ctx) |*ctx| ctx.deinit();

        self.registry.deinit();
        c.wl_display_disconnect(self.display);
    }
};
