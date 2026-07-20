const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;
const c = @import("wl.zig").c;
const Registry = @import("wayland/registry.zig").Registry;
const OutputInfo = @import("wayland/output.zig").OutputInfo;
const SurfaceState = @import("wayland/surface_state.zig").SurfaceState;
const ColormixRenderer = @import("render/colormix.zig").ColormixRenderer;
const Effect = @import("render/effect.zig").Effect;
const EglContext = @import("render/egl_context.zig").EglContext;
const gpu_epoch = @import("render/gpu_epoch.zig");
const shader_mod = @import("render/shader.zig");
const BlitShader = shader_mod.BlitShader;
const EffectShader = @import("render/effect_shader.zig").EffectShader;
const color_fade = @import("render/color_fade.zig");
const defaults = @import("config/defaults.zig");
const config_mod = @import("config/config.zig");
const AppConfig = config_mod.AppConfig;
const NamedPalette = config_mod.NamedPalette;
const UpscaleFilter = config_mod.UpscaleFilter;
const server_mod = @import("ipc/server.zig");
const IpcServer = server_mod.IpcServer;
const connection_mod = @import("ipc/connection.zig");
const IpcConnection = connection_mod.IpcConnection;
const ResponseQueue = connection_mod.ResponseQueue;
const dispatch = @import("ipc/dispatch.zig");
const signal_fd = @import("signal_fd.zig");
const sys = @import("sys");

