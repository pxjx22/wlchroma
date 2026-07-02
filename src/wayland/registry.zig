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
    outputs: ?*std.ArrayList(*OutputInfo) = null,
    allocator: std.mem.Allocator = undefined,

    const Self = @This();

    pub fn bind(self: *Self, display: *c.wl_display, outputs: *std.ArrayList(*OutputInfo), allocator: std.mem.Allocator) !void {
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
    } else if (std.mem.eql(u8, iface, std.mem.sliceTo(c.wl_output_interface.name, 0))) {
        // Bind at most version 3: gives done + mode + geometry events.
        // Version 4 adds name/description which are nice-to-have but many
        // compositors (especially older wlroots-based ones) only support v2/v3.
        const wl_out: ?*c.wl_output = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_output_interface, @min(version, 3)));
        if (wl_out == null) return;

        const outputs = self.outputs orelse return;
        // Heap-allocate so the address (used as wl_output listener userdata)
        // stays valid for the output's lifetime regardless of list growth.
        const info = self.allocator.create(OutputInfo) catch {
            std.debug.print("registry: OOM recording output {}, skipping\n", .{name});
            return;
        };
        info.* = OutputInfo{
            .wl_output = wl_out,
            .registry_name = name,
            .name = "",
            .width = 0,
            .height = 0,
            .refresh_mhz = 0,
            .done = false,
            .removed = false,
            .allocator = self.allocator,
        };
        outputs.append(self.allocator, info) catch {
            std.debug.print("registry: OOM appending output {}, skipping\n", .{name});
            info.deinit();
            self.allocator.destroy(info);
            return;
        };
        _ = c.wl_output_add_listener(wl_out, &output_mod.output_listener, info);
    }
}

fn registryGlobalRemove(
    data: ?*anyopaque,
    registry: ?*c.wl_registry,
    name: u32,
) callconv(.c) void {
    _ = registry;
    const self: *Registry = @ptrCast(@alignCast(data));
    const outputs = self.outputs orelse return;

    // Callbacks only record facts; the main loop's syncSurfaces() pass
    // performs the actual surface/output teardown outside dispatch context.
    for (outputs.items) |out| {
        if (out.registry_name == name and !out.removed) {
            out.removed = true;
            std.debug.print("output removed: name={}{s}{s}\n", .{
                name,
                if (out.name.len > 0) " " else "",
                out.name,
            });
            return;
        }
    }
    // Not an output global (or already handled) — nothing to do.
}
