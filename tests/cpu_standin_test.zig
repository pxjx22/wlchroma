const std = @import("std");
const src = @import("wlchroma_src");

const CpuStandin = src.cpu_standin.CpuStandin;
const Effect = src.effect.Effect;
const EffectType = src.config.EffectType;
const Rgb = src.defaults.Rgb;

const first_palette = [3]Rgb{
    .{ .r = 0x10, .g = 0x20, .b = 0x30 },
    .{ .r = 0x40, .g = 0x50, .b = 0x60 },
    .{ .r = 0x70, .g = 0x80, .b = 0x90 },
};

const second_palette = [3]Rgb{
    .{ .r = 0xa1, .g = 0xb2, .b = 0xc3 },
    .{ .r = 0xd4, .g = 0xe5, .b = 0xf6 },
    .{ .r = 0x17, .g = 0x28, .b = 0x39 },
};

fn effectFor(effect_type: EffectType, colors: [3]Rgb) Effect {
    var config = src.config.defaultConfig();
    config.effect_type = effect_type;
    config.palette = colors;
    return Effect.init(&config);
}

fn expectFirstPaletteColor(effect: *const Effect, color: Rgb) !void {
    try std.testing.expectEqual(EffectType.colormix, @as(EffectType, effect.*));
    const data = effect.paletteData().?;
    try std.testing.expectApproxEqAbs(
        @as(f32, @floatFromInt(color.r)) / 255.0,
        data[0],
        1e-6,
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, @floatFromInt(color.g)) / 255.0,
        data[1],
        1e-6,
    );
    try std.testing.expectApproxEqAbs(
        @as(f32, @floatFromInt(color.b)) / 255.0,
        data[2],
        1e-6,
    );
}

test "native colormix returns source and clears obsolete stand-in" {
    var standin = CpuStandin{};
    var gpu_source = effectFor(.glass_drift, first_palette);
    _ = standin.resolve(&gpu_source);

    var cpu_source = effectFor(.colormix, second_palette);
    const resolved = standin.resolve(&cpu_source);

    try std.testing.expect(resolved == &cpu_source);
    try std.testing.expect(standin.effect == null);
    try std.testing.expect(standin.source_palette == null);
}

test "first GPU-only resolve creates colormix from source palette" {
    var standin = CpuStandin{};
    var source = effectFor(.glass_drift, first_palette);

    const resolved = standin.resolve(&source);

    try std.testing.expect(resolved == &standin.effect.?);
    try std.testing.expectEqual(first_palette, standin.source_palette.?);
    try expectFirstPaletteColor(resolved, first_palette[0]);
}

test "stable GPU-only resolve reuses stand-in without rebuilding palette" {
    var standin = CpuStandin{};
    var source = effectFor(.glass_drift, first_palette);
    const first = standin.resolve(&source);
    const sentinel: f32 = -1_234.5;
    standin.effect.?.colormix.palette_data[0] = sentinel;

    const second = standin.resolve(&source);

    try std.testing.expect(first == second);
    try std.testing.expectEqual(sentinel, standin.effect.?.colormix.palette_data[0]);
}

test "source palette change rebuilds once and records new palette" {
    var standin = CpuStandin{};
    var source = effectFor(.glass_drift, first_palette);
    _ = standin.resolve(&source);
    standin.effect.?.colormix.palette_data[0] = -1_234.5;

    source.updatePalette(second_palette);
    const changed = standin.resolve(&source);

    try std.testing.expectEqual(second_palette, standin.source_palette.?);
    try expectFirstPaletteColor(changed, second_palette[0]);
}

test "invalidate removes cached effect and palette" {
    var standin = CpuStandin{};
    var source = effectFor(.glass_drift, first_palette);
    _ = standin.resolve(&source);

    standin.invalidate();

    try std.testing.expect(standin.effect == null);
    try std.testing.expect(standin.source_palette == null);
}

test "invalidation and GPU effect switch create a fresh stand-in" {
    var standin = CpuStandin{};
    var source = effectFor(.glass_drift, first_palette);
    _ = standin.resolve(&source);
    standin.effect.?.colormix.palette_data[0] = -1_234.5;

    standin.invalidate();
    source = effectFor(.frond_haze, second_palette);
    const fresh = standin.resolve(&source);

    try std.testing.expectEqual(second_palette, standin.source_palette.?);
    try expectFirstPaletteColor(fresh, second_palette[0]);
}
