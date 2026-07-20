const std = @import("std");
const c = @import("../wl.zig").c;
const OutputInfo = @import("output.zig").OutputInfo;
const output_mod = @import("output.zig");

pub const OutputRegistrationOps = struct {
    context: ?*anyopaque,
    bind: *const fn (?*anyopaque, ?*c.wl_registry, u32, u32) ?*c.wl_output,
    add_listener: *const fn (?*anyopaque, *c.wl_output, *OutputInfo) c_int,
    release: *const fn (?*anyopaque, *c.wl_output) void,
};

pub fn registerOutputWithOps(
    allocator: std.mem.Allocator,
    outputs: *std.ArrayList(*OutputInfo),
    registry: ?*c.wl_registry,
    name: u32,
    version: u32,
    ops: OutputRegistrationOps,
) !void {
    const info = try allocator.create(OutputInfo);
    errdefer allocator.destroy(info);

    const proxy = ops.bind(ops.context, registry, name, @min(version, 3)) orelse
        return error.OutputBindFailed;
    info.* = .{
        .wl_output = proxy,
        .registry_name = name,
        .name = "",
        .width = 0,
        .height = 0,
        .refresh_mhz = 0,
        .done = false,
        .removed = false,
        .allocator = allocator,
    };
    errdefer {
        ops.release(ops.context, proxy);
        info.wl_output = null;
        info.deinit();
    }

    try outputs.append(allocator, info);
    errdefer std.debug.assert(outputs.pop().? == info);
    if (ops.add_listener(ops.context, proxy, info) != 0) {
        return error.OutputListenerFailed;
    }
}

fn bindOutput(_: ?*anyopaque, registry: ?*c.wl_registry, name: u32, version: u32) ?*c.wl_output {
    return @ptrCast(c.wl_registry_bind(registry, name, &c.wl_output_interface, version));
}

fn addOutputListener(_: ?*anyopaque, out: *c.wl_output, info: *OutputInfo) c_int {
    return c.wl_output_add_listener(out, &output_mod.output_listener, info);
}

fn releaseOutput(_: ?*anyopaque, out: *c.wl_output) void {
    output_mod.releaseProxy(out);
}

const output_registration_ops = OutputRegistrationOps{
    .context = null,
    .bind = bindOutput,
    .add_listener = addOutputListener,
    .release = releaseOutput,
};

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
        const outputs = self.outputs orelse return;
        registerOutputWithOps(
            self.allocator,
            outputs,
            registry,
            name,
            version,
            output_registration_ops,
        ) catch |err| {
            std.debug.print("registry: failed to register output {}: {s}\n", .{ name, @errorName(err) });
        };
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
