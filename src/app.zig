const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const c = @import("wl.zig").c;
const Registry = @import("wayland/registry.zig").Registry;
const OutputInfo = @import("wayland/output.zig").OutputInfo;
const SurfaceState = @import("wayland/surface_state.zig").SurfaceState;
const ColormixRenderer = @import("render/colormix.zig").ColormixRenderer;
const Effect = @import("render/effect.zig").Effect;
const EglContext = @import("render/egl_context.zig").EglContext;
const shader_mod = @import("render/shader.zig");
const BlitShader = shader_mod.BlitShader;
const EffectShader = @import("render/effect_shader.zig").EffectShader;
const defaults = @import("config/defaults.zig");
const config_mod = @import("config/config.zig");
const AppConfig = config_mod.AppConfig;
const UpscaleFilter = config_mod.UpscaleFilter;

pub const App = struct {
    allocator: std.mem.Allocator,
    display: *c.wl_display,
    registry: Registry,
    outputs: std.ArrayList(OutputInfo),
    surfaces: std.ArrayList(SurfaceState),
    effect: Effect,
    egl_ctx: ?EglContext,
    effect_shader: ?EffectShader,
    blit_shader: ?BlitShader,
    running: bool,
    frame_interval_ns: u32,
    renderer_scale: f32,
    upscale_filter: UpscaleFilter,

    pub fn init(allocator: std.mem.Allocator, config: AppConfig) !App {
        const display = c.wl_display_connect(null) orelse return error.DisplayConnectFailed;
        errdefer c.wl_display_disconnect(display);

        // Build effect from config first (before EGL check).
        var effect = Effect.init(&config);

        var app = App{
            .allocator = allocator,
            .display = display,
            .registry = Registry{},
            .outputs = .{},
            .surfaces = .{},
            .effect = effect,
            .egl_ctx = null,
            .effect_shader = null,
            .blit_shader = null,
            .running = true,
            .frame_interval_ns = config.frame_interval_ns,
            .renderer_scale = config.renderer_scale,
            .upscale_filter = config.upscale_filter,
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
        // reallocate the backing array.
        const MAX_OUTPUTS = 32;
        try app.outputs.ensureTotalCapacity(allocator, MAX_OUTPUTS);

        // 1st roundtrip: bind all globals (outputs appended to ArrayList).
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

        // GPU-only effect fallback: if EGL is unavailable and the selected
        // effect has no CPU path, override to colormix on the SHM path.
        if (app.egl_ctx == null and app.effect.isGpuOnly()) {
            const name = @tagName(config.effect_type);
            std.debug.print("effect {s} requires GPU; falling back to colormix on CPU path\n", .{name});
            effect = Effect{ .colormix = ColormixRenderer.init(
                config.palette[0],
                config.palette[1],
                config.palette[2],
                config.frame_advance_ms,
                config.speed,
            ) };
            app.effect = effect;
        }

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
                &self.effect,
                &self.running,
                if (self.egl_ctx) |*ctx| ctx else null,
                self.renderer_scale,
                self.upscale_filter,
            );
            try self.surfaces.append(self.allocator, surface_state);
        }

        // Attach listeners after all SurfaceStates are at their final addresses
        for (self.surfaces.items) |*s| {
            s.attach();
        }

        // Roundtrip to trigger configure events
        if (c.wl_display_roundtrip(self.display) < 0) return error.RoundtripFailed;

        // Initialize GLES2 effect shader using the first available EGL surface.
        if (self.egl_ctx) |*ctx| {
            var shader_ready = false;
            for (self.surfaces.items) |*s| {
                if (s.egl_surface) |*egl_surf| {
                    if (!egl_surf.makeCurrent(ctx)) {
                        std.debug.print("shader init: makeCurrent failed on a surface, trying next\n", .{});
                        continue;
                    }
                    self.effect_shader = EffectShader.init(&self.effect) catch |err| blk: {
                        std.debug.print("FATAL: EffectShader.init failed: {} -- " ++
                            "EGL surfaces will render black until shader is fixed\n", .{err});
                        break :blk null;
                    };
                    // Bind invariant GL state once -- program, VBO, vertex layout,
                    // and effect-specific static data (palette / phase).
                    if (self.effect_shader) |*sh| sh.bind(&self.effect);

                    // Initialize blit shader for offscreen upscale pass.
                    if (self.renderer_scale < 1.0) {
                        self.blit_shader = BlitShader.init() catch |err| blk: {
                            std.debug.print("BlitShader.init failed: {} -- offscreen rendering disabled\n", .{err});
                            break :blk null;
                        };
                        if (self.blit_shader) |*bs| {
                            bs.bind();
                        } else {
                            // Blit shader unavailable: tear down all offscreen FBOs.
                            for (self.surfaces.items) |*surf| {
                                if (surf.offscreen) |*ofs| {
                                    ofs.deinit();
                                    surf.offscreen = null;
                                }
                            }
                        }
                    }

                    shader_ready = true;
                    break;
                }
            }
            if (!shader_ready) {
                std.debug.print("warning: no EGL surface could be made current; GPU rendering disabled for this session\n", .{});
            }
        }

        // --- poll+timerfd main loop ---
        const tfd = try posix.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true });
        defer posix.close(tfd);

        const timer_ns: u32 = self.frame_interval_ns;
        std.debug.print("timer interval: {}ns ({}fps)\n", .{ timer_ns, 1_000_000_000 / @as(u64, timer_ns) });

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
            if (c.wl_display_flush(self.display) < 0) {
                std.debug.print("wl_display_flush error, exiting\n", .{});
                break;
            }

            const prep = c.wl_display_prepare_read(self.display);
            if (prep != 0) {
                _ = c.wl_display_dispatch_pending(self.display);
                continue;
            }

            fds[0].revents = 0;
            fds[1].revents = 0;
            _ = posix.poll(&fds, -1) catch |err| {
                c.wl_display_cancel_read(self.display);
                std.debug.print("poll error: {}\n", .{err});
                break;
            };

            if (fds[0].revents & (linux.POLL.HUP | linux.POLL.ERR) != 0) {
                c.wl_display_cancel_read(self.display);
                std.debug.print("Wayland socket HUP/ERR, compositor disconnected\n", .{});
                break;
            }

            if (fds[1].revents & (linux.POLL.HUP | linux.POLL.ERR) != 0) {
                c.wl_display_cancel_read(self.display);
                std.debug.print("timerfd HUP/ERR, exiting\n", .{});
                break;
            }

            if (fds[0].revents & linux.POLL.IN != 0) {
                if (c.wl_display_read_events(self.display) < 0) {
                    std.debug.print("wl_display_read_events error\n", .{});
                    break;
                }
            } else {
                c.wl_display_cancel_read(self.display);
            }

            _ = c.wl_display_dispatch_pending(self.display);

            if (fds[1].revents & linux.POLL.IN != 0) {
                var buf: [8]u8 = undefined;
                _ = posix.read(tfd, &buf) catch {};

                const sh_ptr: ?*const EffectShader = if (self.effect_shader) |*sh| sh else null;
                const blit_ptr: ?*const BlitShader = if (self.blit_shader) |*bs| bs else null;
                for (self.surfaces.items) |*s| {
                    s.renderTick(sh_ptr, blit_ptr);
                }

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
        if (self.blit_shader) |*bs| bs.deinit();
        self.blit_shader = null;
        if (self.effect_shader) |*sh| sh.deinit();
        self.effect_shader = null;

        // Unbind EGL context from the surface before destroying EGLSurfaces.
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
