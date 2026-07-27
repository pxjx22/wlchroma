const std = @import("std");
const wayland = @import("wayland_test");
const gpu_fallback = wayland.gpu_fallback;
const Rgb = wayland.defaults.Rgb;
const App = wayland.app.App;
const Effect = wayland.effect.Effect;
const AppConfig = wayland.config.AppConfig;
const EffectType = wayland.config.EffectType;
const AppRgb = Rgb;

const Event = enum {
    close_epoch,
    replace_colormix,
    invalidate_standins,
    configure_cpu,
    mark_applied,
};

const FakeOps = struct {
    permanent_failure: bool = false,
    applied: bool = false,
    gpu_only: bool = false,
    authoritative_palette: [3]Rgb = .{
        .{ .r = 0x11, .g = 0x22, .b = 0x33 },
        .{ .r = 0x44, .g = 0x55, .b = 0x66 },
        .{ .r = 0x77, .g = 0x88, .b = 0x99 },
    },
    embedded_palette: [3]Rgb = .{
        .{ .r = 0xaa, .g = 0xbb, .b = 0xcc },
        .{ .r = 0xdd, .g = 0xee, .b = 0xff },
        .{ .r = 0x01, .g = 0x02, .b = 0x03 },
    },
    replacement_palette: ?[3]Rgb = null,
    events: [8]Event = undefined,
    len: usize = 0,
    close_count: usize = 0,
    replace_count: usize = 0,
    invalidate_count: usize = 0,
    configure_count: usize = 0,
    mark_count: usize = 0,

    fn push(self: *FakeOps, event: Event) void {
        self.events[self.len] = event;
        self.len += 1;
    }

    pub fn permanentFailure(self: *FakeOps) bool {
        return self.permanent_failure;
    }

    pub fn fallbackApplied(self: *FakeOps) bool {
        return self.applied;
    }

    pub fn closeGpuEpoch(self: *FakeOps) void {
        self.close_count += 1;
        self.push(.close_epoch);
    }

    pub fn effectIsGpuOnly(self: *FakeOps) bool {
        return self.gpu_only;
    }

    pub fn currentPalette(self: *FakeOps) [3]Rgb {
        return self.authoritative_palette;
    }

    pub fn replaceWithColormix(self: *FakeOps, colors: [3]Rgb) void {
        self.replace_count += 1;
        self.replacement_palette = colors;
        self.push(.replace_colormix);
    }

    pub fn invalidateCpuStandins(self: *FakeOps) void {
        self.invalidate_count += 1;
        self.push(.invalidate_standins);
    }

    pub fn configureCpuSurfaces(self: *FakeOps) void {
        self.configure_count += 1;
        self.push(.configure_cpu);
    }

    pub fn markFallbackApplied(self: *FakeOps) void {
        self.mark_count += 1;
        self.applied = true;
        self.push(.mark_applied);
    }
};

fn expectEvents(ops: *const FakeOps, expected: []const Event) !void {
    try std.testing.expectEqual(expected.len, ops.len);
    try std.testing.expectEqualSlices(Event, expected, ops.events[0..ops.len]);
}

const embedded_palette: [3]AppRgb = .{
    .{ .r = 0xaa, .g = 0xbb, .b = 0xcc },
    .{ .r = 0xdd, .g = 0xee, .b = 0xff },
    .{ .r = 0x01, .g = 0x02, .b = 0x03 },
};

const authoritative_palette: [3]AppRgb = .{
    .{ .r = 0x11, .g = 0x22, .b = 0x33 },
    .{ .r = 0x44, .g = 0x55, .b = 0x66 },
    .{ .r = 0x77, .g = 0x88, .b = 0x99 },
};

fn appConfig(effect_type: EffectType, palette: [3]AppRgb) AppConfig {
    return .{
        .fps = 15,
        .frame_interval_ns = 66_666_667,
        .effect_type = effect_type,
        .palette = palette,
        .speed = 1.25,
        .renderer_scale = 1.0,
        .upscale_filter = .nearest,
    };
}

fn appFixture(effect_type: EffectType, permanent_failure: bool) App {
    const cfg = appConfig(effect_type, embedded_palette);
    var app: App = undefined;
    app.surfaces = .empty;
    app.detached_gpu = .empty;
    app.configured_effect_type = cfg.effect_type;
    app.effect = Effect.init(&cfg);
    app.animation = wayland.animation_state.AnimationState.init(cfg.speed);
    app.egl_ctx = null;
    app.effect_shader = null;
    app.gpu_upload_state = .{};
    app.blit_shader = null;
    app.gpu_pipeline_failed = permanent_failure;
    app.gpu_fallback_applied = false;
    app.current_palette = authoritative_palette;
    return app;
}

test "recoverable failure performs no fallback work" {
    var ops = FakeOps{};

    try std.testing.expect(!gpu_fallback.apply(FakeOps, &ops));
    try expectEvents(&ops, &.{});
}

test "permanent colormix failure closes GPU before configuring CPU surfaces" {
    var ops = FakeOps{ .permanent_failure = true };

    try std.testing.expect(gpu_fallback.apply(FakeOps, &ops));
    try expectEvents(&ops, &.{
        .close_epoch,
        .invalidate_standins,
        .configure_cpu,
        .mark_applied,
    });
    try std.testing.expectEqual(@as(usize, 0), ops.replace_count);
}

