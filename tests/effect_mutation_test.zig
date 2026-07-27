const std = @import("std");
const src = @import("wlchroma_src");
const Effect = src.effect.Effect;
const config_mod = src.config;
const EffectType = config_mod.EffectType;
const Rgb = src.defaults.Rgb;
const AnimationState = src.animation_state.AnimationState;
const CellGridLayout = src.cell_grid.CellGridLayout;

fn configFor(effect_type: EffectType) config_mod.AppConfig {
    var cfg = config_mod.defaultConfig();
    cfg.effect_type = effect_type;
    return cfg;
}

test "same-effect speed update preserves App animation phase" {
    var animation = AnimationState.init(1.0);
    animation.advance(37);
    const phase_before = animation.phase;

    animation.setSpeed(2.5);

    try std.testing.expectEqual(phase_before, animation.phase);
    try std.testing.expectEqual(@as(f32, 2.5), animation.speed);
}

test "updatePalette applies new colors on every effect arm" {
    const new_palette = [3]Rgb{
        .{ .r = 0x11, .g = 0x22, .b = 0x33 },
        .{ .r = 0x44, .g = 0x55, .b = 0x66 },
        .{ .r = 0x77, .g = 0x88, .b = 0x99 },
    };
    inline for (@typeInfo(EffectType).@"enum".fields) |field| {
        const cfg = configFor(@enumFromInt(field.value));
        var eff = Effect.init(&cfg);
        eff.updatePalette(new_palette);
        if (eff.gpuPalette()) |colors| {
            try std.testing.expectEqual(new_palette[0], colors[0]);
            try std.testing.expectEqual(new_palette[1], colors[1]);
            try std.testing.expectEqual(new_palette[2], colors[2]);
        }
    }
}

test "every GPU-only effect reports no CPU renderer without writing" {
    const grid = CellGridLayout{ .width = 1, .height = 1, .len = 1 };
    const sentinel = Rgb{ .r = 0xaa, .g = 0xbb, .b = 0xcc };
    inline for (@typeInfo(EffectType).@"enum".fields) |field| {
        const effect_type: EffectType = @enumFromInt(field.value);
        if (effect_type != .colormix) {
            const cfg = configFor(effect_type);
            const eff = Effect.init(&cfg);
            var output = [_]Rgb{sentinel};

            try std.testing.expectError(
                error.NoCpuRenderer,
                eff.renderGrid(1.0, grid, &output),
            );
            try std.testing.expectEqual(sentinel, output[0]);
        }
    }
}

test "effect switch reset produces phase zero with the new speed" {
    var animation = AnimationState.init(1.0);
    animation.advance(37);
    var cfg = configFor(.glass_drift);
    cfg.speed = 1.75;

    const eff = Effect.init(&cfg);
    animation.reset(cfg.speed);

    try std.testing.expectEqual(EffectType.glass_drift, @as(EffectType, eff));
    try std.testing.expectEqual(@as(f64, 0.0), animation.phase);
    try std.testing.expectEqual(@as(f32, 1.75), animation.speed);
}

const fallback_colors = [3]Rgb{
    .{ .r = 0x0a, .g = 0x1b, .b = 0x2c },
    .{ .r = 0x3d, .g = 0x4e, .b = 0x5f },
    .{ .r = 0x60, .g = 0x71, .b = 0x82 },
};

test "fallback preserves an existing colormix" {
    const cfg = configFor(.colormix);
    var eff = Effect.init(&cfg);
    const pattern_before = eff.patternMods().?;

    try std.testing.expect(!eff.fallbackToColormix(fallback_colors));
    try std.testing.expectEqual(EffectType.colormix, @as(EffectType, eff));
    try std.testing.expectEqual(pattern_before, eff.patternMods().?);
}

test "fallback converts every GPU-only effect to colormix" {
    inline for (@typeInfo(EffectType).@"enum".fields) |field| {
        const effect_type: EffectType = @enumFromInt(field.value);
        if (effect_type != .colormix) {
            const cfg = configFor(effect_type);
            var eff = Effect.init(&cfg);

            try std.testing.expect(eff.fallbackToColormix(fallback_colors));
            try std.testing.expectEqual(EffectType.colormix, @as(EffectType, eff));
        }
    }
}

test "fallback conversion changes effect tag without changing App phase" {
    const cfg = configFor(.glass_drift);
    var eff = Effect.init(&cfg);
    var animation = AnimationState.init(2.25);
    animation.advance(43);
    const phase_before = animation.phase;

    try std.testing.expect(eff.fallbackToColormix(fallback_colors));
    try std.testing.expectEqual(EffectType.colormix, @as(EffectType, eff));
    try std.testing.expectEqual(phase_before, animation.phase);
}

test "fallback conversion rebuilds colormix palette data from supplied colors" {
    const gpu_cfg = configFor(.velvet_mesh);
    var eff = Effect.init(&gpu_cfg);

    var expected_cfg = configFor(.colormix);
    expected_cfg.palette = fallback_colors;
    const expected = Effect.init(&expected_cfg);

    try std.testing.expect(eff.fallbackToColormix(fallback_colors));
    try std.testing.expectEqualSlices(
        f32,
        expected.paletteData().?[0..],
        eff.paletteData().?[0..],
    );
}
