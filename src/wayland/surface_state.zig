const std = @import("std");
const c = @import("../wl.zig").c;
const LayerSurface = @import("layer_shell.zig").LayerSurface;
const ShmPool = @import("shm_pool.zig").ShmPool;
const ColormixRenderer = @import("../render/colormix.zig").ColormixRenderer;
const framebuffer = @import("../render/framebuffer.zig");
const defaults = @import("../config/defaults.zig");
const OutputInfo = @import("output.zig").OutputInfo;

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
    pub fn renderTick(self: *SurfaceState) void {
        if (!self.configured) return;

        // Compositor backpressure: if a frame callback is still pending,
        // the compositor has not yet presented the last committed buffer.
        // Skip this tick to avoid piling up frames.
        if (self.frame_callback != null) return;

        const wl_surface = self.layer_surface.wl_surface orelse return;

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

    const grid_w = @max(@divFloor(pw, @as(u32, defaults.CELL_W)), 1);
    const grid_h = @max(@divFloor(ph, @as(u32, defaults.CELL_H)), 1);
    self.grid_w = grid_w;
    self.grid_h = grid_h;

    if (self.cell_grid.len > 0) {
        self.allocator.free(self.cell_grid);
    }
    self.cell_grid = self.allocator.alloc(defaults.Rgb, grid_w * grid_h) catch {
        std.debug.print("OOM allocating cell_grid\n", .{});
        return;
    };

    if (self.shm_pool) |*old| {
        // Detach the current buffer and roundtrip so the compositor
        // releases any reference before we destroy the old pool's mmap.
        if (self.layer_surface.wl_surface) |ws| {
            c.wl_surface_attach(ws, null, 0, 0);
            c.wl_surface_commit(ws);
            _ = c.wl_display_roundtrip(self.display);
        }
        old.deinit();
    }
    self.shm_pool = ShmPool.init(self.shm, pw, ph) catch {
        std.debug.print("failed to create ShmPool\n", .{});
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

    // Render first frame from current renderer state (frame 0)
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
