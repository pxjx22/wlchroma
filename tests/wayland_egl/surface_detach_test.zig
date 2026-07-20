const std = @import("std");
const wayland = @import("wayland_test");
const App = wayland.app.App;
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

test "retiring CPU-only last surface clears App cleanup scratch" {
    var app: App = undefined;
    app.surfaces = .empty;
    app.detached_gpu = .empty;
    defer app.detached_gpu.deinit(std.testing.allocator);
    try app.detached_gpu.ensureTotalCapacity(std.testing.allocator, 1);
    app.egl_ctx = null;
    app.effect_shader = null;
    app.blit_shader = null;

    var state: SurfaceState = undefined;
    state.egl_ctx = null;
    state.egl_surface = null;
    state.offscreen = null;

    App.TestAdapter.retireSurfaceGpu(&app, &state);

    try std.testing.expectEqual(@as(usize, 0), app.detached_gpu.items.len);
    try std.testing.expect(state.egl_ctx == null);
    try std.testing.expect(state.egl_surface == null);
    try std.testing.expect(state.offscreen == null);
}
