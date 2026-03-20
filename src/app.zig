const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const c = @import("wl.zig").c;
const Registry = @import("wayland/registry.zig").Registry;
const OutputInfo = @import("wayland/output.zig").OutputInfo;
const SurfaceState = @import("wayland/surface_state.zig").SurfaceState;
const ColormixRenderer = @import("render/colormix.zig").ColormixRenderer;
const EglContext = @import("render/egl_context.zig").EglContext;
const ShaderProgram = @import("render/shader.zig").ShaderProgram;
const defaults = @import("config/defaults.zig");

pub const App = struct {
    allocator: std.mem.Allocator,
    display: *c.wl_display,
    registry: Registry,
    outputs: std.ArrayList(OutputInfo),
    surfaces: std.ArrayList(SurfaceState),
    renderer: ColormixRenderer,
    egl_ctx: ?EglContext,
    shader: ?ShaderProgram,
    running: bool,

    pub fn init(allocator: std.mem.Allocator) !App {
        const display = c.wl_display_connect(null) orelse return error.DisplayConnectFailed;
        errdefer c.wl_display_disconnect(display);

        var app = App{
            .allocator = allocator,
            .display = display,
            .registry = Registry{},
            .outputs = .{},
            .surfaces = .{},
            .renderer = ColormixRenderer.init(defaults.DEFAULT_COL1, defaults.DEFAULT_COL2, defaults.DEFAULT_COL3),
            .egl_ctx = null,
            .shader = null,
            .running = true,
        };
        errdefer app.registry.deinit();
        errdefer {
            for (app.outputs.items) |*out| out.deinit();
            app.outputs.deinit(allocator);
        }
        errdefer if (app.egl_ctx) |*ctx| ctx.deinit();

        try app.registry.bind(display, &app.outputs, allocator);

        // Pre-reserve capacity so that appends from registryGlobal (both
        // during the startup roundtrip and from runtime hotplug) never
        // reallocate the backing array.  This keeps item pointers stable
        // for use as wl_output listener userdata.
        const MAX_OUTPUTS = 32;
        try app.outputs.ensureTotalCapacity(allocator, MAX_OUTPUTS);

        // 1st roundtrip: bind all globals (outputs appended to ArrayList).
        // registryGlobal now attaches wl_output listeners immediately on
        // append, which is safe because capacity is pre-reserved above.
        if (c.wl_display_roundtrip(display) < 0) return error.RoundtripFailed;

        // 2nd roundtrip: collect all output done events
        if (c.wl_display_roundtrip(display) < 0) return error.RoundtripFailed;

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
                std.debug.print("output: {s} {}x{} refresh={}mHz\n", .{ out.name, out.width, out.height, out.refresh_mhz });
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
                if (self.egl_ctx) |*ctx| ctx else null,
            );
            try self.surfaces.append(self.allocator, surface_state);
        }

        // Attach listeners after all SurfaceStates are at their final addresses
        for (self.surfaces.items) |*s| {
            s.attach();
        }

        // Roundtrip to trigger configure events
        if (c.wl_display_roundtrip(self.display) < 0) return error.RoundtripFailed;

        // Initialize GLES2 shader program using the first available EGL surface.
        // The EGL context must be current on this thread before creating GL objects.
        // Try each surface in turn -- if makeCurrent fails on one (e.g. bad
        // driver state), continue to the next rather than giving up entirely.
        if (self.egl_ctx) |*ctx| {
            var shader_ready = false;
            for (self.surfaces.items) |*s| {
                if (s.egl_surface) |*egl_surf| {
                    if (!egl_surf.makeCurrent(ctx)) {
                        std.debug.print("shader init: makeCurrent failed on a surface, trying next\n", .{});
                        continue;
                    }
                    self.shader = ShaderProgram.init() catch |err| blk: {
                        std.debug.print("FATAL: ShaderProgram.init failed: {} -- " ++
                            "EGL surfaces will render black until shader is fixed\n", .{err});
                        break :blk null;
                    };
                    // Bind invariant GL state once -- program, VBO, vertex
                    // layout. Persists across frames for this single-program
                    // setup. draw() only uploads per-frame uniforms.
                    if (self.shader) |*sh| sh.bind(&self.renderer.palette_data);
                    shader_ready = true;
                    break;
                }
            }
            if (!shader_ready) {
                std.debug.print("warning: no EGL surface could be made current; GPU rendering disabled for this session\n", .{});
            }
        }

        // --- poll+timerfd main loop ---
        // Create a timerfd that fires at a fixed 15fps (~66.7ms) cadence.
        // Fixed 15fps is intentional: this is a low-power wallpaper engine
        // targeting an ASCII/TUI aesthetic. Output refresh rates are stored
        // in OutputInfo.refresh_mhz but are intentionally not used for pacing.
        const tfd = try posix.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true });
        defer posix.close(tfd);

        const timer_ns: u32 = defaults.FRAME_INTERVAL_NS;
        std.debug.print("timer interval: {}ns (fixed 15fps low-power)\n", .{timer_ns});

        const interval = linux.itimerspec{
            .it_value = .{ .sec = 0, .nsec = timer_ns },
            .it_interval = .{ .sec = 0, .nsec = timer_ns },
        };
        try posix.timerfd_settime(tfd, .{}, &interval, null);

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

            // Check for Wayland socket hangup/error (compositor disconnect)
            if (fds[0].revents & (linux.POLL.HUP | linux.POLL.ERR) != 0) {
                c.wl_display_cancel_read(self.display);
                std.debug.print("Wayland socket HUP/ERR, compositor disconnected\n", .{});
                break;
            }

            // Check for timerfd hangup/error
            if (fds[1].revents & (linux.POLL.HUP | linux.POLL.ERR) != 0) {
                c.wl_display_cancel_read(self.display);
                std.debug.print("timerfd HUP/ERR, exiting\n", .{});
                break;
            }

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

            // Timer tick -- attempt render on all surfaces.
            // At 15fps, wakeups during backpressure (all SHM buffers busy or
            // frame callback pending) are cheap no-ops: drain timerfd + iterate
            // surfaces. The missed frame is acceptable at this power target and
            // the next tick recovers. A future optimization could disarm the
            // timerfd while all surfaces are backpressured and re-arm on the
            // next frame callback, but the overhead is negligible.
            if (fds[1].revents & linux.POLL.IN != 0) {
                // Drain the timerfd (8-byte expiration count)
                var buf: [8]u8 = undefined;
                _ = posix.read(tfd, &buf) catch {};

                const sh_ptr: ?*const ShaderProgram = if (self.shader) |*sh| sh else null;
                for (self.surfaces.items) |*s| {
                    s.renderTick(sh_ptr);
                }

                // If all surfaces are dead (e.g. all outputs unplugged),
                // exit gracefully instead of spinning.
                var any_alive = false;
                for (self.surfaces.items) |*s| {
                    if (!s.dead) {
                        any_alive = true;
                        break;
                    }
                }
                if (!any_alive) {
                    std.debug.print("all surfaces dead, exiting\n", .{});
                    self.running = false;
                }
            }
        }
    }

    pub fn deinit(self: *App) void {
        // Make EGL context current so GL object deletion works.
        if (self.egl_ctx) |*ctx| {
            var made_current = false;
            for (self.surfaces.items) |*s| {
                if (s.dead) continue;
                if (s.egl_surface) |*egl_surf| {
                    made_current = egl_surf.makeCurrent(ctx);
                    if (!made_current) {
                        std.debug.print("deinit: eglMakeCurrent failed, GL cleanup may be incomplete\n", .{});
                    }
                    break;
                }
            }
        }
        if (self.shader) |*sh| sh.deinit();
        self.shader = null;

        // Unbind EGL context from the surface before destroying EGLSurfaces.
        // eglDestroySurface on a current surface is implementation-defined;
        // unbinding first is the safe portable path.
        if (self.egl_ctx) |*ctx| {
            _ = c.eglMakeCurrent(ctx.display, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, c.EGL_NO_CONTEXT);
        }

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
