const std = @import("std");
const c = @import("../wl.zig").c;
const LockSurface = @import("session_lock.zig").LockSurface;
const password_widget_mod = @import("../render/password_widget.zig");
const PasswordWidget = password_widget_mod.PasswordWidget;
const AuthState = password_widget_mod.AuthState;
const InputState = @import("../lock_app.zig").InputState;
const ShmPool = @import("shm_pool.zig").ShmPool;
const Effect = @import("../render/effect.zig").Effect;
const EffectShader = @import("../render/effect_shader.zig").EffectShader;
const framebuffer = @import("../render/framebuffer.zig");
const defaults = @import("../config/defaults.zig");
const OutputInfo = @import("output.zig").OutputInfo;
const EglSurface = @import("../render/egl_surface.zig").EglSurface;
const EglContext = @import("../render/egl_context.zig").EglContext;
const shader_mod = @import("../render/shader.zig");
const BlitShader = shader_mod.BlitShader;
const Offscreen = @import("../render/offscreen.zig").Offscreen;
const UpscaleFilter = @import("../config/config.zig").UpscaleFilter;

/// Context passed as userdata to each wl_buffer release listener.
pub const BufReleaseCtx = struct {
    pool_busy: ?*bool,
    surface: ?*LockSurfaceState,
};