pub const App = struct {
    allocator: std.mem.Allocator,
    /// Io interface and environment from std.process.Init, retained for
    /// config reloads (file reads and XDG path resolution).
    io: std.Io,
    environ: std.process.Environ,
    display: *c.wl_display,
    registry: Registry,
    /// Heap-allocated per-object so addresses handed to libwayland as
    /// listener userdata stay valid regardless of list growth or removal.
    outputs: std.ArrayList(*OutputInfo),
    surfaces: std.ArrayList(*SurfaceState),
    detached_gpu: std.ArrayList(SurfaceState.DetachedGpu),
    effect: Effect,
    egl_ctx: ?EglContext,
    effect_shader: ?EffectShader,
    blit_shader: ?BlitShader,
    /// Set when GPU pipeline init failed permanently (shader compile/link or
    /// no surface could be made current); prevents retrying every tick.
    gpu_pipeline_failed: bool,
    /// Frame timer state: armed while at least one surface exists, disarmed
    /// at zero surfaces so an output-less daemon sleeps at ~0% CPU.
    timer_armed: bool,
    running: bool,
    frame_interval_ns: u32,
    renderer_scale: f32,
    upscale_filter: UpscaleFilter,
    // --- IPC fields (T009) ---
    tfd: posix.fd_t,
    sig_fd: posix.fd_t,
    ipc_server: ?IpcServer,
    ipc_client: ?IpcConnection,
    /// Config path for reload. Null when wlchroma was started without --config
    /// and no default config file was found.
    config_path: ?[]const u8,
    /// Named palettes loaded from [[palettes]] config table. Owned by App.
    palettes: []NamedPalette,
    /// Name of the currently active palette, or zero-length = "custom".
    active_palette_name_buf: [64]u8,
    active_palette_name_len: usize,
    /// Authoritative last-applied color triple — the origin a faded set-colors
    /// transitions from. Updated by every palette apply path (instant
    /// set-colors, each fade tick, set-palette, reload, switchEffect).
    current_palette: [3]defaults.Rgb,
    /// In-flight palette transition, or null when no fade is animating.
    fade: ?color_fade.ColorFade,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ: std.process.Environ,
        config: AppConfig,
        palettes: []NamedPalette,
        config_path: ?[]const u8,
    ) !App {
        const display = c.wl_display_connect(null) orelse return error.DisplayConnectFailed;
        errdefer c.wl_display_disconnect(display);

        // Build effect from config first (before EGL check).
        const effect = Effect.init(&config);

        // Create the timerfd here so it is accessible as a field for set_fps.
        const tfd = try sys.timerfdCreate(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true });
        errdefer sys.close(tfd);

        // Block SIGTERM/SIGINT and capture them via signalfd so the poll loop
        // handles them cleanly (triggers deinit, removes socket file). Without
        // this, either signal kills the process instantly and leaves a stale
        // socket.
        var sig_mask = posix.sigemptyset();
        posix.sigaddset(&sig_mask, posix.SIG.TERM);
        posix.sigaddset(&sig_mask, posix.SIG.INT);
        posix.sigprocmask(posix.SIG.BLOCK, &sig_mask, null);
        const sig_fd_flags: u32 = @bitCast(linux.O{ .NONBLOCK = true, .CLOEXEC = true });
        const sig_fd = try posix.signalfd(-1, &sig_mask, sig_fd_flags);
        errdefer sys.close(sig_fd);

        const app = App{
            .allocator = allocator,
            .io = io,
            .environ = environ,
            .display = display,
            .registry = Registry{},
            .outputs = .empty,
            .surfaces = .empty,
            .detached_gpu = .empty,
            .effect = effect,
            .egl_ctx = null,
            .effect_shader = null,
            .blit_shader = null,
            .gpu_pipeline_failed = false,
            .timer_armed = false,
            .running = true,
            .frame_interval_ns = config.frame_interval_ns,
            .renderer_scale = config.renderer_scale,
            .upscale_filter = config.upscale_filter,
            .tfd = tfd,
            .sig_fd = sig_fd,
            .ipc_server = null,
            .ipc_client = null,
            .config_path = config_path,
            .palettes = palettes,
            .active_palette_name_buf = std.mem.zeroes([64]u8),
            .active_palette_name_len = 0,
            .current_palette = config.palette,
            .fade = null,
        };
        return app;
    }

    /// Second init phase. MUST be called after the App value rests at its
    /// final address (i.e. in main's stack frame): the registry listener
    /// stores pointers into this App as userdata, and init() returns by
    /// value, so registering listeners inside init() would leave libwayland
    /// pointing into a dead stack frame on every post-startup event.
    pub fn setup(self: *App) !void {
        try self.registry.bind(self.display, &self.outputs, self.allocator);

        // 1st roundtrip: bind all globals (outputs recorded by the registry).
        if (c.wl_display_roundtrip(self.display) < 0) return error.RoundtripFailed;

        // 2nd roundtrip: collect all output done events
        if (c.wl_display_roundtrip(self.display) < 0) return error.RoundtripFailed;

        std.debug.print("bound: wl_compositor={} wl_shm={} zwlr_layer_shell_v1={}\n", .{
            self.registry.compositor != null,
            self.registry.shm != null,
            self.registry.layer_shell != null,
        });

        self.egl_ctx = EglContext.init(self.display) catch |err| blk: {
            std.debug.print("EGL init failed: {}, falling back to CPU path\n", .{err});
            break :blk null;
        };

        // GPU-only effect fallback: if EGL is unavailable and the selected
        // effect has no CPU path, override to colormix on the SHM path.
        if (self.egl_ctx == null and self.effect.isGpuOnly()) {
            std.debug.print("effect {s} requires GPU; falling back to colormix on CPU path\n", .{@tagName(self.effect)});
            const colors = self.effect.gpuPalette().?;
            const frame_advance_ms = self.effect.frameAdvanceMs();
            const speed = self.effect.speed();
            self.effect = Effect{ .colormix = ColormixRenderer.init(
                colors[0],
                colors[1],
                colors[2],
                frame_advance_ms,
                speed,
            ) };
        }

        if (self.registry.compositor == null) return error.MissingCompositor;
        if (self.registry.shm == null) return error.MissingShm;
        if (self.registry.layer_shell == null) return error.MissingLayerShell;

        self.ipc_server = IpcServer.init(self.environ) catch |err| switch (err) {
            error.AlreadyRunning => {
                std.debug.print("ipc: another wlchroma instance owns the control socket\n", .{});
                return error.AlreadyRunning;
            },
            else => blk: {
                std.debug.print("ipc: failed to start IPC server: {} -- continuing without IPC\n", .{err});
                break :blk null;
            },
        };
    }

    /// Reconcile the surface list with the current outputs list: reap
    /// surfaces whose output vanished (or that the compositor closed), then
    /// create a surface for every ready output that lacks one. Runs at
    /// startup and in the poll loop after event dispatch — never inside a
    /// libwayland callback (callbacks record facts; the loop acts on them).
    fn syncSurfaces(self: *App) void {
        self.reapSurfaces();

        for (self.outputs.items) |out| {
            if (!out.done or out.removed) continue;
            if (self.surfaceForOutput(out) != null) continue;

            self.surfaces.ensureUnusedCapacity(self.allocator, 1) catch |err| {
                std.debug.print("surface list reserve failed for output {}: {}\n", .{ out.registry_name, err });
                continue;
            };
            self.detached_gpu.ensureTotalCapacity(
                self.allocator,
                self.surfaces.items.len + 1,
            ) catch |err| {
                std.debug.print("surface GPU cleanup reserve failed for output {}: {}\n", .{ out.registry_name, err });
                continue;
            };
            const surface_state = SurfaceState.create(
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
            ) catch |err| {
                std.debug.print("surface create failed for output {}: {} — skipping this output\n", .{ out.registry_name, err });
                continue;
            };
            self.surfaces.appendAssumeCapacity(surface_state);
            std.debug.print("surface created for output {} ({}x{}{s}{s})\n", .{
                out.registry_name,
                out.width,
                out.height,
                if (out.name.len > 0) " " else "",
                out.name,
            });
        }

        self.ensureGpuPipeline();
        self.updateFrameTimer();
    }

    /// Arm the frame timer when surfaces exist, disarm it when none do.
    /// Re-arming uses the *current* frame_interval_ns so a set-fps issued
    /// while idle takes effect on resume.
    fn updateFrameTimer(self: *App) void {
        const want_armed = self.surfaces.items.len > 0;
        if (want_armed == self.timer_armed) return;

        if (want_armed) {
            const ns = self.frame_interval_ns;
            const interval = linux.itimerspec{
                .it_value = .{ .sec = 0, .nsec = ns },
                .it_interval = .{ .sec = 0, .nsec = ns },
            };
            sys.timerfdSettime(self.tfd, &interval) catch |err| {
                std.debug.print("frame timer arm failed: {}\n", .{err});
                return;
            };
            self.timer_armed = true;
            std.debug.print("frame timer armed ({}fps)\n", .{1_000_000_000 / @as(u64, ns)});
        } else {
            const disarm = std.mem.zeroes(linux.itimerspec);
            sys.timerfdSettime(self.tfd, &disarm) catch |err| {
                std.debug.print("frame timer disarm failed: {}\n", .{err});
                return;
            };
            self.timer_armed = false;
            std.debug.print("frame timer disarmed (no outputs)\n", .{});
        }
    }

    /// Destroy surfaces that are dead (compositor closed the layer surface)
    /// or whose output was removed from the registry, then free removed
    /// outputs that no longer have a surface. The two removal channels can
    /// arrive in either order; both funnel here and each object is freed
    /// exactly once.
    fn reapSurfaces(self: *App) void {
        var i: usize = 0;
        while (i < self.surfaces.items.len) {
            const s = self.surfaces.items[i];
            if (!s.dead and !s.output.removed) {
                i += 1;
                continue;
            }
            const reason: []const u8 = if (s.output.removed) "removed" else "closed";
            std.debug.print("surface reaped for output {} (reason: {s})\n", .{ s.output.registry_name, reason });
            // Compositor-initiated closure is honored as output removal
            // (runtime-behavior contract): without this, a closed-but-not-
            // removed output would get a fresh surface next pass, churning
            // create/close forever. If the output genuinely persists, the
            // compositor re-announces it as a new global.
            s.output.removed = true;
            _ = self.surfaces.swapRemove(i);
            self.retireSurfaceGpu(s);
            std.debug.assert(self.detached_gpu.items.len == 0);
            s.deinit();
            self.allocator.destroy(s);
        }

        i = 0;
        while (i < self.outputs.items.len) {
            const out = self.outputs.items[i];
            if (!out.removed or self.surfaceForOutput(out) != null) {
                i += 1;
                continue;
            }
            out.deinit();
            self.allocator.destroy(out);
            _ = self.outputs.swapRemove(i);
        }
    }

    fn retireSurfaceGpu(self: *App, surface: *SurfaceState) void {
        const detached_index = self.detached_gpu.items.len;
        self.detached_gpu.appendAssumeCapacity(surface.detachGpu());
        const detached = &self.detached_gpu.items[detached_index];

        if (self.surfaces.items.len == 0) {
            self.closeGpuEpoch();
            return;
        }

        if (self.egl_ctx) |*ctx| {
            var current = false;
            if (detached.egl_surface) |*egl_surface| current = egl_surface.makeCurrent(ctx);
            if (!current) {
                for (self.surfaces.items) |survivor| {
                    if (survivor.egl_surface) |*egl_surface| {
                        if (egl_surface.makeCurrent(ctx)) {
                            current = true;
                            break;
                        }
                    }
                }
            }

            if (current) {
                if (detached.offscreen) |*offscreen| offscreen.deinit();
                detached.offscreen = null;
                ctx.clearCurrent();
                if (detached.egl_surface) |*egl_surface| egl_surface.deinit();
                detached.egl_surface = null;
                _ = self.detached_gpu.pop();
                return;
            }

            if (detached.offscreen != null) {
                self.gpu_pipeline_failed = true;
                self.closeGpuEpoch();
                for (self.surfaces.items) |survivor| survivor.configureCpuFallbackAfterDetach();
                return;
            }
        }

        std.debug.assert(detached.offscreen == null);
        if (detached.egl_surface) |*egl_surface| egl_surface.deinit();
        detached.egl_surface = null;
        _ = self.detached_gpu.pop();
    }

    const GpuEpochOps = struct {
        app: *App,
        ctx: *EglContext,

        pub fn detachAll(self: *GpuEpochOps) void {
            for (self.app.surfaces.items) |surface| {
                self.app.detached_gpu.appendAssumeCapacity(surface.detachGpu());
            }
        }

        pub fn candidateCount(self: *GpuEpochOps) usize {
            return self.app.detached_gpu.items.len;
        }

        pub fn tryMakeCurrent(self: *GpuEpochOps, index: usize) bool {
            const egl_surface = if (self.app.detached_gpu.items[index].egl_surface) |*value| value else return false;
            return egl_surface.makeCurrent(self.ctx);
        }

        pub fn deleteAppGl(self: *GpuEpochOps) void {
            if (self.app.blit_shader) |*shader| shader.deinit();
            self.app.blit_shader = null;
            if (self.app.effect_shader) |*shader| shader.deinit();
            self.app.effect_shader = null;
        }

        pub fn deleteSurfaceGl(self: *GpuEpochOps, index: usize) void {
            const detached = &self.app.detached_gpu.items[index];
            if (detached.offscreen) |*offscreen| offscreen.deinit();
            detached.offscreen = null;
        }

        pub fn clearCurrent(self: *GpuEpochOps) void {
            self.ctx.clearCurrent();
        }

        pub fn destroySurface(self: *GpuEpochOps, index: usize) void {
            const detached = &self.app.detached_gpu.items[index];
            if (detached.egl_surface) |*egl_surface| egl_surface.deinit();
            detached.egl_surface = null;
        }

        pub fn destroyContext(self: *GpuEpochOps) void {
            self.ctx.destroy();
            self.app.egl_ctx = null;
        }

        pub fn clearHandles(self: *GpuEpochOps) void {
            self.app.blit_shader = null;
            self.app.effect_shader = null;
            for (self.app.detached_gpu.items) |*detached| {
                std.debug.assert(detached.egl_surface == null);
                detached.offscreen = null;
            }
            self.app.detached_gpu.clearRetainingCapacity();
            for (self.app.surfaces.items) |surface| {
                std.debug.assert(surface.egl_ctx == null);
                std.debug.assert(surface.egl_surface == null);
                std.debug.assert(surface.offscreen == null);
            }
        }
    };

    fn closeGpuEpoch(self: *App) void {
        const ctx = if (self.egl_ctx) |*value| value else {
            std.debug.assert(self.detached_gpu.items.len == 0);
            std.debug.assert(self.effect_shader == null);
            std.debug.assert(self.blit_shader == null);
            for (self.surfaces.items) |surface| {
                std.debug.assert(surface.egl_ctx == null);
                std.debug.assert(surface.egl_surface == null);
                std.debug.assert(surface.offscreen == null);
            }
            return;
        };
        var ops = GpuEpochOps{ .app = self, .ctx = ctx };
        gpu_epoch.close(GpuEpochOps, &ops);
        for (self.surfaces.items) |surface| {
            std.debug.assert(surface.egl_ctx == null);
            std.debug.assert(surface.egl_surface == null);
            std.debug.assert(surface.offscreen == null);
        }
    }

    fn surfaceForOutput(self: *App, out: *const OutputInfo) ?*SurfaceState {
        for (self.surfaces.items) |s| {
            if (s.output == out) return s;
        }
        return null;
    }

    /// Initialize the GPU pipeline (effect shader + optional blit shader)
    /// once an EGL surface is available. Lazy so it serves both normal
    /// startup and the first output arriving after a zero-output start.
    /// One-shot on failure: a compile/link error or a pass where EGL
    /// surfaces exist but none can be made current falls back to the CPU
    /// path for the session (matches pre-hotplug semantics, no per-tick
    /// retry or log spam).
    fn ensureGpuPipeline(self: *App) void {
        const ctx = if (self.egl_ctx) |*p| p else return;
        if (self.effect_shader != null or self.gpu_pipeline_failed) return;

        const perf_logs_enabled = builtin.mode == .Debug;
        var attempted = false;

        for (self.surfaces.items) |s| {
            if (s.egl_surface) |*egl_surf| {
                attempted = true;
                if (!egl_surf.makeCurrent(ctx)) {
                    std.debug.print("shader init: makeCurrent failed on a surface, trying next\n", .{});
                    continue;
                }
                const shader_init_start_ns: u64 = if (perf_logs_enabled) sys.monotonicNs() else 0;
                self.effect_shader = EffectShader.init(&self.effect) catch |err| blk: {
                    std.debug.print("shader init failed: {} -- using CPU fallback on this session\n", .{err});
                    break :blk null;
                };
                if (self.effect_shader == null) {
                    self.gpu_pipeline_failed = true;
                    if (self.effect.isGpuOnly()) self.forceCpuFallbackForGpuOnly();
                    return;
                }
                if (perf_logs_enabled) {
                    const shader_init_end_ns: u64 = sys.monotonicNs();
                    const shader_init_ms = @as(f64, @floatFromInt(shader_init_end_ns - shader_init_start_ns)) / std.time.ns_per_ms;
                    std.debug.print("perf: effect shader init for {s} took {d:.2}ms\n", .{ @tagName(self.effect), shader_init_ms });
                }
                // Bind invariant GL state once -- program, VBO, vertex layout,
                // and effect-specific static data (palette / phase).
                if (self.effect_shader) |*sh| sh.bind(&self.effect);

                // Initialize blit shader for offscreen upscale pass.
                if (self.renderer_scale < 1.0) {
                    self.ensureBlitShader();
                    if (self.blit_shader == null) {
                        // Blit shader unavailable: tear down all offscreen FBOs.
                        for (self.surfaces.items) |surf| {
                            if (surf.offscreen) |*ofs| {
                                ofs.deinit();
                                surf.offscreen = null;
                            }
                        }
                    }
                }
                return;
            }
        }

        if (attempted) {
            // EGL surfaces exist but none could be made current.
            std.debug.print("warning: no EGL surface could be made current; using CPU fallback on this session\n", .{});
            self.gpu_pipeline_failed = true;
            if (self.effect.isGpuOnly()) self.forceCpuFallbackForGpuOnly();
        }
        // else: no EGL surface yet — try again on a later sync pass.
    }

    /// Replace the running effect with the one described by cfg and rebuild
    /// the GPU shader pipeline if one is live. Only called when the effect
    /// type actually changed. Overwrites self.effect in place: SurfaceStates
    /// hold *Effect aimed at this field, so the switch propagates to every
    /// surface without touching their pointers.
    fn switchEffect(self: *App, cfg: *const config_mod.AppConfig) void {
        // Tear down the old shader first so peak GPU object count stays flat
        // across repeated switches.
        if (self.effect_shader) |*sh| {
            var context_current = false;
            if (self.egl_ctx) |*ctx| {
                for (self.surfaces.items) |s| {
                    if (s.dead) continue;
                    if (s.egl_surface) |*egl_surf| {
                        if (egl_surf.makeCurrent(ctx)) {
                            context_current = true;
                            break;
                        }
                    }
                }
            }
            if (context_current) {
                sh.deinit();
            }
            // Without a current-able surface (zero outputs) GL deletion is
            // impossible; orphan the objects — they belong to the EGL context
            // and are reclaimed when the context is destroyed.
            self.effect_shader = null;
        }

        self.effect = Effect.init(cfg);

        // Startup-parity fallback: a GPU-only effect with no usable GPU
        // pipeline becomes colormix on the CPU path — same log line and
        // semantics as setup().
        if ((self.egl_ctx == null or self.gpu_pipeline_failed) and self.effect.isGpuOnly()) {
            std.debug.print("effect {s} requires GPU; falling back to colormix on CPU path\n", .{@tagName(self.effect)});
            const colors = self.effect.gpuPalette().?;
            const frame_advance_ms = self.effect.frameAdvanceMs();
            const speed = self.effect.speed();
            self.effect = Effect{ .colormix = ColormixRenderer.init(
                colors[0],
                colors[1],
                colors[2],
                frame_advance_ms,
                speed,
            ) };
        }

        // Per-surface CPU stand-ins were built from the old effect; drop them
        // so cpuEffect() rebuilds lazily from the new one.
        for (self.surfaces.items) |s| {
            s.shm_effect = null;
        }

        // Rebuild the shader for the new effect while EGL surfaces exist; at
        // zero outputs this is a no-op and the next syncSurfaces pass
        // rebuilds lazily. Failure inside latches gpu_pipeline_failed and
        // forces the CPU fallback exactly like a startup failure.
        self.ensureGpuPipeline();
    }

    /// Compile and bind the blit shader if it is not already available.
    /// Requires an initialized effect shader and a current EGL context.
    /// Lazy so set-scale can enable offscreen rendering mid-session even
    /// when the daemon started at scale 1.0 (blit skipped at pipeline init).
    fn ensureBlitShader(self: *App) void {
        if (self.blit_shader != null or self.effect_shader == null) return;
        self.blit_shader = BlitShader.init() catch |err| {
            std.debug.print("BlitShader.init failed: {} -- offscreen rendering disabled\n", .{err});
            return;
        };
        if (self.blit_shader) |*bs| bs.bind();
        // bind() leaves the blit program/VBO as current GL state; restore the
        // effect program so per-frame uniform uploads hit the right program.
        if (self.effect_shader) |*sh| sh.bind(&self.effect);
    }

    pub fn run(self: *App) !void {
        const perf_logs_enabled = builtin.mode == .Debug;
        const perf_log_interval: u64 = 120;
        var render_tick_count: u64 = 0;
        var render_tick_total_ns: u64 = 0;

        // Create surfaces for outputs known at startup.
        self.syncSurfaces();

        // Roundtrip to deliver the configure events (EGL surfaces are created
        // in the configure handler), then sync again so the GPU pipeline is
        // ready before the first timer tick.
        if (c.wl_display_roundtrip(self.display) < 0) return error.RoundtripFailed;
        self.syncSurfaces();

        // --- poll+timerfd main loop ---
        // tfd was created in App.init and stored as self.tfd; syncSurfaces
        // arms/disarms it as surfaces come and go (zero-output start stays
        // disarmed until the first output arrives).
        const tfd = self.tfd;

        const wl_fd: posix.fd_t = c.wl_display_get_fd(self.display);

        // fds[0]=wayland  fds[1]=timerfd  fds[2]=signalfd
        // fds[3]=IPC listener or the one active IPC client
        var fds = [4]posix.pollfd{
            .{ .fd = wl_fd, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = tfd, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = self.sig_fd, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = -1, .events = 0, .revents = 0 },
        };

        while (self.running) {
            if (c.wl_display_flush(self.display) < 0) {
                std.debug.print("wl_display_flush error, exiting\n", .{});
                break;
            }

            const prep = c.wl_display_prepare_read(self.display);
            if (prep != 0) {
                _ = c.wl_display_dispatch_pending(self.display);
                // Reconcile here too: otherwise output events dispatched on
                // this path would wait for the next poll wake, which may be
                // indefinite with the frame timer disarmed.
                self.syncSurfaces();
                self.expireIpcClient();
                if (!self.running) break;
                continue;
            }

            const poll_timeout = self.ipcPollTimeout();
            if (!self.running) {
                c.wl_display_cancel_read(self.display);
                break;
            }
            const ipc_role = self.configureIpcPollSlot(&fds[3]);
            const nfds: usize = if (ipc_role == .none) 3 else 4;

            for (fds[0..nfds]) |*poll_fd| poll_fd.revents = 0;
            _ = posix.poll(fds[0..nfds], poll_timeout) catch |err| {
                c.wl_display_cancel_read(self.display);
                std.debug.print("poll error: {}\n", .{err});
                break;
            };

            const poll_terminal = linux.POLL.HUP | linux.POLL.ERR | linux.POLL.NVAL;
            if (fds[0].revents & poll_terminal != 0) {
                c.wl_display_cancel_read(self.display);
                std.debug.print("Wayland socket HUP/ERR/NVAL, compositor disconnected\n", .{});
                break;
            }

            if (fds[1].revents & poll_terminal != 0) {
                c.wl_display_cancel_read(self.display);
                std.debug.print("timerfd HUP/ERR/NVAL, exiting\n", .{});
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

            // Reconcile surfaces with outputs that appeared in this batch.
            self.syncSurfaces();

            if (fds[1].revents & linux.POLL.IN != 0) {
                var buf: [8]u8 = undefined;
                _ = posix.read(tfd, &buf) catch {};

                const render_tick_start_ns: u64 = if (perf_logs_enabled) sys.monotonicNs() else 0;

                // Advance an in-flight palette fade once per tick (before drawing
                // surfaces, which read the shared App.effect palette). Time-based
                // so it is frame-rate-independent and self-completes if frames are
                // sparse; settles on the exact target when the duration elapses.
                if (self.fade) |f| {
                    const s = color_fade.sample(f, sys.monotonicNs());
                    self.effect.updatePalette(s.colors);
                    if (self.effect_shader) |*sh| sh.bind(&self.effect);
                    self.current_palette = s.colors;
                    if (s.done) self.fade = null;
                }

                const sh_ptr: ?*const EffectShader = if (self.effect_shader) |*sh| sh else null;
                const blit_ptr: ?*const BlitShader = if (self.blit_shader) |*bs| bs else null;
                for (self.surfaces.items) |s| {
                    s.renderTick(sh_ptr, blit_ptr);
                }
                if (perf_logs_enabled) {
                    const render_tick_end_ns: u64 = sys.monotonicNs();
                    render_tick_count += 1;
                    render_tick_total_ns += render_tick_end_ns - render_tick_start_ns;
                    if (render_tick_count % perf_log_interval == 0) {
                        const avg_tick_ms = @as(f64, @floatFromInt(render_tick_total_ns / perf_log_interval)) / std.time.ns_per_ms;
                        std.debug.print("perf: average renderTick over last {} timer ticks: {d:.3}ms across {} surfaces\n", .{ perf_log_interval, avg_tick_ms, self.surfaces.items.len });
                        render_tick_total_ns = 0;
                    }
                }
            }

            if (fds[2].revents & linux.POLL.IN != 0) {
                self.handleSignalEvent();
            }
            if (fds[2].revents & poll_terminal != 0) {
                std.debug.print("signalfd HUP/ERR/NVAL, shutting down\n", .{});
                self.running = false;
            }

            // Signal shutdown wins over accepting or mutating IPC state. Otherwise use
            // the role captured before poll, even if accepting changes ipc_client.
            if (self.running and ipc_role != .none) {
                self.serviceIpcSlot(ipc_role, fds[3].revents);
            }
        }
    }

    const CommandOutcome = enum { keep_running, shutdown_after_flush };
    const IpcPollRole = enum { none, listener, client };

    fn configureIpcPollSlot(self: *App, slot: *posix.pollfd) IpcPollRole {
        slot.revents = 0;
        if (self.ipc_client) |*client| {
            slot.fd = client.fd;
            slot.events = client.pollEvents();
            return .client;
        }
        if (self.ipc_server) |*server| {
            slot.fd = server.fd;
            slot.events = linux.POLL.IN;
            return .listener;
        }
        slot.fd = -1;
        slot.events = 0;
        return .none;
    }

    fn expireIpcClient(self: *App) void {
        if (self.ipc_client == null) return;
        const now_ns = sys.monotonicNsChecked() catch |err| {
            std.debug.print("ipc: monotonic clock failed: {}; closing client\n", .{err});
            self.closeIpcClient();
            return;
        };
        var expired = false;
        if (self.ipc_client) |*client| expired = client.expired(now_ns);
        if (expired) self.closeIpcClient();
    }

    fn ipcPollTimeout(self: *App) i32 {
        if (self.ipc_client == null) return -1;
        const now_ns = sys.monotonicNsChecked() catch |err| {
            std.debug.print("ipc: monotonic clock failed: {}; closing client\n", .{err});
            self.closeIpcClient();
            return -1;
        };
        var expired = false;
        var timeout_ms: i32 = -1;
        if (self.ipc_client) |*client| {
            expired = client.expired(now_ns);
            if (!expired) timeout_ms = client.timeoutMs(now_ns);
        }
        if (expired) {
            self.closeIpcClient();
            return -1;
        }
        return timeout_ms;
    }

    fn acceptIpcClient(self: *App) void {
        const server = if (self.ipc_server) |*value| value else return;
        const client_fd = server.accept() catch |err| switch (err) {
            error.WouldBlock, error.ConnectionAborted => return,
            else => {
                std.debug.print("ipc: accept failed: {}\n", .{err});
                return;
            },
        };
        const now_ns = sys.monotonicNsChecked() catch |err| {
            std.debug.print("ipc: monotonic clock failed after accept: {}\n", .{err});
            sys.close(client_fd);
            return;
        };
        std.debug.assert(self.ipc_client == null);
        self.ipc_client = IpcConnection.init(client_fd, now_ns);
    }

    fn disableIpcServer(self: *App) void {
        if (self.ipc_server) |*server| server.deinit();
        self.ipc_server = null;
    }

    fn serviceIpcSlot(self: *App, role: IpcPollRole, revents: i16) void {
        const terminal = linux.POLL.HUP | linux.POLL.ERR | linux.POLL.NVAL;
        switch (role) {
            .none => {},
            .listener => {
                if (revents & linux.POLL.IN != 0) self.acceptIpcClient();
                if (revents & terminal != 0) {
                    std.debug.print("ipc: listener HUP/ERR/NVAL; disabling IPC\n", .{});
                    self.disableIpcServer();
                }
            },
            .client => {
                const now_ns = sys.monotonicNsChecked() catch |err| {
                    std.debug.print("ipc: monotonic clock failed: {}; closing client\n", .{err});
                    self.closeIpcClient();
                    return;
                };
                self.serviceActiveIpcClient(revents, now_ns);
            },
        }
    }

    fn serviceActiveIpcClient(self: *App, revents: i16, now_ns: u64) void {
        if (self.ipc_client == null) return;
        var expired = false;
        if (self.ipc_client) |*client| expired = client.expired(now_ns);
        if (expired) {
            self.closeIpcClient();
            return;
        }

        var should_close = false;
        if (self.ipc_client) |*client| {
            switch (client.state) {
                .reading => reading: {
                    if (revents & linux.POLL.IN == 0) break :reading;
                    const outcome = client.readReady() catch |err| {
                        std.debug.print("ipc: client read failed: {}\n", .{err});
                        should_close = true;
                        break :reading;
                    };
                    switch (outcome) {
                        .incomplete => {},
                        .complete => |line| {
                            if (!self.queueCommandResponse(client, line)) {
                                should_close = true;
                            }
                        },
                        .line_too_long => {
                            dispatch.appendError(&client.response, "command too long");
                            if (!self.beginIpcResponse(client, false)) {
                                should_close = true;
                            }
                        },
                        .extra_data => {
                            dispatch.appendError(
                                &client.response,
                                "multiple commands are not supported",
                            );
                            if (!self.beginIpcResponse(client, false)) {
                                should_close = true;
                            }
                        },
                        .peer_closed => should_close = true,
                    }
                },
                .writing => writing: {
                    if (revents & linux.POLL.OUT == 0) break :writing;
                    const outcome = client.flushReady() catch |err| {
                        std.debug.print("ipc: client write failed: {}\n", .{err});
                        should_close = true;
                        break :writing;
                    };
                    if (outcome == .complete) should_close = true;
                },
                .closed => should_close = true,
            }

            // HUP may accompany the last readable request bytes, so expected IO
            // is serviced first. A terminal revent then closes this connection.
            const terminal = linux.POLL.HUP | linux.POLL.ERR | linux.POLL.NVAL;
            if (!should_close and revents & terminal != 0) should_close = true;
        }
        if (should_close) self.closeIpcClient();
    }

    fn queueCommandResponse(
        self: *App,
        client: *IpcConnection,
        line: []const u8,
    ) bool {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        const space = std.mem.indexOfScalar(u8, trimmed, ' ');
        const verb = if (space) |index| trimmed[0..index] else trimmed;

        const cmd = dispatch.parseLine(line) catch |err| {
            switch (err) {
                error.UnknownCommand => {
                    dispatch.appendUnknownCommand(&client.response, verb);
                },
                error.UnexpectedArgument => {
                    dispatch.appendUnexpectedArgument(&client.response, verb);
                },
                error.MissingArgument, error.BadArgument => {
                    const fallback = if (err == error.MissingArgument)
                        "missing argument"
                    else
                        "invalid argument";
                    const kind: []const u8 = if (std.mem.eql(u8, verb, "set-palette"))
                        "name"
                    else if (std.mem.eql(u8, verb, "set-colors"))
                        "color"
                    else
                        "numeric";
                    var buf: [96]u8 = undefined;
                    const msg = std.fmt.bufPrint(
                        &buf,
                        "{s} requires a {s} argument",
                        .{ verb, kind },
                    ) catch fallback;
                    dispatch.appendError(&client.response, msg);
                },
            }
            return self.beginIpcResponse(client, false);
        };

        const outcome = self.dispatchCommand(&client.response, cmd);
        return self.beginIpcResponse(
            client,
            outcome == .shutdown_after_flush,
        );
    }

    fn beginIpcResponse(
        _: *App,
        client: *IpcConnection,
        shutdown_after_flush: bool,
    ) bool {
        const response_now_ns = sys.monotonicNsChecked() catch |err| {
            std.debug.print(
                "ipc: monotonic clock failed before response: {}; closing client\n",
                .{err},
            );
            // A successfully dispatched stop must still shut down when the clock
            // failure makes a bounded response phase impossible.
            client.shutdown_after_flush = shutdown_after_flush;
            return false;
        };
        client.beginWriting(response_now_ns, shutdown_after_flush);
        return true;
    }

    fn closeIpcClient(self: *App) void {
        var shutdown_after_close = false;
        if (self.ipc_client) |*client| {
            shutdown_after_close = client.close();
        }
        self.ipc_client = null;
        if (shutdown_after_close) self.running = false;
    }

    fn handleSignalEvent(self: *App) void {
        while (true) {
            const result = signal_fd.readOne(self.sig_fd) catch |err| {
                std.debug.print("signalfd read failed: {}; ignoring\n", .{err});
                return;
            };
            switch (result) {
                .signal => |info| switch (info.signo) {
                    @intFromEnum(posix.SIG.INT),
                    @intFromEnum(posix.SIG.TERM),
                    => {
                        const name = if (info.signo == @intFromEnum(posix.SIG.INT))
                            "SIGINT"
                        else
                            "SIGTERM";
                        std.debug.print("received {s}, shutting down\n", .{name});
                        self.running = false;
                        return;
                    },
                    else => {
                        std.debug.print("unexpected signalfd signal {}; ignoring\n", .{info.signo});
                    },
                },
                .would_block => {
                    std.debug.print("signalfd readiness race; ignoring\n", .{});
                    return;
                },
                .short_read => |n| {
                    std.debug.print("short signalfd record ({} bytes); ignoring\n", .{n});
                    return;
                },
            }
        }
    }

    fn forceCpuFallbackForGpuOnly(self: *App) void {
        if (!self.effect.isGpuOnly()) return;
        self.closeGpuEpoch();
        for (self.surfaces.items) |surface| {
            surface.configureCpuFallbackAfterDetach();
        }
    }

    fn dispatchCommand(
        self: *App,
        out: *ResponseQueue,
        cmd: dispatch.IpcCommand,
    ) CommandOutcome {
        switch (cmd) {
            .query => self.handleQuery(out),
            .stop => {
                self.handleStop(out);
                return .shutdown_after_flush;
            },
            .set_fps => |fps| self.handleSetFps(out, fps),
            .set_scale => |scale| self.handleSetScale(out, scale),
            .set_palette => |args| self.handleSetPalette(out, args.nameSlice()),
            .set_colors => |set_colors| {
                self.handleSetColors(out, set_colors.colors, set_colors.fade_ms);
            },
            .reload => self.handleReload(out),
        }
        return .keep_running;
    }

    // --- IPC command handlers ---

    fn handleQuery(self: *App, out: *ResponseQueue) void {
        dispatch.appendKv(out, "effect", @tagName(self.effect));

        const fps = 1_000_000_000 / @as(u64, self.frame_interval_ns);
        var fps_buf: [16]u8 = undefined;
        const fps_str = std.fmt.bufPrint(&fps_buf, "{}", .{fps}) catch "?";
        dispatch.appendKv(out, "fps", fps_str);

        var scale_buf: [16]u8 = undefined;
        const scale_str = std.fmt.bufPrint(
            &scale_buf,
            "{d:.2}",
            .{self.renderer_scale},
        ) catch "?";
        dispatch.appendKv(out, "scale", scale_str);

        const palette_name: []const u8 = if (self.active_palette_name_len > 0)
            self.active_palette_name_buf[0..self.active_palette_name_len]
        else
            "custom";
        dispatch.appendKv(out, "palette", palette_name);
        dispatch.appendOk(out);
    }

    fn handleStop(_: *App, out: *ResponseQueue) void {
        dispatch.appendOk(out);
    }

    fn handleSetFps(self: *App, out: *ResponseQueue, fps: u32) void {
        if (fps < 1 or fps > 240) {
            dispatch.appendError(out, "fps must be between 1 and 240");
            return;
        }
        const interval_ns: u32 = @intCast(1_000_000_000 / @as(u64, fps));
        if (self.timer_armed) {
            const interval = linux.itimerspec{
                .it_value = .{ .sec = 0, .nsec = interval_ns },
                .it_interval = .{ .sec = 0, .nsec = interval_ns },
            };
            sys.timerfdSettime(self.tfd, &interval) catch |err| {
                var buf: [64]u8 = undefined;
                const msg = std.fmt.bufPrint(
                    &buf,
                    "timerfd_settime failed: {}",
                    .{err},
                ) catch "timerfd_settime failed";
                dispatch.appendError(out, msg);
                return;
            };
        }
        self.frame_interval_ns = interval_ns;
        dispatch.appendOk(out);
    }

    fn handleSetScale(self: *App, out: *ResponseQueue, scale: f32) void {
        if (!std.math.isFinite(scale) or scale < 0.1 or scale > 1.0) {
            dispatch.appendError(out, "scale must be between 0.1 and 1.0");
            return;
        }
        if (scale < 1.0 and scale >= config_mod.RENDERER_SCALE_NEAR_NATIVE_MIN) {
            dispatch.appendError(
                out,
                "scale values from 0.95 up to but not including 1.0 are too close to native; use a lower value or exactly 1.0",
            );
            return;
        }
        self.applyScaleNow(scale);
        dispatch.appendOk(out);
    }

    /// Write scale into App and surface state and apply it immediately —
    /// create/resize/destroy offscreen FBOs now instead of waiting for the
    /// next configure event. Shared by set-scale and reload so both have
    /// identical visual semantics. No-op GL-wise on the CPU path where
    /// renderer scale does not apply. Callers validate the value first.
    fn applyScaleNow(self: *App, scale: f32) void {
        self.renderer_scale = scale;
        for (self.surfaces.items) |s| {
            s.renderer_scale = scale;
        }
        if (self.egl_ctx) |*ctx| {
            if (scale < 1.0) {
                // Shader compilation needs a current EGL context, which is
                // not guaranteed at IPC-handling time.
                for (self.surfaces.items) |s| {
                    if (s.dead) continue;
                    if (s.egl_surface) |*egl_surf| {
                        if (egl_surf.makeCurrent(ctx)) break;
                    }
                }
                self.ensureBlitShader();
            }
            const blit_available = self.blit_shader != null;
            for (self.surfaces.items) |s| {
                s.applyRendererScale(ctx, blit_available);
            }
        }
    }

    fn handleSetPalette(
        self: *App,
        out: *ResponseQueue,
        name: []const u8,
    ) void {
        var found: ?[3]defaults.Rgb = null;
        for (self.palettes) |*palette| {
            if (std.mem.eql(u8, palette.nameSlice(), name)) {
                found = palette.colors;
                break;
            }
        }
        const colors = found orelse {
            var buf: [96]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &buf,
                "unknown palette \"{s}\"",
                .{name},
            ) catch "unknown palette";
            dispatch.appendError(out, msg);
            return;
        };
        self.fade = null;
        self.effect.updatePalette(colors);
        if (self.effect_shader) |*shader| shader.bind(&self.effect);
        self.current_palette = colors;
        const copy_len = @min(name.len, self.active_palette_name_buf.len);
        @memcpy(self.active_palette_name_buf[0..copy_len], name[0..copy_len]);
        self.active_palette_name_len = copy_len;
        dispatch.appendOk(out);
    }

    fn handleSetColors(
        self: *App,
        out: *ResponseQueue,
        colors: [3]defaults.Rgb,
        fade_ms: u32,
    ) void {
        self.active_palette_name_len = 0;

        if (fade_ms == 0) {
            self.fade = null;
            self.effect.updatePalette(colors);
            if (self.effect_shader) |*shader| shader.bind(&self.effect);
            self.current_palette = colors;
            dispatch.appendOk(out);
            return;
        }

        const now = sys.monotonicNs();
        const start = if (self.fade) |fade|
            color_fade.sample(fade, now).colors
        else
            self.current_palette;
        self.fade = .{
            .start = start,
            .target = colors,
            .start_ns = now,
            .dur_ns = @as(u64, fade_ms) * std.time.ns_per_ms,
        };
        dispatch.appendOk(out);
    }

    fn handleReload(self: *App, out: *ResponseQueue) void {
        const load_result = config_mod.loadConfigFullRequireFile(
            self.allocator,
            self.io,
            self.environ,
            self.config_path,
        ) catch |err| {
            if (err == error.ConfigFileNotFound) {
                dispatch.appendError(out, "config file not found");
                return;
            }
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &buf,
                "config parse failed: {}",
                .{err},
            ) catch "config parse failed";
            dispatch.appendError(out, msg);
            return;
        };
        const cfg = &load_result.config;

        const new_interval_ns = cfg.frame_interval_ns;
        if (self.timer_armed) {
            const new_interval = linux.itimerspec{
                .it_value = .{ .sec = 0, .nsec = new_interval_ns },
                .it_interval = .{ .sec = 0, .nsec = new_interval_ns },
            };
            sys.timerfdSettime(self.tfd, &new_interval) catch {};
        }
        self.frame_interval_ns = new_interval_ns;

        if (cfg.upscale_filter != self.upscale_filter) {
            self.upscale_filter = cfg.upscale_filter;
            for (self.surfaces.items) |surface| {
                surface.upscale_filter = cfg.upscale_filter;
                if (self.egl_ctx) |*ctx| surface.dropOffscreenForFilterChange(ctx);
            }
        }

        self.applyScaleNow(cfg.renderer_scale);
        self.fade = null;
        if (@as(config_mod.EffectType, self.effect) != cfg.effect_type) {
            self.switchEffect(cfg);
        } else {
            self.effect.setSpeed(cfg.speed);
            self.effect.updatePalette(cfg.palette);
            if (self.effect_shader) |*shader| shader.bind(&self.effect);
        }
        self.current_palette = cfg.palette;

        self.allocator.free(self.palettes);
        self.palettes = load_result.palettes;
        self.active_palette_name_len = 0;
        dispatch.appendOk(out);
    }

    pub fn deinit(self: *App) void {
        self.closeIpcClient();
        if (self.ipc_server) |*srv| srv.deinit();
        self.ipc_server = null;
        self.allocator.free(self.palettes);
        sys.close(self.tfd);
        sys.close(self.sig_fd);

        self.closeGpuEpoch();

        for (self.surfaces.items) |s| {
            s.deinit();
            self.allocator.destroy(s);
        }
        self.surfaces.deinit(self.allocator);
        self.detached_gpu.deinit(self.allocator);

        for (self.outputs.items) |out| {
            out.deinit();
            self.allocator.destroy(out);
        }
        self.outputs.deinit(self.allocator);

        self.registry.deinit();
        c.wl_display_disconnect(self.display);
    }
};