test "permanent GPU-only failure converts from the authoritative palette" {
    var ops = FakeOps{
        .permanent_failure = true,
        .gpu_only = true,
    };

    try std.testing.expect(!std.meta.eql(ops.authoritative_palette, ops.embedded_palette));
    try std.testing.expect(gpu_fallback.apply(FakeOps, &ops));
    try expectEvents(&ops, &.{
        .close_epoch,
        .replace_colormix,
        .invalidate_standins,
        .configure_cpu,
        .mark_applied,
    });
    try std.testing.expectEqual(ops.authoritative_palette, ops.replacement_palette.?);
}

test "permanent fallback is idempotent" {
    var ops = FakeOps{
        .permanent_failure = true,
        .gpu_only = true,
    };

    try std.testing.expect(gpu_fallback.apply(FakeOps, &ops));
    try std.testing.expect(!gpu_fallback.apply(FakeOps, &ops));
    try std.testing.expectEqual(@as(usize, 1), ops.close_count);
    try std.testing.expectEqual(@as(usize, 1), ops.replace_count);
    try std.testing.expectEqual(@as(usize, 1), ops.invalidate_count);
    try std.testing.expectEqual(@as(usize, 1), ops.configure_count);
    try std.testing.expectEqual(@as(usize, 1), ops.mark_count);
}

test "App permanent colormix failure latches fallback and retains colormix" {
    var app = appFixture(.colormix, true);
    app.gpu_upload_state = wayland.gpu_upload_state.GpuUploadState.newGeneration();
    app.animation.advance(1);
    const before = app.effect;
    const phase_before = app.animation.phase;

    app.applyPermanentGpuFallback();

    try std.testing.expect(app.gpu_fallback_applied);
    try std.testing.expect(app.gpu_upload_state.isClean());
    try std.testing.expectEqual(EffectType.colormix, std.meta.activeTag(app.effect));
    try std.testing.expect(std.meta.eql(before, app.effect));
    try std.testing.expectEqual(phase_before, app.animation.phase);
}

test "App permanent GPU-only failure converts from current palette" {
    var app = appFixture(.glass_drift, true);
    try std.testing.expect(!std.meta.eql(embedded_palette, app.current_palette));

    app.applyPermanentGpuFallback();

    const expected_cfg = appConfig(.colormix, authoritative_palette);
    const expected = Effect.init(&expected_cfg);
    try std.testing.expect(app.gpu_fallback_applied);
    try std.testing.expectEqual(EffectType.colormix, std.meta.activeTag(app.effect));
    try std.testing.expectEqualSlices(
        f32,
        expected.paletteData().?,
        app.effect.paletteData().?,
    );
}

test "App second permanent fallback preserves advanced animation phase" {
    var app = appFixture(.glass_drift, true);
    app.applyPermanentGpuFallback();
    app.animation.advance(1);
    const advanced_phase = app.animation.phase;

    app.applyPermanentGpuFallback();

    try std.testing.expectApproxEqAbs(@as(f64, 0.0125), advanced_phase, 1e-12);
    try std.testing.expectEqual(advanced_phase, app.animation.phase);
}

test "App reload of same configured GPU effect preserves phase after permanent fallback" {
    var app = appFixture(.glass_drift, true);
    app.applyPermanentGpuFallback();
    app.animation.advance(17);
    const phase_before = app.animation.phase;
    var cfg = appConfig(.glass_drift, embedded_palette);
    cfg.speed = 2.0;

    App.TestAdapter.applyReloadEffectConfig(&app, &cfg);

    try std.testing.expectEqual(EffectType.glass_drift, app.configured_effect_type);
    try std.testing.expectEqual(EffectType.colormix, std.meta.activeTag(app.effect));
    try std.testing.expectEqual(phase_before, app.animation.phase);
    try std.testing.expectEqual(@as(f32, 2.0), app.animation.speed);
}

test "App reload to a different configured GPU effect resets phase" {
    var app = appFixture(.glass_drift, true);
    app.applyPermanentGpuFallback();
    app.animation.advance(17);
    var cfg = appConfig(.frond_haze, embedded_palette);
    cfg.speed = 2.0;

    App.TestAdapter.applyReloadEffectConfig(&app, &cfg);

    try std.testing.expectEqual(EffectType.frond_haze, app.configured_effect_type);
    try std.testing.expectEqual(@as(f64, 0.0), app.animation.phase);
    try std.testing.expectEqual(@as(f32, 2.0), app.animation.speed);
}

test "App reload from configured GPU effect to colormix resets phase" {
    var app = appFixture(.glass_drift, true);
    app.applyPermanentGpuFallback();
    app.animation.advance(17);
    var cfg = appConfig(.colormix, embedded_palette);
    cfg.speed = 2.0;

    App.TestAdapter.applyReloadEffectConfig(&app, &cfg);

    try std.testing.expectEqual(EffectType.colormix, app.configured_effect_type);
    try std.testing.expectEqual(EffectType.colormix, std.meta.activeTag(app.effect));
    try std.testing.expectEqual(@as(f64, 0.0), app.animation.phase);
    try std.testing.expectEqual(@as(f32, 2.0), app.animation.speed);
}

test "App recoverable state leaves fallback state and effect unchanged" {
    var app = appFixture(.glass_drift, false);
    app.gpu_upload_state = wayland.gpu_upload_state.GpuUploadState.newGeneration();
    const before = app.effect;
    const upload_before = app.gpu_upload_state;

    app.applyPermanentGpuFallback();

    try std.testing.expect(!app.gpu_pipeline_failed);
    try std.testing.expect(!app.gpu_fallback_applied);
    try std.testing.expect(std.meta.eql(before, app.effect));
    try std.testing.expectEqualDeep(upload_before, app.gpu_upload_state);
}
