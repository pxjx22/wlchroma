const std = @import("std");
const c = @import("../wl.zig").c;
const LayerSurface = @import("layer_shell.zig").LayerSurface;
const ShmPool = @import("shm_pool.zig").ShmPool;
const ColormixRenderer = @import("../render/colormix.zig").ColormixRenderer;
const framebuffer = @import("../render/framebuffer.zig");
const defaults = @import("../config/defaults.zig");
const OutputInfo = @import("output.zig").OutputInfo;
const EglSurface = @import("../render/egl_surface.zig").EglSurface;
const EglContext = @import("../render/egl_context.zig").EglContext;
const ShaderProgram = @import("../render/shader.zig").ShaderProgram;

/// Context passed as userdata to each wl_buffer release listener.
/// Carries a pointer back into ShmPool.busy[i] so acquireBuffer
/// works unchanged.
pub const BufReleaseCtx = struct {
    pool_busy: *bool,
    surface: *SurfaceState,
};

pub const SurfaceState = struct {
    allocator: std.mem.Allocator,
    layer_surface: LayerSurface,
    shm_pool: ?ShmPool,
    shm: *c.wl_shm,
    renderer: *ColormixRenderer,
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
    /// Per-buffer release context, stored here so the release handler
    /// can reach both the ShmPool busy flag and the SurfaceState.
    buf_ctx: [2]BufReleaseCtx,

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

    /// Create the SurfaceState value. Does NOT attach the listener yet --
    /// call `attach` after storing at its final address.
    pub fn create(
        allocator: std.mem.Allocator,
        compositor: *c.wl_compositor,
        shm: *c.wl_shm,
        layer_shell: *c.zwlr_layer_shell_v1,
        out: *const OutputInfo,
        display: *c.wl_display,
        renderer: *ColormixRenderer,
        running: *bool,
        egl_ctx: ?*const EglContext,
    ) !SurfaceState {
        const layer_surf = try LayerSurface.create(compositor, layer_shell, out.wl_output, "wallpaper");

        return SurfaceState{
            .allocator = allocator,
            .layer_surface = layer_surf,
            .shm_pool = null,
            .shm = shm,
            .renderer = renderer,
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
            .buf_ctx = undefined, // initialized after shm_pool is stable
        };
    }

    /// Attach listener and do initial commit. Must be called on the
    /// SurfaceState at its final memory location (i.e. inside the ArrayList).
    pub fn attach(self: *SurfaceState) void {
        _ = c.zwlr_layer_surface_v1_add_listener(
            self.layer_surface.layer_surface,
            &layer_surface_listener,
            self,
        );
        // Initial commit with no buffer triggers configure event
        c.wl_surface_commit(self.layer_surface.wl_surface);
    }

    /// Called by the timerfd tick in the main loop (~30fps).
    /// Renders a new frame if the compositor has presented the previous one
    /// (frame_callback == null) and a buffer is available.
    /// Render one frame. The shader pointer is passed per-call to avoid
    /// storing a borrowed pointer on the struct.
    pub fn renderTick(self: *SurfaceState, shader: ?*const ShaderProgram) void {
        if (!self.configured) return;

        // Compositor backpressure: if a frame callback is still pending,
        // the compositor has not yet presented the last committed buffer.
        // Skip this tick to avoid piling up frames.
        if (self.frame_callback != null) return;

        const wl_surface = self.layer_surface.wl_surface orelse return;

        // EGL path: render via GPU when an EGL surface is available.
        if (self.egl_surface) |*egl_surf| {
            const ctx = self.egl_ctx.?;
            if (!egl_surf.makeCurrent(ctx)) return;

            // TODO(Phase 4): call renderer.maybeAdvance + pass uniforms to shader
            if (shader) |sh| {
                c.glViewport(0, 0, @intCast(self.pixel_w), @intCast(self.pixel_h));
                sh.draw(0.2, 0.4, 0.8); // solid blue -- visible proof shader pipeline works
            } else {
                // Shader not ready yet, keep the black clear as fallback
                c.glClearColor(0.0, 0.0, 0.0, 1.0);
                c.glClear(c.GL_COLOR_BUFFER_BIT);
            }

            // Arm frame callback BEFORE eglSwapBuffers so the
            // wl_surface_frame request is included in the same commit
            // that swap triggers internally.
            const cb = c.wl_surface_frame(wl_surface);
            self.frame_callback = cb;
            _ = c.wl_callback_add_listener(cb, &SurfaceState.frame_callback_listener, self);

            if (!egl_surf.swapBuffers()) {
                std.debug.print("eglSwapBuffers failed\n", .{});
            }
            return;
        }

        // SHM/CPU fallback path
        var pool = &(self.shm_pool orelse return);
        const idx = pool.acquireBuffer() orelse {
            // Both buffers busy -- skip this tick. bufferRelease will
            // free one eventually and the next timer tick will render.
            return;
        };

        // Advance animation state and render
        const now_ms = getMonotonicMs();
        self.renderer.maybeAdvance(now_ms);
        self.renderer.renderGrid(self.grid_w, self.grid_h, self.cell_grid);
        framebuffer.expandCells(self.cell_grid, self.grid_w, self.grid_h, pool.pixelSlice(idx), self.pixel_w, self.pixel_h);

        c.wl_surface_attach(wl_surface, pool.wlBuffer(idx), 0, 0);
        c.wl_surface_damage_buffer(wl_surface, 0, 0, std.math.maxInt(i32), std.math.maxInt(i32));

        // Arm frame callback to track when compositor presents this buffer.
        // The callback does NOT trigger rendering -- only clears the flag.
        const cb = c.wl_surface_frame(wl_surface);
        self.frame_callback = cb;
        _ = c.wl_callback_add_listener(cb, &SurfaceState.frame_callback_listener, self);

        c.wl_surface_commit(wl_surface);
    }

    /// Read CLOCK_MONOTONIC and return milliseconds (wrapping u32).
    fn getMonotonicMs() u32 {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        const ms: u64 = @intCast(ts.sec * 1000 + @divFloor(ts.nsec, 1_000_000));
        return @truncate(ms);
    }

    pub fn deinit(self: *SurfaceState, display: *c.wl_display) void {
        if (self.frame_callback) |cb| {
            c.wl_callback_destroy(cb);
            self.frame_callback = null;
        }
        // Tear down EGL surface before the layer surface (wl_surface)
        // is destroyed. EglContext.deinit happens later in App.deinit.
        if (self.egl_surface) |*egl_surf| {
            egl_surf.deinit();
            self.egl_surface = null;
        }
        if (self.configured) {
            if (self.layer_surface.wl_surface) |ws| {
                c.wl_surface_attach(ws, null, 0, 0);
                c.wl_surface_commit(ws);
                // Drain pending release events before destroying buffers
                _ = c.wl_display_roundtrip(display);
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

    var pw = width;
    var ph = height;
    if (pw == 0) pw = self.pixel_w;
    if (ph == 0) ph = self.pixel_h;
    self.pixel_w = pw;
    self.pixel_h = ph;

    // Always ack the configure to avoid stalling the compositor.
    c.zwlr_layer_surface_v1_ack_configure(layer_surface, serial);

    if (pw == 0 or ph == 0) {
        std.debug.print("configure: zero dimensions, skipping\n", .{});
        return;
    }

    // EGL surface setup: create on first configure, resize on subsequent.
    // When EGL is active, skip SHM pool and cell_grid allocation entirely --
    // the GPU path does not use wl_shm buffers.
    if (self.egl_ctx) |ctx| {
        const wl_surface_egl = self.layer_surface.wl_surface orelse {
            self.configured = false;
            return;
        };
        if (self.egl_surface) |*existing| {
            // Resize the existing EGL window -- no need to recreate EGLSurface
            existing.resize(pw, ph);
        } else {
            // First configure: create the EGL surface
            self.egl_surface = EglSurface.create(ctx, wl_surface_egl, pw, ph) catch |err| blk: {
                std.debug.print("EglSurface.create failed: {}\n", .{err});
                break :blk null;
            };
            if (self.egl_surface) |*egl_surf| {
                if (egl_surf.makeCurrent(ctx)) {
                    _ = c.eglSwapInterval(ctx.display, 0);
                }
            }
        }

        // With EGL, render the first frame via GPU and skip the shm path
        if (self.egl_surface) |*egl_surf| {
            if (egl_surf.makeCurrent(ctx)) {
                // Shader is not available in the configure callback (it's
                // initialized later in App.run). Clear to black; the first
                // real shader frame will arrive on the next timer tick.
                c.glClearColor(0.0, 0.0, 0.0, 1.0);
                c.glClear(c.GL_COLOR_BUFFER_BIT);

                // Destroy any stale callback, then arm before swap
                if (self.frame_callback) |old_cb| c.wl_callback_destroy(old_cb);
                const cb = c.wl_surface_frame(wl_surface_egl);
                self.frame_callback = cb;
                _ = c.wl_callback_add_listener(cb, &SurfaceState.frame_callback_listener, self);

                _ = egl_surf.swapBuffers();
            }
            self.configured = true;
            std.debug.print("configure (EGL): {}x{}\n", .{ pw, ph });
            return;
        }

        // EGL surface creation failed -- mark unconfigured so renderTick skips
        self.configured = false;
        return;
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

    // Tear down old SHM pool. Set self.shm_pool = null first so that on
    // failure of the new init, we do not hold a dangling (deinitialized) pool.
    // wl_buffer_destroy is safe per protocol even if the compositor holds a
    // reference -- the compositor will release it internally. No roundtrip
    // needed (calling wl_display_roundtrip inside a callback is re-entrant UB).
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
    // Initialize per-buffer release contexts now that shm_pool is at its
    // final address inside this SurfaceState.
    self.buf_ctx[0] = .{ .pool_busy = &self.shm_pool.?.busy[0], .surface = self };
    self.buf_ctx[1] = .{ .pool_busy = &self.shm_pool.?.busy[1], .surface = self };
    self.shm_pool.?.attachListeners(
        &SurfaceState.buf_release_listener,
        @ptrCast(&self.buf_ctx[0]),
        @ptrCast(&self.buf_ctx[1]),
    );

    // SHM/CPU fallback: render first frame from current renderer state
    self.renderer.renderGrid(grid_w, grid_h, self.cell_grid);

    var pool = &(self.shm_pool.?);
    const idx = pool.acquireBuffer() orelse {
        std.debug.print("no free buffer on configure\n", .{});
        return;
    };

    framebuffer.expandCells(self.cell_grid, grid_w, grid_h, pool.pixelSlice(idx), pw, ph);

    const wl_surface = self.layer_surface.wl_surface orelse return;
    c.wl_surface_attach(wl_surface, pool.wlBuffer(idx), 0, 0);
    c.wl_surface_damage_buffer(wl_surface, 0, 0, std.math.maxInt(i32), std.math.maxInt(i32));

    // Destroy any stale callback, then request next frame BEFORE commit
    if (self.frame_callback) |old_cb| c.wl_callback_destroy(old_cb);
    const cb = c.wl_surface_frame(wl_surface);
    self.frame_callback = cb;
    _ = c.wl_callback_add_listener(cb, &SurfaceState.frame_callback_listener, self);

    c.wl_surface_commit(wl_surface);
    self.configured = true;
    std.debug.print("configure: {}x{} grid={}x{}\n", .{ pw, ph, grid_w, grid_h });
}

/// Frame callback handler. The compositor calls this when the previously
/// committed buffer has been presented. We only clear the flag here --
/// actual rendering is driven by the timerfd in the main loop.
fn frameCallbackDone(
    data: ?*anyopaque,
    callback: ?*c.wl_callback,
    time_ms: u32,
) callconv(.c) void {
    _ = time_ms;
    const self: *SurfaceState = @ptrCast(@alignCast(data));

    c.wl_callback_destroy(callback);
    self.frame_callback = null;
}

/// Layer surface closed by the compositor. This sets the shared App.running
/// flag to false, which terminates the entire application. This is intentional:
/// any output closing triggers a full shutdown. Per-output lifecycle tracking
/// (allowing other outputs to continue) is out of scope for now.
fn layerSurfaceClosed(
    data: ?*anyopaque,
    layer_surface: ?*c.zwlr_layer_surface_v1,
) callconv(.c) void {
    _ = layer_surface;
    const self: *SurfaceState = @ptrCast(@alignCast(data));
    std.debug.print("layer surface closed, signaling shutdown\n", .{});
    self.running.* = false;
}

/// wl_buffer.release handler. Clears the busy flag in ShmPool so
/// acquireBuffer can hand the buffer out again. No chain restart
/// needed -- the timerfd in the main loop drives render attempts.
fn bufferRelease(data: ?*anyopaque, buffer: ?*c.wl_buffer) callconv(.c) void {
    _ = buffer;
    const ctx: *BufReleaseCtx = @ptrCast(@alignCast(data));
    ctx.pool_busy.* = false;
}
