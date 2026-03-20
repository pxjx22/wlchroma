const std = @import("std");
const c = @import("../wl.zig").c;

pub const OutputInfo = struct {
    wl_output: ?*c.wl_output,
    name: []const u8,
    width: i32,
    height: i32,
    /// Output refresh rate in mHz (Hz * 1000), e.g. 60000 = 60Hz.
    /// Stored from the wl_output.mode event for future timer tuning.
    refresh_mhz: i32,
    done: bool,
    /// Set true when the compositor removes this output via wl_registry.global_remove.
    /// The OutputInfo entry remains in the ArrayList (stable pointer) but will not
    /// be used to create new surfaces.
    removed: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *OutputInfo) void {
        if (self.wl_output) |out| {
            c.wl_output_release(out);
            self.wl_output = null;
        }
        if (self.name.len > 0) {
            self.allocator.free(self.name);
            self.name = "";
        }
    }
};

// Correction #3: all 6 wl_output_listener callbacks

fn outputGeometry(
    data: ?*anyopaque,
    wl_output: ?*c.wl_output,
    x: i32,
    y: i32,
    physical_width: i32,
    physical_height: i32,
    subpixel: i32,
    make: [*c]const u8,
    model: [*c]const u8,
    transform: i32,
) callconv(.c) void {
    _ = data;
    _ = wl_output;
    _ = x;
    _ = y;
    _ = physical_width;
    _ = physical_height;
    _ = subpixel;
    _ = make;
    _ = model;
    _ = transform;
}

fn outputMode(
    data: ?*anyopaque,
    wl_output: ?*c.wl_output,
    flags: u32,
    width: i32,
    height: i32,
    refresh: i32,
) callconv(.c) void {
    _ = wl_output;
    // Only record dimensions for the current mode; compositors may
    // advertise multiple modes, but only the current one is active.
    if (flags & c.WL_OUTPUT_MODE_CURRENT == 0) return;
    const self: *OutputInfo = @ptrCast(@alignCast(data));
    self.width = width;
    self.height = height;
    self.refresh_mhz = refresh;
}

fn outputDone(
    data: ?*anyopaque,
    wl_output: ?*c.wl_output,
) callconv(.c) void {
    _ = wl_output;
    const self: *OutputInfo = @ptrCast(@alignCast(data));
    self.done = true;
}

fn outputScale(
    data: ?*anyopaque,
    wl_output: ?*c.wl_output,
    factor: i32,
) callconv(.c) void {
    _ = data;
    _ = wl_output;
    _ = factor;
}

fn outputName(
    data: ?*anyopaque,
    wl_output: ?*c.wl_output,
    name_str: [*c]const u8,
) callconv(.c) void {
    _ = wl_output;
    const self: *OutputInfo = @ptrCast(@alignCast(data));
    if (self.name.len > 0) {
        self.allocator.free(self.name);
    }
    const slice = std.mem.sliceTo(name_str, 0);
    self.name = self.allocator.dupe(u8, slice) catch "";
}

fn outputDescription(
    data: ?*anyopaque,
    wl_output: ?*c.wl_output,
    description: [*c]const u8,
) callconv(.c) void {
    _ = data;
    _ = wl_output;
    _ = description;
}

pub const output_listener = c.wl_output_listener{
    .geometry = outputGeometry,
    .mode = outputMode,
    .done = outputDone,
    .scale = outputScale,
    .name = outputName,
    .description = outputDescription,
};
