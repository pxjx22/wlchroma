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
    session_lock_manager: ?*c.ext_session_lock_manager_v1 = null,
    seat: ?*c.wl_seat = null,
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
        if (self.session_lock_manager) |slm| c.ext_session_lock_manager_v1_destroy(slm);
        if (self.seat) |seat| c.wl_seat_destroy(seat);
        if (self.wl_registry) |reg| c.wl_registry_destroy(reg);
        self.compositor = null;
        self.shm = null;
        self.layer_shell = null;
        self.session_lock_manager = null;
        self.seat = null;
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
    const self: *Registry = @ptrCast(@alignCast(data));
    const iface = std.mem.sliceTo(interface, 0);

    if (std.mem.eql(u8, iface, std.mem.sliceTo(c.wl_compositor_interface.name, 0))) {
        self.compositor = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_compositor_interface, 4));
    } else if (std.mem.eql(u8, iface, std.mem.sliceTo(c.wl_shm_interface.name, 0))) {
        // wl_shm is bound even on the EGL path as a fallback; if EGL init
        // fails, the CPU/SHM path uses it for software rendering.
        self.shm = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_shm_interface, 1));
    } else if (std.mem.eql(u8, iface, std.mem.sliceTo(c.zwlr_layer_shell_v1_interface.name, 0))) {
        self.layer_shell = @ptrCast(c.wl_registry_bind(registry, name, &c.zwlr_layer_shell_v1_interface, 4));
    } else if (std.mem.eql(u8, iface, "ext_session_lock_manager_v1")) {
        self.session_lock_manager = @ptrCast(c.wl_registry_bind(
            registry,
            name,
            &c.ext_session_lock_manager_v1_interface,
            1,
        ));
    } else if (std.mem.eql(u8, iface, std.mem.sliceTo(c.wl_seat_interface.name, 0))) {
        self.seat = @ptrCast(c.wl_registry_bind(
            registry,
            name,
            &c.wl_seat_interface,
            @min(version, 7),
        ));
    } else if (std.mem.eql(u8, iface, std.mem.sliceTo(c.wl_output_interface.name, 0))) {
        // Bind at most version 3: gives done + mode + geometry events.
        // Version 4 adds name/description which are nice-to-have but many
        // compositors (especially older wlroots-based ones) only support v2/v3.
        const wl_out: ?*c.wl_output = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_output_interface, @min(version, 3)));
        if (wl_out == null) return;

        const outputs = self.outputs orelse return;
        const info = OutputInfo{
            .wl_output = wl_out,
            .name = "",
            .width = 0,
            .height = 0,
            .refresh_mhz = 0,
            .done = false,
            .removed = false,
            .allocator = self.allocator,
        };
        // Capacity is pre-reserved in App.init (MAX_OUTPUTS) so appends
        // after startup do not reallocate and existing item pointers
        // (used as wl_output listener userdata) remain valid.
        outputs.append(self.allocator, info) catch return;

        // If listeners have already been attached (post-startup hotplug),
        // attach immediately -- the pointer is stable because capacity
        // was pre-reserved.
        const new_out = &outputs.items[outputs.items.len - 1];
        if (new_out.wl_output) |out| {
            _ = c.wl_output_add_listener(out, &@import("output.zig").output_listener, new_out);
        }
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
