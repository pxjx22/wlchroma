const std = @import("std");
const c = @import("../wl.zig").c;
const LayerSurface = @import("layer_shell.zig").LayerSurface;
const ShmPool = @import("shm_pool.zig").ShmPool;
const Effect = @import("../render/effect.zig").Effect;
const EffectShader = @import("../render/effect_shader.zig").EffectShader;
const GpuUploadState = @import("../render/gpu_upload_state.zig").GpuUploadState;
const ColormixRenderer = @import("../render/colormix.zig").ColormixRenderer;
const framebuffer = @import("../render/framebuffer.zig");
const defaults = @import("../config/defaults.zig");
const OutputInfo = @import("output.zig").OutputInfo;
const EglSurface = @import("../render/egl_surface.zig").EglSurface;
const EglContext = @import("../render/egl_context.zig").EglContext;
const gpu_epoch = @import("../render/gpu_epoch.zig");
const shader_mod = @import("../render/shader.zig");
const BlitShader = shader_mod.BlitShader;
const Offscreen = @import("../render/offscreen.zig").Offscreen;
const UpscaleFilter = @import("../config/config.zig").UpscaleFilter;
const dimensions = @import("dimensions.zig");
const Extent = dimensions.Extent;
const ShmLayout = dimensions.ShmLayout;

const EffectUploadOps = struct {
    shader: *EffectShader,
    effect: *const Effect,

    pub fn useProgram(self: *EffectUploadOps) void {
        self.shader.useProgram();
    }

    pub fn bindGeometry(self: *EffectUploadOps) void {
        self.shader.bindGeometry();
    }

    pub fn uploadPalette(self: *EffectUploadOps) void {
        self.shader.uploadPalette(self.effect);
    }

    pub fn uploadStatic(self: *EffectUploadOps) void {
        self.shader.uploadStatic(self.effect);
    }
};

/// Context passed as userdata to each wl_buffer release listener.
pub const BufReleaseCtx = struct {
    pool_busy: *bool,
    surface: *SurfaceState,
};

