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
const NamedPalette = config_mod.NamedPalette;
const UpscaleFilter = config_mod.UpscaleFilter;
const server_mod = @import("ipc/server.zig");
const IpcServer = server_mod.IpcServer;
const dispatch = @import("ipc/dispatch.zig");

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
    // --- IPC fields (T009) ---
    tfd: posix.fd_t,
    ipc_server: ?IpcServer,
    /// Config path for reload. Null when wlchroma was started without --config
    /// and no default config file was found.
    config_path: ?[]const u8,
    /// Named palettes loaded from [[palettes]] config table. Owned by App.
    palettes: []NamedPalette,
    /// Name of the currently active palette, or zero-length = "custom".
    active_palette_name_buf: [64]u8,
    active_palette_name_len: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        config: AppConfig,
        palettes: []NamedPalette,
        config_path: ?[]const u8,
    ) !App {
        const display = c.wl_display_connect(null) orelse return error.DisplayConnectFailed;
        errdefer c.wl_display_disconnect(display);

        // Build effect from config first (before EGL check).
        var effect = Effect.init(&config);

        // Create the timerfd here so it is accessible as a field for set_fps.
        const tfd = try posix.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true });
        errdefer posix.close(tfd);

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
            .tfd = tfd,
            .ipc_server = null,
            .config_path = config_path,
            .palettes = palettes,
            .active_palette_name_buf = std.mem.zeroes([64]u8),
            .active_palette_name_len = 0,
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

        // Start IPC server. Failure is non-fatal (Constitution III: graceful degradation).
        app.ipc_server = IpcServer.init() catch |err| blk: {
            std.debug.print("ipc: failed to start IPC server: {} — continuing without IPC\n", .{err});
            break :blk null;
        };

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
        // tfd was created in App.init and stored as self.tfd.
        const tfd = self.tfd;

        const timer_ns: u32 = self.frame_interval_ns;
        std.debug.print("timer interval: {}ns ({}fps)\n", .{ timer_ns, 1_000_000_000 / @as(u64, timer_ns) });

        const interval = linux.itimerspec{
            .it_value = .{ .sec = 0, .nsec = timer_ns },
            .it_interval = .{ .sec = 0, .nsec = timer_ns },
        };
        try posix.timerfd_settime(tfd, .{}, &interval, null);

        const wl_fd: posix.fd_t = c.wl_display_get_fd(self.display);
        const ipc_fd: posix.fd_t = if (self.ipc_server) |*srv| srv.fd else -1;

        var fds = [3]posix.pollfd{
            .{ .fd = wl_fd, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = tfd, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = ipc_fd, .events = linux.POLL.IN, .revents = 0 },
        };
        // How many fds are active in the poll call.
        const nfds: u32 = if (self.ipc_server != null) 3 else 2;

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
            fds[2].revents = 0;
            _ = posix.poll(fds[0..nfds], -1) catch |err| {
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

            // Handle incoming IPC command (fds[2]).
            if (nfds == 3 and fds[2].revents & linux.POLL.IN != 0) {
                self.handleIpcEvent();
            }
        }
    }

    /// Accept one IPC client connection, read a command line, dispatch it,
    /// write the response, and close the client fd.
    fn handleIpcEvent(self: *App) void {
        var srv = &(self.ipc_server orelse return);
        const client_fd = srv.accept() catch |err| {
            std.debug.print("ipc: accept failed: {}\n", .{err});
            return;
        };
        defer posix.close(client_fd);

        var line_buf: [server_mod.LINE_MAX + 1]u8 = undefined;
        const line = IpcServer.readLine(client_fd, &line_buf) catch |err| {
            std.debug.print("ipc: readLine failed: {}\n", .{err});
            return;
        };

        const cmd = dispatch.parseLine(line) catch |err| switch (err) {
            error.UnknownCommand => {
                // Extract verb for the error message.
                const space = std.mem.indexOfScalar(u8, line, ' ');
                const verb = if (space) |s| line[0..s] else line;
                dispatch.writeUnknownCommand(client_fd, verb);
                return;
            },
            error.MissingArgument => {
                dispatch.writeError(client_fd, "missing argument");
                return;
            },
            error.BadArgument => {
                dispatch.writeError(client_fd, "invalid argument");
                return;
            },
        };

        self.dispatchCommand(client_fd, cmd);
    }

    /// Execute a parsed IpcCommand against the live App state.
    fn dispatchCommand(self: *App, client_fd: posix.fd_t, cmd: dispatch.IpcCommand) void {
        switch (cmd) {
            .query => self.handleQuery(client_fd),
            .stop => self.handleStop(client_fd),
            .set_fps => |fps| self.handleSetFps(client_fd, fps),
            .set_scale => |scale| self.handleSetScale(client_fd, scale),
            .set_palette => |args| self.handleSetPalette(client_fd, args.nameSlice()),
            .reload => self.handleReload(client_fd),
        }
    }

    // --- IPC command handlers (stubs — filled in per user story phase) ---

    fn handleQuery(self: *App, client_fd: posix.fd_t) void {
        // effect=<tag name>
        dispatch.writeKv(client_fd, "effect", @tagName(self.effect));

        // fps=<computed from frame_interval_ns>
        const fps = 1_000_000_000 / @as(u64, self.frame_interval_ns);
        var fps_buf: [16]u8 = undefined;
        const fps_str = std.fmt.bufPrint(&fps_buf, "{}", .{fps}) catch "?";
        dispatch.writeKv(client_fd, "fps", fps_str);

        // scale=<2 decimal places>
        var scale_buf: [16]u8 = undefined;
        const scale_str = std.fmt.bufPrint(&scale_buf, "{d:.2}", .{self.renderer_scale}) catch "?";
        dispatch.writeKv(client_fd, "scale", scale_str);

        // palette=<active name or "custom">
        const palette_name: []const u8 = if (self.active_palette_name_len > 0)
            self.active_palette_name_buf[0..self.active_palette_name_len]
        else
            "custom";
        dispatch.writeKv(client_fd, "palette", palette_name);

        dispatch.writeOk(client_fd);
    }

    fn handleStop(self: *App, client_fd: posix.fd_t) void {
        dispatch.writeError(client_fd, "not implemented");
        _ = self;
    }

    fn handleSetFps(self: *App, client_fd: posix.fd_t, fps: u32) void {
        if (fps < 1 or fps > 240) {
            dispatch.writeError(client_fd, "fps must be in range [1, 240]");
            return;
        }
        const interval_ns: u32 = @intCast(1_000_000_000 / @as(u64, fps));
        const interval = linux.itimerspec{
            .it_value = .{ .sec = 0, .nsec = interval_ns },
            .it_interval = .{ .sec = 0, .nsec = interval_ns },
        };
        posix.timerfd_settime(self.tfd, .{}, &interval, null) catch |err| {
            var buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "timerfd_settime failed: {}", .{err}) catch "timerfd_settime failed";
            dispatch.writeError(client_fd, msg);
            return;
        };
        self.frame_interval_ns = interval_ns;
        dispatch.writeOk(client_fd);
    }

    fn handleSetScale(self: *App, client_fd: posix.fd_t, scale: f32) void {
        if (scale <= 0.0 or scale > 4.0) {
            dispatch.writeError(client_fd, "scale must be in range (0.0, 4.0]");
            return;
        }
        self.renderer_scale = scale;
        for (self.surfaces.items) |*s| {
            s.renderer_scale = scale;
        }
        dispatch.writeOk(client_fd);
    }

    fn handleSetPalette(self: *App, client_fd: posix.fd_t, name: []const u8) void {
        // Look up the named palette in the loaded palette list.
        var found: ?[3]defaults.Rgb = null;
        for (self.palettes) |*p| {
            if (std.mem.eql(u8, p.nameSlice(), name)) {
                found = p.colors;
                break;
            }
        }
        const colors = found orelse {
            var buf: [96]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "unknown palette \"{s}\"", .{name}) catch "unknown palette";
            dispatch.writeError(client_fd, msg);
            return;
        };
        self.effect.updatePalette(colors);
        if (self.effect_shader) |*sh| sh.bind(&self.effect);
        // Record active palette name.
        const copy_len = @min(name.len, self.active_palette_name_buf.len);
        @memcpy(self.active_palette_name_buf[0..copy_len], name[0..copy_len]);
        self.active_palette_name_len = copy_len;
        dispatch.writeOk(client_fd);
    }

    fn handleReload(self: *App, client_fd: posix.fd_t) void {
        const path = self.config_path orelse {
            dispatch.writeError(client_fd, "no config path known");
            return;
        };
        const load_result = config_mod.loadConfigFull(self.allocator, path) catch |err| {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "config parse error: {}", .{err}) catch "config parse error";
            dispatch.writeError(client_fd, msg);
            return;
        };
        // Apply new config — update fields without tearing down EGL or surfaces.
        // 1. fps / timerfd
        const new_interval_ns = load_result.config.frame_interval_ns;
        const new_interval = linux.itimerspec{
            .it_value = .{ .sec = 0, .nsec = new_interval_ns },
            .it_interval = .{ .sec = 0, .nsec = new_interval_ns },
        };
        posix.timerfd_settime(self.tfd, .{}, &new_interval, null) catch {};
        self.frame_interval_ns = new_interval_ns;
        // 2. renderer_scale
        self.renderer_scale = load_result.config.renderer_scale;
        for (self.surfaces.items) |*s| {
            s.renderer_scale = load_result.config.renderer_scale;
        }
        // 3. palette colors (stays within the same effect type — no shader rebind type mismatch)
        self.effect.updatePalette(load_result.config.palette);
        if (self.effect_shader) |*sh| sh.bind(&self.effect);
        // 4. named palettes — replace the owned slice
        self.allocator.free(self.palettes);
        self.palettes = load_result.palettes;
        // 5. reset active palette name (reload resets to config colors, i.e. "custom")
        self.active_palette_name_len = 0;
        dispatch.writeOk(client_fd);
    }

    pub fn deinit(self: *App) void {
        if (self.ipc_server) |*srv| srv.deinit();
        self.ipc_server = null;
        self.allocator.free(self.palettes);
        posix.close(self.tfd);

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
