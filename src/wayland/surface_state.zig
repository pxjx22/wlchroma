const std = @import("std");
const c = @import("../wl.zig").c;
const LayerSurface = @import("layer_shell.zig").LayerSurface;
const ShmPool = @import("shm_pool.zig").ShmPool;
const SolidColorRenderer = @import("../render/solid.zig").SolidColorRenderer;
const framebuffer = @import("../render/framebuffer.zig");
const defaults = @import("../config/defaults.zig");
const OutputInfo = @import("output.zig").OutputInfo;

pub const SurfaceState = struct {
    allocator: std.mem.Allocator,
    layer_surface: LayerSurface,
    shm_pool: ?ShmPool,
    shm: *c.wl_shm,
    renderer: *SolidColorRenderer,
    cell_grid: []defaults.Rgb,
    grid_w: usize,
    grid_h: usize,
    pixel_w: u32,
    pixel_h: u32,
    configured: bool,
    display: *c.wl_display,

    const layer_surface_listener = c.zwlr_layer_surface_v1_listener{
        .configure = layerSurfaceConfigure,
        .closed = layerSurfaceClosed,
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
        renderer: *SolidColorRenderer,
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

    pub fn deinit(self: *SurfaceState, display: *c.wl_display) void {
        _ = display;
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

    if (pw == 0 or ph == 0) {
        std.debug.print("configure: zero dimensions, skipping\n", .{});
        c.zwlr_layer_surface_v1_ack_configure(layer_surface, serial);
        return;
    }

    const grid_w = @max(@divFloor(pw, @as(u32, defaults.CELL_W)), 1);
    const grid_h = @max(@divFloor(ph, @as(u32, defaults.CELL_H)), 1);
    self.grid_w = grid_w;
    self.grid_h = grid_h;

    // Free old cell_grid if reconfigured
    if (self.cell_grid.len > 0) {
        self.allocator.free(self.cell_grid);
    }
    self.cell_grid = self.allocator.alloc(defaults.Rgb, grid_w * grid_h) catch {
        std.debug.print("OOM allocating cell_grid\n", .{});
        return;
    };

    // Init/reinit ShmPool
    if (self.shm_pool) |*old| old.deinit();
    self.shm_pool = ShmPool.init(self.shm, pw, ph) catch {
        std.debug.print("failed to create ShmPool\n", .{});
        return;
    };

    // Ack configure
    c.zwlr_layer_surface_v1_ack_configure(layer_surface, serial);

    self.renderer.renderGrid(grid_w, grid_h, self.cell_grid);

    var pool = &(self.shm_pool.?);
    const idx = pool.acquireBuffer() orelse {
        std.debug.print("no free buffer\n", .{});
        return;
    };

    const pixels = pool.pixelSlice(idx);
    framebuffer.expandCells(self.cell_grid, grid_w, grid_h, pixels, pw, ph);

    // Attach, damage, commit
    const wl_surface = self.layer_surface.wl_surface orelse return;
    c.wl_surface_attach(wl_surface, pool.wlBuffer(idx), 0, 0);
    c.wl_surface_damage_buffer(wl_surface, 0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
    c.wl_surface_commit(wl_surface);

    self.configured = true;
    std.debug.print("configure: {}x{} grid={}x{}\n", .{ pw, ph, grid_w, grid_h });
}

fn layerSurfaceClosed(
    data: ?*anyopaque,
    layer_surface: ?*c.zwlr_layer_surface_v1,
) callconv(.c) void {
    _ = layer_surface;
    _ = data;
    std.debug.print("layer surface closed, exiting\n", .{});
    std.process.exit(0);
}