pub const SurfaceState = struct {
    allocator: std.mem.Allocator,
    /// Owning output. The reaper in App.syncSurfaces uses this link to
    /// associate surfaces with removed outputs.
    output: *OutputInfo,
    layer_surface: LayerSurface,
    shm_pool: ?ShmPool,
    shm: *c.wl_shm,
    effect: *Effect,
    shm_effect: ?Effect,
    cell_grid: []defaults.Rgb,
    grid_w: usize,
    grid_h: usize,
    extent: ?Extent,
    configured: bool,
    display: *c.wl_display,
    frame_callback: ?*c.wl_callback,
    running: *bool,
    egl_surface: ?EglSurface,
    egl_ctx: ?*const EglContext,
    /// Per-buffer release context, stored here so the release handler
    /// can reach both the ShmPool busy flag and the SurfaceState.
    buf_ctx: [2]BufReleaseCtx,
    /// Offscreen FBO for reduced-resolution rendering. null when
    /// renderer_scale == 1.0 or when FBO creation failed.
    offscreen: ?Offscreen,
    renderer_scale: f32,
    upscale_filter: UpscaleFilter,
    /// Set true when the layer surface is closed by the compositor.
    dead: bool,
    /// Set once non-GPU Wayland and SHM ownership has been released.
    torn_down: bool,

    pub const DetachedGpu = struct {
        egl_surface: ?EglSurface,
        offscreen: ?Offscreen,
    };

    const layer_surface_listener = c.zwlr_layer_surface_v1_listener{
        .configure = layerSurfaceConfigure,
        .closed = layerSurfaceClosed,
    };

    const frame_callback_listener = c.wl_callback_listener{
        .done = frameCallbackDone,
    };

    const buf_release_listener = c.wl_buffer_listener{
        .release = bufferRelease,
    };

    /// Create a heap-allocated SurfaceState, attach its listener, and do the
    /// initial commit. The returned pointer is the surface's permanent
    /// address (it is registered as listener userdata), valid until the
    /// caller destroys it after teardown.
    pub fn create(
        allocator: std.mem.Allocator,
        compositor: *c.wl_compositor,
        shm: *c.wl_shm,
        layer_shell: *c.zwlr_layer_shell_v1,
        output: *OutputInfo,
        display: *c.wl_display,
        effect: *Effect,
        running: *bool,
        egl_ctx: ?*const EglContext,
        renderer_scale: f32,
        upscale_filter: UpscaleFilter,
    ) !*SurfaceState {
        var layer_surf = try LayerSurface.create(compositor, layer_shell, output.wl_output, "wallpaper");
        errdefer layer_surf.destroy();

        const self = try allocator.create(SurfaceState);
        const initial_extent: ?Extent = if (output.width > 0 and output.height > 0)
            Extent.init(@intCast(output.width), @intCast(output.height)) catch null
        else
            null;
        self.* = SurfaceState{
            .allocator = allocator,
            .output = output,
            .layer_surface = layer_surf,
            .shm_pool = null,
            .shm = shm,
            .effect = effect,
            .shm_effect = null,
            .cell_grid = &.{},
            .grid_w = 0,
            .grid_h = 0,
            .extent = initial_extent,
            .configured = false,
            .display = display,
            .frame_callback = null,
            .running = running,
            .egl_surface = null,
            .egl_ctx = egl_ctx,
            .buf_ctx = undefined,
            .offscreen = null,
            .renderer_scale = renderer_scale,
            .upscale_filter = upscale_filter,
            .dead = false,
            .torn_down = false,
        };

        _ = c.zwlr_layer_surface_v1_add_listener(
            self.layer_surface.layer_surface,
            &layer_surface_listener,
            self,
        );
        c.wl_surface_commit(self.layer_surface.wl_surface);
        return self;
    }

    /// Called by the timerfd tick in the main loop (~15fps).
    pub fn renderTick(
        self: *SurfaceState,
        shader: ?*EffectShader,
        upload_state: *GpuUploadState,
        blit_shader: ?*const BlitShader,
    ) void {
        if (self.dead) return;
        if (!self.configured) return;
        const extent = self.extent orelse return;

        if (self.frame_callback != null) return;

        const wl_surface = self.layer_surface.wl_surface orelse return;

        // EGL path: render via GPU when an EGL surface is available.
        if (self.egl_surface) |*egl_surf| {
            const ctx = self.egl_ctx.?;
            if (!egl_surf.makeCurrent(ctx)) return;

            if (shader) |sh| {
                var upload_ops = EffectUploadOps{
                    .shader = sh,
                    .effect = self.effect,
                };
                upload_state.flushIfCurrent(EffectUploadOps, &upload_ops, true);

                if (self.offscreen) |*ofs| {
                    if (blit_shader) |bs| {
                        // Offscreen pass: render at reduced resolution
                        ofs.bind();
                        c.glViewport(0, 0, ofs.extent.c_width, ofs.extent.c_height);
                        sh.setUniforms(self.effect, @floatFromInt(ofs.extent.width), @floatFromInt(ofs.extent.height));
                        sh.draw();

                        // Upscale pass: blit FBO texture to default framebuffer
                        ofs.unbind();
                        c.glViewport(0, 0, extent.c_width, extent.c_height);
                        bs.draw(ofs.tex, sh.glProgram(), sh.glVbo(), sh.glAPosLoc());
                    } else {
                        // Blit shader unavailable -- fall back to direct rendering
                        sh.setUniforms(self.effect, @floatFromInt(extent.width), @floatFromInt(extent.height));
                        sh.draw();
                    }
                } else {
                    // Direct render at full resolution (scale == 1.0)
                    sh.setUniforms(self.effect, @floatFromInt(extent.width), @floatFromInt(extent.height));
                    sh.draw();
                }
            } else {
                c.glClearColor(0.0, 0.0, 0.0, 1.0);
                c.glClear(c.GL_COLOR_BUFFER_BIT);
            }

            const cb = c.wl_surface_frame(wl_surface) orelse {
                std.debug.print("wl_surface_frame returned null (OOM), skipping callback arm\n", .{});
                return;
            };
            self.frame_callback = cb;
            _ = c.wl_callback_add_listener(cb, &SurfaceState.frame_callback_listener, self);

            if (!egl_surf.swapBuffers()) {
                std.debug.print("eglSwapBuffers failed\n", .{});
                if (self.frame_callback) |stale_cb| {
                    c.wl_callback_destroy(stale_cb);
                    self.frame_callback = null;
                }
            }
            return;
        }

        // SHM/CPU fallback path
        var pool = &(self.shm_pool orelse return);
        const idx = pool.acquireBuffer() orelse return;

        if (getMonotonicMs()) |now_ms| {
            self.cpuEffect().maybeAdvance(now_ms);
        }
        const cpu_effect = self.cpuEffect();
        cpu_effect.renderGrid(self.grid_w, self.grid_h, self.cell_grid);
        framebuffer.expandCells(self.cell_grid, self.grid_w, self.grid_h, pool.pixelSlice(idx), extent);

        c.wl_surface_attach(wl_surface, pool.wlBuffer(idx), 0, 0);
        c.wl_surface_damage_buffer(wl_surface, 0, 0, std.math.maxInt(i32), std.math.maxInt(i32));

        const cb = c.wl_surface_frame(wl_surface) orelse {
            std.debug.print("wl_surface_frame returned null (OOM), skipping callback arm\n", .{});
            c.wl_surface_commit(wl_surface);
            return;
        };
        self.frame_callback = cb;
        _ = c.wl_callback_add_listener(cb, &SurfaceState.frame_callback_listener, self);

        c.wl_surface_commit(wl_surface);
    }

    fn getMonotonicMs() ?u32 {
        var ts: std.os.linux.timespec = undefined;
        const rc = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        if (rc != 0) {
            std.debug.print("clock_gettime failed: rc={}\n", .{rc});
            return null;
        }
        const ms: u64 = @intCast(ts.sec * 1000 + @divFloor(ts.nsec, 1_000_000));
        return @truncate(ms);
    }

    pub fn detachGpu(self: *SurfaceState) DetachedGpu {
        const detached = DetachedGpu{
            .egl_surface = self.egl_surface,
            .offscreen = self.offscreen,
        };
        self.egl_ctx = null;
        self.egl_surface = null;
        self.offscreen = null;
        return detached;
    }

    pub fn configureCpuFallbackAfterDetach(self: *SurfaceState) void {
        std.debug.assert(self.egl_ctx == null);
        std.debug.assert(self.egl_surface == null);
        std.debug.assert(self.offscreen == null);
        if (self.dead) return;
        const extent = self.extent orelse {
            self.configured = false;
            return;
        };
        self.configureShmFallback(extent) catch |err| {
            std.debug.print("failed to configure CPU fallback: {}\n", .{err});
            self.configured = false;
        };
    }

    fn teardownWayland(self: *SurfaceState) void {
        if (self.torn_down) return;
        self.torn_down = true;
        std.debug.assert(self.egl_ctx == null);
        std.debug.assert(self.egl_surface == null);
        std.debug.assert(self.offscreen == null);

        if (self.frame_callback) |cb| {
            c.wl_callback_destroy(cb);
            self.frame_callback = null;
        }
        if (self.configured) {
            if (self.layer_surface.wl_surface) |ws| {
                c.wl_surface_attach(ws, null, 0, 0);
                c.wl_surface_commit(ws);
            }
        }
        self.layer_surface.destroy();
        if (self.shm_pool) |*pool| {
            pool.deinit();
            self.shm_pool = null;
        }
        if (self.cell_grid.len > 0) {
            self.allocator.free(self.cell_grid);
            self.cell_grid = &.{};
        }
        self.configured = false;
        self.shm_effect = null;
    }

    pub fn deinit(self: *SurfaceState) void {
        self.teardownWayland();
    }

    /// Apply the current renderer_scale immediately: create or resize the
    /// offscreen FBO (scale < 1.0, blit shader available) or destroy it
    /// (scale == 1.0). Called by the set-scale IPC handler so the change is
    /// visible without waiting for the next configure event. Requires an
    /// EGL surface; makes it current for the GL object work.
    pub fn applyRendererScale(self: *SurfaceState, ctx: *const EglContext, blit_available: bool) void {
        if (self.dead or !self.configured) return;
        const extent = self.extent orelse return;
        const egl_surf = if (self.egl_surface) |*e| e else return;
        if (!egl_surf.makeCurrent(ctx)) {
            std.debug.print("set-scale: makeCurrent failed on output {}, deferring to next configure\n", .{self.output.registry_name});
            return;
        }

        if (self.renderer_scale < 1.0 and blit_available) {
            const render_extent = extent.scaled(self.renderer_scale) catch |err| {
                std.debug.print("set-scale: invalid scaled extent on output {}: {}, rendering at full resolution\n", .{ self.output.registry_name, err });
                return;
            };
            if (self.offscreen) |*ofs| {
                if (ofs.filter != self.upscale_filter) {
                    var replacement_ops = OffscreenReplacementOps{
                        .surface = self,
                        .ctx = ctx,
                        .extent = render_extent,
                        .filter = self.upscale_filter,
                    };
                    if (!gpu_epoch.replaceCurrentOwned(OffscreenReplacementOps, &replacement_ops)) {
                        std.debug.print("set-scale: offscreen filter replacement deferred on output {}\n", .{self.output.registry_name});
                    }
                } else if (!ofs.resize(render_extent)) {
                    std.debug.print("set-scale: FBO incomplete after resize, disabling offscreen on output {}\n", .{self.output.registry_name});
                    ofs.deinit();
                    self.offscreen = null;
                }
            } else {
                self.offscreen = Offscreen.init(render_extent, self.upscale_filter) catch |err| blk: {
                    std.debug.print("set-scale: Offscreen.init failed on output {}: {}, rendering at full resolution\n", .{ self.output.registry_name, err });
                    break :blk null;
                };
            }
        } else if (self.offscreen) |*ofs| {
            ofs.deinit();
            self.offscreen = null;
        }
    }

    const OffscreenReplacementOps = struct {
        surface: *SurfaceState,
        ctx: *const EglContext,
        extent: Extent,
        filter: UpscaleFilter,

        pub fn acquireCurrent(self: *OffscreenReplacementOps) bool {
            const egl_surface = if (self.surface.egl_surface) |*value| value else return false;
            return egl_surface.makeCurrent(self.ctx);
        }

        pub fn createReplacement(self: *OffscreenReplacementOps) !Offscreen {
            return Offscreen.init(self.extent, self.filter);
        }

        pub fn commitReplacement(self: *OffscreenReplacementOps, replacement: Offscreen) void {
            var old = self.surface.offscreen.?;
            self.surface.offscreen = replacement;
            old.deinit();
        }
    };

    fn cpuEffect(self: *SurfaceState) *Effect {
        if (self.effect.isGpuOnly()) {
            self.ensureShmFallbackEffect();
            return &(self.shm_effect.?);
        }
        self.shm_effect = null;
        return self.effect;
    }

    fn ensureShmFallbackEffect(self: *SurfaceState) void {
        const colors = self.effect.gpuPalette() orelse return;
        if (self.shm_effect == null) {
            self.shm_effect = Effect{ .colormix = ColormixRenderer.init(
                colors[0],
                colors[1],
                colors[2],
                self.effect.frameAdvanceMs(),
                self.effect.speed(),
            ) };
        } else {
            self.shm_effect.?.updatePalette(colors);
        }
    }

    fn configureShmFallback(self: *SurfaceState, extent: Extent) !void {
        const layout = try ShmLayout.init(extent);
        const wl_surface = self.layer_surface.wl_surface orelse return error.MissingWlSurface;

        const new_grid = try self.allocator.alloc(defaults.Rgb, layout.grid_len);
        errdefer self.allocator.free(new_grid);
        var new_pool = try ShmPool.init(self.shm, layout);
        errdefer new_pool.deinit();

        self.cpuEffect().renderGrid(layout.grid_w, layout.grid_h, new_grid);
        const first = new_pool.acquireBuffer() orelse return error.NoFreeShmBuffer;
        framebuffer.expandCells(
            new_grid,
            layout.grid_w,
            layout.grid_h,
            new_pool.pixelSlice(first),
            extent,
        );

        if (self.frame_callback) |old_callback| {
            c.wl_callback_destroy(old_callback);
            self.frame_callback = null;
        }
        if (self.shm_pool) |*old_pool| old_pool.deinit();
        if (self.cell_grid.len > 0) self.allocator.free(self.cell_grid);

        self.shm_pool = new_pool;
        self.cell_grid = new_grid;
        self.grid_w = layout.grid_w;
        self.grid_h = layout.grid_h;
        self.buf_ctx[0] = .{ .pool_busy = &self.shm_pool.?.busy[0], .surface = self };
        self.buf_ctx[1] = .{ .pool_busy = &self.shm_pool.?.busy[1], .surface = self };
        self.shm_pool.?.attachListeners(
            &SurfaceState.buf_release_listener,
            @ptrCast(&self.buf_ctx[0]),
            @ptrCast(&self.buf_ctx[1]),
        );

        c.wl_surface_attach(wl_surface, self.shm_pool.?.wlBuffer(first), 0, 0);
        c.wl_surface_damage_buffer(wl_surface, 0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
        if (c.wl_surface_frame(wl_surface)) |callback| {
            self.frame_callback = callback;
            _ = c.wl_callback_add_listener(callback, &SurfaceState.frame_callback_listener, self);
        } else {
            std.debug.print("configure: wl_surface_frame returned null (OOM)\n", .{});
        }
        c.wl_surface_commit(wl_surface);
        self.configured = true;
        std.debug.print("configure: {}x{} grid={}x{}\n", .{ extent.width, extent.height, layout.grid_w, layout.grid_h });
    }
};

fn layerSurfaceConfigure(
    data: ?*anyopaque,
    layer_surface: ?*c.zwlr_layer_surface_v1,
    serial: u32,
    width: u32,
    height: u32,
) callconv(.c) void {
    const self: *SurfaceState = @ptrCast(@alignCast(data));

    c.zwlr_layer_surface_v1_ack_configure(layer_surface, serial);
    const next_extent = dimensions.resolve(self.extent, width, height) catch |err| {
        std.debug.print("configure: rejecting dimensions {}x{}: {}\n", .{ width, height, err });
        return;
    };
    const extent = next_extent orelse {
        self.configured = false;
        std.debug.print("configure: zero dimensions, skipping\n", .{});
        return;
    };
    self.extent = extent;

    if (self.egl_ctx) |ctx| {
        const wl_surface_egl = self.layer_surface.wl_surface orelse {
            self.configured = false;
            return;
        };
        var gl_context_current = false;
        if (self.egl_surface) |*existing| {
            existing.resize(extent);
            if (existing.makeCurrent(ctx)) {
                gl_context_current = true;
                c.glViewport(0, 0, extent.c_width, extent.c_height);
            } else {
                std.debug.print("configure: makeCurrent failed during resize, viewport not updated\n", .{});
            }
        } else {
            self.egl_surface = EglSurface.create(ctx, wl_surface_egl, extent) catch |err| blk: {
                std.debug.print("EglSurface.create failed: {}\n", .{err});
                break :blk null;
            };
            if (self.egl_surface) |*egl_surf| {
                if (egl_surf.makeCurrent(ctx)) {
                    gl_context_current = true;
                    if (c.eglSwapInterval(ctx.display, 0) == c.EGL_FALSE) {
                        std.debug.print("eglSwapInterval(0) failed -- vsync may remain enabled\n", .{});
                    }
                    c.glViewport(0, 0, extent.c_width, extent.c_height);
                }
            }
        }

        if (self.egl_surface != null and self.renderer_scale < 1.0 and gl_context_current) {
            const render_extent: ?Extent = extent.scaled(self.renderer_scale) catch |err| blk: {
                std.debug.print("configure: invalid scaled extent: {}, rendering at full resolution\n", .{err});
                break :blk null;
            };
            if (render_extent) |scaled_extent| {
                if (self.offscreen) |*ofs| {
                    if (!ofs.resize(scaled_extent)) {
                        std.debug.print("configure: FBO incomplete after resize, disabling offscreen\n", .{});
                        ofs.deinit();
                        self.offscreen = null;
                    }
                } else {
                    self.offscreen = Offscreen.init(scaled_extent, self.upscale_filter) catch |err| blk: {
                        std.debug.print("Offscreen.init failed: {}, rendering at full resolution\n", .{err});
                        break :blk null;
                    };
                }
            }
        } else if (gl_context_current) {
            if (self.offscreen) |*ofs| {
                ofs.deinit();
                self.offscreen = null;
            }
        }

        if (self.egl_surface) |*egl_surf| {
            if (egl_surf.makeCurrent(ctx)) {
                c.glClearColor(0.0, 0.0, 0.0, 1.0);
                c.glClear(c.GL_COLOR_BUFFER_BIT);

                if (self.frame_callback) |old_cb| c.wl_callback_destroy(old_cb);
                if (c.wl_surface_frame(wl_surface_egl)) |cb| {
                    self.frame_callback = cb;
                    _ = c.wl_callback_add_listener(cb, &SurfaceState.frame_callback_listener, self);
                } else {
                    std.debug.print("configure: wl_surface_frame returned null (OOM)\n", .{});
                    self.frame_callback = null;
                }

                if (!egl_surf.swapBuffers()) {
                    std.debug.print("configure: initial eglSwapBuffers failed\n", .{});
                    if (self.frame_callback) |stale_cb| {
                        c.wl_callback_destroy(stale_cb);
                        self.frame_callback = null;
                    }
                }
            }
            self.configured = true;
            std.debug.print("configure (EGL): {}x{}\n", .{ extent.width, extent.height });
            return;
        }

        std.debug.print("configure: EGL surface unavailable, falling back to SHM\n", .{});
        self.egl_ctx = null;
    }

    self.configureShmFallback(extent) catch |err| {
        std.debug.print("configure: configureShmFallback failed: {}\n", .{err});
        self.configured = false;
    };
}

/// Frame callback handler. Clears the pending flag and advances the
/// effect frame counter on the EGL path using the compositor's timestamp.
fn frameCallbackDone(
    data: ?*anyopaque,
    callback: ?*c.wl_callback,
    time_ms: u32,
) callconv(.c) void {
    const self: *SurfaceState = @ptrCast(@alignCast(data));

    c.wl_callback_destroy(callback);
    self.frame_callback = null;

    // On the EGL path, use the compositor's presentation timestamp to
    // drive frame advancement (presentation-aligned animation).
    if (self.egl_surface != null) {
        self.effect.maybeAdvance(time_ms);
    }
}

/// Layer surface closed by the compositor (e.g. output unplugged).
fn layerSurfaceClosed(
    data: ?*anyopaque,
    layer_surface: ?*c.zwlr_layer_surface_v1,
) callconv(.c) void {
    _ = layer_surface;
    const self: *SurfaceState = @ptrCast(@alignCast(data));
    std.debug.print("layer surface closed, scheduling surface teardown\n", .{});
    self.dead = true;
}

/// wl_buffer.release handler.
fn bufferRelease(data: ?*anyopaque, buffer: ?*c.wl_buffer) callconv(.c) void {
    _ = buffer;
    const ctx: *BufReleaseCtx = @ptrCast(@alignCast(data));
    ctx.pool_busy.* = false;
}
