const std = @import("std");
const wayland = @import("wayland_test");
const App = wayland.app.App;
const SurfaceState = wayland.surface_state.SurfaceState;

test "App owns the only animation state" {
    try std.testing.expect(@hasField(App, "animation"));
    try std.testing.expect(!@hasDecl(wayland.effect.Effect, "maybeAdvance"));
    try std.testing.expect(!@hasDecl(wayland.effect.Effect, "frameCount"));
    try std.testing.expect(!@hasDecl(wayland.effect.Effect, "setSpeed"));
    try std.testing.expect(!@hasField(wayland.gpu_effect_state.GpuEffectState, "frames"));
    try std.testing.expect(!@hasField(wayland.gpu_effect_state.GpuEffectState, "last_advance_ms"));
    try std.testing.expect(!@hasField(wayland.colormix.ColormixRenderer, "frames"));
}

test "surface readiness requires live configured callback-free Wayland state" {
    var output: wayland.output.OutputInfo = undefined;
    output.removed = false;

    var state: SurfaceState = undefined;
    state.output = &output;
    state.dead = false;
    state.torn_down = false;
    state.configured = true;
    state.extent = try wayland.dimensions.Extent.init(1920, 1080);
    state.frame_callback = null;
    state.layer_surface = .{
        .wl_surface = @as(*wayland.c.wl_surface, @ptrFromInt(0x1000)),
        .layer_surface = null,
    };

    try std.testing.expect(state.readyForRender());

    state.dead = true;
    try std.testing.expect(!state.readyForRender());
    state.dead = false;

    state.torn_down = true;
    try std.testing.expect(!state.readyForRender());
    state.torn_down = false;

    output.removed = true;
    try std.testing.expect(!state.readyForRender());
    output.removed = false;

    state.configured = false;
    try std.testing.expect(!state.readyForRender());
    state.configured = true;

    state.extent = null;
    try std.testing.expect(!state.readyForRender());
    state.extent = try wayland.dimensions.Extent.init(1920, 1080);

    state.frame_callback = @as(*wayland.c.wl_callback, @ptrFromInt(0x2000));
    try std.testing.expect(!state.readyForRender());
    state.frame_callback = null;

    state.layer_surface.wl_surface = null;
    try std.testing.expect(!state.readyForRender());
}

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

test "program global upload state is app owned" {
    try std.testing.expect(@hasField(App, "gpu_upload_state"));
    try std.testing.expect(!@hasField(SurfaceState, "needs_static_uniforms"));
}

test "surface owns change-driven CPU stand-in state" {
    try std.testing.expect(@hasField(SurfaceState, "cpu_standin"));
    try std.testing.expect(!@hasField(SurfaceState, "shm_effect"));
}

test "render tick receives mutable shader and app upload state" {
    const info = @typeInfo(@TypeOf(SurfaceState.renderTick)).@"fn";
    try std.testing.expectEqual(@as(usize, 4), info.params.len);
    try std.testing.expect(
        info.params[1].type.? == ?*wayland.effect_shader.EffectShader,
    );
    try std.testing.expect(
        info.params[2].type.? ==
            *wayland.gpu_upload_state.GpuUploadState,
    );
}
