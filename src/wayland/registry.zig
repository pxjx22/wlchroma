const std = @import("std");
const c = @import("../wl.zig").c;
const OutputInfo = @import("output.zig").OutputInfo;
const output_mod = @import("output.zig");

/// File-scope listener struct -- must outlive the wl_registry object.
/// Defined at file scope (not inside a function) so the Wayland C library's
/// raw pointer to this listener remains valid for the lifetime of the process.
const registry_listener = c.wl_registry_listener{
    .global = registryGlobal,
    .global_remove = registryGlobalRemove,
};

pub const Registry = struct {
    compositor: ?*c.wl_compositor = null,
    shm: ?*c.wl_shm = null,
    layer_shell: ?*c.zwlr_layer_shell_v1 = null,
    wl_registry: ?*c.wl_registry = null,
    outputs: ?*std.ArrayList(OutputInfo) = null,
    allocator: std.mem.Allocator = undefined,

    const Self = @This();

    pub fn bind(self: *Self, display: *c.wl_display, outputs: *std.ArrayList(OutputInfo), allocator: std.mem.Allocator) !void {
        self.outputs = outputs;
        self.allocator = allocator;
        self.wl_registry = c.wl_display_get_registry(display) orelse return error.RegistryFailed;
        _ = c.wl_registry_add_listener(self.wl_registry, &registry_listener, self);
    }

    pub fn deinit(self: *Self) void {
        if (self.compositor) |comp| c.wl_compositor_destroy(comp);
        if (self.shm) |shm| c.wl_shm_destroy(shm);
        if (self.layer_shell) |ls| c.zwlr_layer_shell_v1_destroy(ls);
        if (self.wl_registry) |reg| c.wl_registry_destroy(reg);
        self.compositor = null;
        self.shm = null;
        self.layer_shell = null;
        self.wl_registry = null;
    }
};

// Correction #1: callconv(.c) lowercase
fn registryGlobal(
    data: ?*anyopaque,
    registry: ?*c.wl_registry,
    name: u32,
    interface: [*c]const u8,
    version: u32,
) callconv(.c) void {
    _ = version;
    const self: *Registry = @ptrCast(@alignCast(data));
    const iface = std.mem.sliceTo(interface, 0);

    if (std.mem.eql(u8, iface, std.mem.sliceTo(c.wl_compositor_interface.name, 0))) {
        self.compositor = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_compositor_interface, 4));
    } else if (std.mem.eql(u8, iface, std.mem.sliceTo(c.wl_shm_interface.name, 0))) {
        self.shm = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_shm_interface, 1));
    } else if (std.mem.eql(u8, iface, std.mem.sliceTo(c.zwlr_layer_shell_v1_interface.name, 0))) {
        self.layer_shell = @ptrCast(c.wl_registry_bind(registry, name, &c.zwlr_layer_shell_v1_interface, 4));
    } else if (std.mem.eql(u8, iface, std.mem.sliceTo(c.wl_output_interface.name, 0))) {
        const wl_out: ?*c.wl_output = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_output_interface, 4));
        if (wl_out == null) return;

        const outputs = self.outputs orelse return;
        const info = OutputInfo{
            .wl_output = wl_out,
            .name = "",
            .width = 0,
            .height = 0,
            .refresh_mhz = 0,
            .done = false,
            .allocator = self.allocator,
        };
        // Append only; do NOT register wl_output listener here.
        // The ArrayList may reallocate on subsequent appends, which would
        // invalidate any pointer passed as listener data.  Listeners are
        // attached in a second pass after all outputs have been collected
        // (see App.init).
        outputs.append(self.allocator, info) catch return;
    }
}

fn registryGlobalRemove(
    data: ?*anyopaque,
    registry: ?*c.wl_registry,
    name: u32,
) callconv(.c) void {
    _ = data;
    _ = registry;
    // Hot-unplug handling is deferred. Full support would require:
    //   1. Matching `name` back to the OutputInfo/SurfaceState that owns it
    //   2. Tearing down the EGL surface, SHM pool, and layer surface
    //   3. Removing the entry from the surfaces ArrayList (invalidating ptrs)
    // Since this is a wallpaper daemon that typically runs for the session
    // lifetime, logging and continuing is acceptable. The compositor will
    // close the layer surface if the output goes away, triggering
    // layerSurfaceClosed -> clean shutdown.
    std.debug.print("registry: global {} removed (hot-unplug handling deferred)\n", .{name});
}
