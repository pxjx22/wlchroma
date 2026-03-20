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

        try app.registry.bind(display, &app.outputs, allocator);

        // 1st roundtrip: bind all globals (outputs appended to ArrayList)
        if (c.wl_display_roundtrip(display) < 0) return error.RoundtripFailed;

        // Attach wl_output listeners now that the ArrayList is stable --
        // no more appends will invalidate item pointers.
        for (app.outputs.items) |*out| {
            if (out.wl_output) |wl_out| {
                _ = c.wl_output_add_listener(wl_out, &@import("wayland/output.zig").output_listener, out);
            }
        }

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
        if (self.egl_ctx) |*ctx| {
            for (self.surfaces.items) |*s| {
                if (s.egl_surface) |*egl_surf| {
                    if (egl_surf.makeCurrent(ctx)) {
                        self.shader = ShaderProgram.init() catch |err| blk: {
                            std.debug.print("FATAL: ShaderProgram.init failed: {} -- " ++
                                "EGL surfaces will render black until shader is fixed\n", .{err});
                            break :blk null;
                        };
                        // Bind invariant GL state once -- program, VBO, vertex
                        // layout. Persists across frames for this single-program
                        // setup. draw() only uploads per-frame uniforms.
                        if (self.shader) |*sh| sh.bind(&self.renderer.palette_data);
                    }
                    break;
                }
            }
        }

        // --- poll+timerfd main loop ---
        // Create a timerfd that fires at the render rate using CLOCK_MONOTONIC.
        // Derive interval from the fastest output's refresh rate so we can
        // produce frames at the display's native cadence. Falls back to ~30fps
        // (33ms) if no output reports a refresh rate.
        const tfd = try posix.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true });
        defer posix.close(tfd);

        // Find max refresh_mhz across all outputs to determine timer cadence.
        var max_refresh_mhz: i32 = 0;
        for (self.outputs.items) |*out| {
            if (out.done and out.refresh_mhz > max_refresh_mhz) {
                max_refresh_mhz = out.refresh_mhz;
            }
        }
        const timer_ns: u32 = if (max_refresh_mhz > 0)
            @intCast(@divFloor(@as(u64, 1_000_000_000_000), @as(u64, @intCast(max_refresh_mhz))))
        else
            33_333_333; // ~30fps fallback
        std.debug.print("timer interval: {}ns (from max refresh {}mHz)\n", .{ timer_ns, max_refresh_mhz });

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
            // When all surfaces are backpressured (frame_callback != null),
            // renderTick returns immediately for each surface, making this
            // wakeup a cheap no-op (drain timerfd + iterate surfaces). A
            // future optimization could disarm the timerfd while all surfaces
            // are backpressured and re-arm on the next frame callback, but
            // the overhead is negligible for the current surface count.
            if (fds[1].revents & linux.POLL.IN != 0) {
                // Drain the timerfd (8-byte expiration count)
                var buf: [8]u8 = undefined;
                _ = posix.read(tfd, &buf) catch {};

                const sh_ptr: ?*const ShaderProgram = if (self.shader) |*sh| sh else null;
                for (self.surfaces.items) |*s| {
                    s.renderTick(sh_ptr);
                }
            }
        }
    }

    pub fn deinit(self: *App) void {
        // Make EGL context current so GL object deletion works.
        if (self.egl_ctx) |*ctx| {
            var made_current = false;
            for (self.surfaces.items) |*s| {
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