pub const LockSurfaceState = struct {
    allocator: std.mem.Allocator,
    lock_surface: LockSurface,
    shm_pool: ?ShmPool,
    shm: *c.wl_shm,
    effect: *Effect,
    cell_grid: []defaults.Rgb,
    grid_w: usize,
    grid_h: usize,
    pixel_w: u32,
    pixel_h: u32,
    configured: bool,
    display: *c.wl_display,
    frame_callback: ?*c.wl_callback,
    running: *bool,
    egl_surface: ?EglSurface,
    egl_ctx: ?*const EglContext,
    needs_static_uniforms: bool,
    buf_ctx: [2]BufReleaseCtx,
    offscreen: ?Offscreen,
    renderer_scale: f32,
    upscale_filter: UpscaleFilter,
    /// Set true when the compositor tears down this surface.
    dead: bool,
    /// Password overlay widget; null on SHM path (no GL context).
    password_widget: ?PasswordWidget,
    /// True until the first renderTick attempt has been diagnosed (one-shot stderr print).
    first_render_diag: bool,

    const lock_surface_listener = c.ext_session_lock_surface_v1_listener{
        .configure = lockSurfaceConfigure,
    };

    const frame_callback_listener = c.wl_callback_listener{
        .done = frameCallbackDone,
    };

    const buf_release_listener = c.wl_buffer_listener{
        .release = bufferRelease,
    };

    /// Create the LockSurfaceState value. Does NOT attach the listener yet —
    /// call `attach` after storing at its final address.
    pub fn create(
        allocator: std.mem.Allocator,
        compositor: *c.wl_compositor,
        shm: *c.wl_shm,
        lock: *c.ext_session_lock_v1,
        out: *const OutputInfo,
        display: *c.wl_display,
        effect: *Effect,
        running: *bool,
        egl_ctx: ?*const EglContext,
        renderer_scale: f32,
        upscale_filter: UpscaleFilter,
    ) !LockSurfaceState {
        const lock_surf = try LockSurface.create(compositor, lock, out.wl_output);

        return LockSurfaceState{
            .allocator = allocator,
            .lock_surface = lock_surf,
            .shm_pool = null,
            .shm = shm,
            .effect = effect,
            .cell_grid = &.{},
            .grid_w = 0,
            .grid_h = 0,
            .pixel_w = @intCast(@max(0, out.width)),
            .pixel_h = @intCast(@max(0, out.height)),
            .configured = false,
            .display = display,
            .frame_callback = null,
            .running = running,
            .egl_surface = null,
            .egl_ctx = egl_ctx,
            .needs_static_uniforms = true,
            .buf_ctx = std.mem.zeroes([2]BufReleaseCtx),
            .offscreen = null,
            .renderer_scale = renderer_scale,
            .upscale_filter = upscale_filter,
            .dead = false,
            .password_widget = null,
            .first_render_diag = true,
        };
    }

    /// Attach listener and do initial commit. Must be called on the
    /// LockSurfaceState at its final memory location (i.e. inside the ArrayList).
    pub fn attach(self: *LockSurfaceState) void {
        _ = c.ext_session_lock_surface_v1_add_listener(
            self.lock_surface.lock_surface,
            &lock_surface_listener,
            self,
        );
        c.wl_surface_commit(self.lock_surface.wl_surface);
    }

    /// Called by the timerfd tick in the main loop (~15fps).
    /// `input`: current password input state for overlay rendering.
    pub fn renderTick(self: *LockSurfaceState, shader: ?*const EffectShader, blit_shader: ?*const BlitShader, input: *const InputState) void {
        if (self.first_render_diag) {
            self.first_render_diag = false;
            std.debug.print("renderTick first call: dead={} configured={} has_frame_cb={}\n", .{
                self.dead, self.configured, self.frame_callback != null,
            });
        }
        if (self.dead) return;
        if (!self.configured) return;
        if (self.frame_callback != null) return;

        const wl_surface = self.lock_surface.wl_surface orelse return;

        // EGL path
        if (self.egl_surface) |*egl_surf| {
            const ctx = self.egl_ctx.?;
            if (!egl_surf.makeCurrent(ctx)) return;

            if (shader) |sh| {
                if (self.needs_static_uniforms) {
                    sh.setStaticUniforms(self.effect);
                    self.needs_static_uniforms = false;
                }

                if (self.offscreen) |*ofs| {
                    if (blit_shader) |bs| {
                        ofs.bind();
                        c.glViewport(0, 0, @intCast(ofs.width), @intCast(ofs.height));
                        sh.setUniforms(self.effect, @floatFromInt(ofs.width), @floatFromInt(ofs.height));
                        sh.draw();

                        ofs.unbind();
                        c.glViewport(0, 0, @intCast(self.pixel_w), @intCast(self.pixel_h));
                        bs.draw(ofs.tex, sh.glProgram(), sh.glVbo(), sh.glAPosLoc());
                    } else {
                        sh.setUniforms(self.effect, @floatFromInt(self.pixel_w), @floatFromInt(self.pixel_h));
                        sh.draw();
                    }
                } else {
                    sh.setUniforms(self.effect, @floatFromInt(self.pixel_w), @floatFromInt(self.pixel_h));
                    sh.draw();
                }
            } else {
                c.glClearColor(0.0, 0.0, 0.0, 1.0);
                c.glClear(c.GL_COLOR_BUFFER_BIT);
            }

            // Initialize password widget on first EGL render.
            if (self.password_widget == null) {
                self.password_widget = PasswordWidget.init() catch |err| blk: {
                    std.debug.print("PasswordWidget.init failed: {}\n", .{err});
                    break :blk null;
                };
            }

            // Render password overlay on top of shader effect.
            if (self.password_widget) |*pw| {
                pw.render(self.pixel_w, self.pixel_h, input.password_len, input.auth_state);
            }

            const cb = c.wl_surface_frame(wl_surface) orelse {
                std.debug.print("wl_surface_frame returned null (OOM), skipping callback arm\n", .{});
                return;
            };
            self.frame_callback = cb;
            _ = c.wl_callback_add_listener(cb, &LockSurfaceState.frame_callback_listener, self);

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

        self.effect.renderGrid(self.grid_w, self.grid_h, self.cell_grid);
        framebuffer.expandCells(self.cell_grid, self.grid_w, self.grid_h, pool.pixelSlice(idx), self.pixel_w, self.pixel_h);

        c.wl_surface_attach(wl_surface, pool.wlBuffer(idx), 0, 0);
        c.wl_surface_damage_buffer(wl_surface, 0, 0, std.math.maxInt(i32), std.math.maxInt(i32));

        const cb = c.wl_surface_frame(wl_surface) orelse {
            std.debug.print("wl_surface_frame returned null (OOM), skipping callback arm\n", .{});
            c.wl_surface_commit(wl_surface);
            return;
        };
        self.frame_callback = cb;
        _ = c.wl_callback_add_listener(cb, &LockSurfaceState.frame_callback_listener, self);

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

    pub fn deinit(self: *LockSurfaceState) void {
        if (self.dead) return;
        self.teardown();
    }

    fn teardown(self: *LockSurfaceState) void {
        if (self.frame_callback) |cb| {
            c.wl_callback_destroy(cb);
            self.frame_callback = null;
        }
        if (self.offscreen) |*ofs| {
            var gl_ok = false;
            if (self.egl_surface) |*egl_surf| {
                if (self.egl_ctx) |ctx| {
                    gl_ok = egl_surf.makeCurrent(ctx);
                }
            }
            if (gl_ok) {
                ofs.deinit();
            } else {
                std.debug.print("teardown: skipping GL cleanup (no current context), offscreen FBO leaked\n", .{});
            }
            self.offscreen = null;
        }
        // Password widget uses GL objects; clean up while context is still current.
        if (self.password_widget) |*pw| {
            var pw_gl_ok = false;
            if (self.egl_surface) |*egl_surf| {
                if (self.egl_ctx) |ctx| {
                    pw_gl_ok = egl_surf.makeCurrent(ctx);
                }
            }
            if (pw_gl_ok) {
                pw.deinit();
            } else {
                std.debug.print("teardown: skipping password_widget GL cleanup (no current context), GL objects leaked\n", .{});
            }
            self.password_widget = null;
        }
        if (self.egl_surface) |*egl_surf| {
            egl_surf.deinit();
            self.egl_surface = null;
        }
        // NOTE: Do NOT attach null buffer to lock surfaces — this is a protocol
        // violation. The compositor controls lock surface lifetime.
        self.lock_surface.destroy();
        if (self.shm_pool) |*pool| {
            pool.deinit();
            self.shm_pool = null;
        }
        if (self.cell_grid.len > 0) {
            self.allocator.free(self.cell_grid);
            self.cell_grid = &.{};
        }
        self.configured = false;
    }
};

fn lockSurfaceConfigure(
    data: ?*anyopaque,
    lock_surface: ?*c.ext_session_lock_surface_v1,
    serial: u32,
    width: u32,
    height: u32,
) callconv(.c) void {
    const self: *LockSurfaceState = @ptrCast(@alignCast(data));

    var pw = width;
    var ph = height;
    if (pw == 0) pw = self.pixel_w;
    if (ph == 0) ph = self.pixel_h;
    self.pixel_w = pw;
    self.pixel_h = ph;

    c.ext_session_lock_surface_v1_ack_configure(lock_surface, serial);
    std.debug.print("lockSurfaceConfigure entry: {}x{} serial={}\n", .{ pw, ph, serial });

    if (pw == 0 or ph == 0) {
        std.debug.print("lock configure: zero dimensions, skipping\n", .{});
        return;
    }

    if (self.egl_ctx) |ctx| {
        const wl_surface_egl = self.lock_surface.wl_surface orelse {
            self.configured = false;
            return;
        };
        var gl_context_current = false;
        if (self.egl_surface) |*existing| {
            existing.resize(pw, ph);
            if (existing.makeCurrent(ctx)) {
                gl_context_current = true;
                if (c.eglSwapInterval(ctx.display, 0) == c.EGL_FALSE) {
                    std.debug.print("lock configure resize: eglSwapInterval(0) failed\n", .{});
                }
                c.glViewport(0, 0, @intCast(pw), @intCast(ph));
            } else {
                std.debug.print("lock configure: makeCurrent failed during resize\n", .{});
            }
            self.needs_static_uniforms = true;
        } else {
            self.egl_surface = EglSurface.create(ctx, wl_surface_egl, pw, ph) catch |err| blk: {
                std.debug.print("EglSurface.create failed: {}\n", .{err});
                break :blk null;
            };
            if (self.egl_surface) |*egl_surf| {
                if (egl_surf.makeCurrent(ctx)) {
                    gl_context_current = true;
                    if (c.eglSwapInterval(ctx.display, 0) == c.EGL_FALSE) {
                        std.debug.print("eglSwapInterval(0) failed\n", .{});
                    }
                    c.glViewport(0, 0, @intCast(pw), @intCast(ph));
                }
            }
        }

        if (self.egl_surface != null and self.renderer_scale < 1.0 and gl_context_current) {
            const rw = @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(pw)) * self.renderer_scale)));
            const rh = @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(ph)) * self.renderer_scale)));
            if (self.offscreen) |*ofs| {
                if (!ofs.resize(rw, rh)) {
                    std.debug.print("lock configure: FBO incomplete after resize, disabling offscreen\n", .{});
                    ofs.deinit();
                    self.offscreen = null;
                }
            } else {
                self.offscreen = Offscreen.init(rw, rh, self.upscale_filter) catch |err| blk: {
                    std.debug.print("Offscreen.init failed: {}, rendering at full resolution\n", .{err});
                    break :blk null;
                };
            }
        } else if (gl_context_current) {
            if (self.offscreen) |*ofs| {
                ofs.deinit();
                self.offscreen = null;
            }
        }

        if (self.egl_surface) |*egl_surf| {
            if (egl_surf.makeCurrent(ctx)) {
                // Destroy any stale frame callback — renderTick owns all frame pacing.
                if (self.frame_callback) |old_cb| {
                    c.wl_callback_destroy(old_cb);
                    self.frame_callback = null;
                }
                c.glClearColor(0.0, 0.0, 0.0, 1.0);
                c.glClear(c.GL_COLOR_BUFFER_BIT);
                const swap_ok = egl_surf.swapBuffers();
                std.debug.print("lock configure (EGL): {}x{} swapBuffers={}\n", .{ pw, ph, swap_ok });
            }
            self.configured = true;
            return;
        }

        std.debug.print("lock configure: EGL surface unavailable, falling back to SHM\n", .{});
        self.egl_ctx = null;
    }

    // --- SHM/CPU fallback path ---
    const grid_w = @max(@divFloor(pw, @as(u32, defaults.CELL_W)), 1);
    const grid_h = @max(@divFloor(ph, @as(u32, defaults.CELL_H)), 1);
    self.grid_w = grid_w;
    self.grid_h = grid_h;

    if (self.cell_grid.len > 0) {
        self.allocator.free(self.cell_grid);
        self.cell_grid = &.{};
    }
    self.cell_grid = self.allocator.alloc(defaults.Rgb, grid_w * grid_h) catch {
        std.debug.print("OOM allocating cell_grid\n", .{});
        self.configured = false;
        return;
    };

    if (self.shm_pool) |*old| {
        old.deinit();
        self.shm_pool = null;
        self.buf_ctx = undefined;
    }
    self.shm_pool = ShmPool.init(self.shm, pw, ph) catch {
        std.debug.print("failed to create ShmPool\n", .{});
        self.configured = false;
        return;
    };
    self.buf_ctx[0] = .{ .pool_busy = &self.shm_pool.?.busy[0], .surface = self };
    self.buf_ctx[1] = .{ .pool_busy = &self.shm_pool.?.busy[1], .surface = self };
    self.shm_pool.?.attachListeners(
        &LockSurfaceState.buf_release_listener,
        @ptrCast(&self.buf_ctx[0]),
        @ptrCast(&self.buf_ctx[1]),
    );

    self.effect.renderGrid(grid_w, grid_h, self.cell_grid);

    var pool = &(self.shm_pool.?);
    const idx = pool.acquireBuffer() orelse {
        std.debug.print("no free buffer on lock configure\n", .{});
        return;
    };

    framebuffer.expandCells(self.cell_grid, grid_w, grid_h, pool.pixelSlice(idx), pw, ph);

    const wl_surface = self.lock_surface.wl_surface orelse return;
    c.wl_surface_attach(wl_surface, pool.wlBuffer(idx), 0, 0);
    c.wl_surface_damage_buffer(wl_surface, 0, 0, std.math.maxInt(i32), std.math.maxInt(i32));

    // Destroy any stale frame callback — renderTick owns all frame pacing.
    if (self.frame_callback) |old_cb| {
        c.wl_callback_destroy(old_cb);
        self.frame_callback = null;
    }

    c.wl_surface_commit(wl_surface);
    self.configured = true;
    std.debug.print("lock configure (SHM): {}x{} grid={}x{}\n", .{ pw, ph, grid_w, grid_h });
}

fn frameCallbackDone(
    data: ?*anyopaque,
    callback: ?*c.wl_callback,
    time_ms: u32,
) callconv(.c) void {
    const self: *LockSurfaceState = @ptrCast(@alignCast(data));

    _ = time_ms;
    c.wl_callback_destroy(callback);
    self.frame_callback = null;
    std.debug.print("frameCallbackDone fired\n", .{});
}

fn bufferRelease(data: ?*anyopaque, buffer: ?*c.wl_buffer) callconv(.c) void {
    _ = buffer;
    const ctx: *BufReleaseCtx = @ptrCast(@alignCast(data));
    if (ctx.pool_busy) |busy| {
        busy.* = false;
    }
}
