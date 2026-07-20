const std = @import("std");
const wayland = @import("wayland_test");
const SurfaceState = wayland.surface_state.SurfaceState;

fn setDetachFields(state: *SurfaceState, dead: bool, configured: bool, has_extent: bool) void {
    state.dead = dead;
    state.configured = configured;
    state.extent = if (has_extent)
        wayland.dimensions.Extent.init(1920, 1080) catch unreachable
    else
        null;
    state.egl_ctx = @as(
        *const wayland.egl_context.EglContext,
        @ptrFromInt(0x1000),
    );
    state.egl_surface = null;
    state.offscreen = null;
}

fn expectDetached(state: *SurfaceState) !void {
    const detached = state.detachGpu();
    try std.testing.expect(detached.egl_surface == null);
    try std.testing.expect(detached.offscreen == null);
    try std.testing.expect(state.egl_ctx == null);
    try std.testing.expect(state.egl_surface == null);
    try std.testing.expect(state.offscreen == null);
}

test "dead surface invalidates its context borrow" {
    var state: SurfaceState = undefined;
    setDetachFields(&state, true, true, true);
    try expectDetached(&state);
}

test "zero-sized surface invalidates its context borrow" {
    var state: SurfaceState = undefined;
    setDetachFields(&state, false, false, false);
    try expectDetached(&state);
}

test "unconfigured surface invalidates its context borrow" {
    var state: SurfaceState = undefined;
    setDetachFields(&state, false, false, true);
    try expectDetached(&state);
}
