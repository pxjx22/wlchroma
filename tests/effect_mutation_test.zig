const std = @import("std");
const src = @import("wlchroma_src");
const Effect = src.effect.Effect;
const config_mod = src.config;
const EffectType = config_mod.EffectType;
const Rgb = src.defaults.Rgb;

fn configFor(effect_type: EffectType) config_mod.AppConfig {
    var cfg = config_mod.defaultConfig();
    cfg.effect_type = effect_type;
    return cfg;
}

test "setSpeed updates the speed multiplier on every effect arm" {
    inline for (@typeInfo(EffectType).@"enum".fields) |field| {
        const cfg = configFor(@enumFromInt(field.value));
        var eff = Effect.init(&cfg);
        try std.testing.expectEqual(@as(f32, 1.0), eff.speed());
        eff.setSpeed(2.5);
        try std.testing.expectEqual(@as(f32, 2.5), eff.speed());
        eff.setSpeed(0.25);
        try std.testing.expectEqual(@as(f32, 0.25), eff.speed());
    }
}

test "setSpeed preserves the effect type and frame counter" {
    inline for (@typeInfo(EffectType).@"enum".fields) |field| {
        const effect_type: EffectType = @enumFromInt(field.value);
        const cfg = configFor(effect_type);
        var eff = Effect.init(&cfg);
        const frames_before = eff.frameCount();
        eff.setSpeed(2.0);
        try std.testing.expectEqual(effect_type, @as(EffectType, eff));
        try std.testing.expectEqual(frames_before, eff.frameCount());
    }
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

test "Effect.init honors config speed" {
    inline for (@typeInfo(EffectType).@"enum".fields) |field| {
        var cfg = configFor(@enumFromInt(field.value));
        cfg.speed = 1.75;
        var eff = Effect.init(&cfg);
        try std.testing.expectEqual(@as(f32, 1.75), eff.speed());
    }
}

const fallback_colors = [3]Rgb{
    .{ .r = 0x0a, .g = 0x1b, .b = 0x2c },
    .{ .r = 0x3d, .g = 0x4e, .b = 0x5f },
    .{ .r = 0x60, .g = 0x71, .b = 0x82 },
};

test "fallback preserves an existing colormix" {
    var cfg = configFor(.colormix);
    cfg.frame_advance_ms = 47;
    cfg.speed = 1.75;
    var eff = Effect.init(&cfg);
    eff.maybeAdvance(100);
    eff.maybeAdvance(200);

    const frames_before = eff.frameCount();
    const pattern_before = eff.patternMods().?;

    try std.testing.expect(!eff.fallbackToColormix(fallback_colors));
    try std.testing.expectEqual(EffectType.colormix, @as(EffectType, eff));
    try std.testing.expectEqual(frames_before, eff.frameCount());
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

test "fallback conversion preserves frame advance and speed" {
    var cfg = configFor(.glass_drift);
    cfg.frame_advance_ms = 43;
    cfg.speed = 2.25;
    var eff = Effect.init(&cfg);

    try std.testing.expect(eff.fallbackToColormix(fallback_colors));
    try std.testing.expectEqual(@as(u32, 43), eff.frameAdvanceMs());
    try std.testing.expectEqual(@as(f32, 2.25), eff.speed());
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
