const std = @import("std");
const src = @import("wlchroma_src");
const color_fade = src.color_fade;
const Rgb = src.defaults.Rgb;
const ColorFade = color_fade.ColorFade;

const a = [3]Rgb{
    .{ .r = 0, .g = 0, .b = 0 },
    .{ .r = 10, .g = 20, .b = 30 },
    .{ .r = 255, .g = 255, .b = 255 },
};
const b = [3]Rgb{
    .{ .r = 255, .g = 255, .b = 255 },
    .{ .r = 210, .g = 220, .b = 230 },
    .{ .r = 0, .g = 0, .b = 0 },
};

// --- smoothstep ---

test "smoothstep endpoints and midpoint" {
    try std.testing.expectEqual(@as(f32, 0.0), color_fade.smoothstep(0.0));
    try std.testing.expectEqual(@as(f32, 1.0), color_fade.smoothstep(1.0));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), color_fade.smoothstep(0.5), 1e-6);
}

test "smoothstep clamps out-of-range input" {
    try std.testing.expectEqual(@as(f32, 0.0), color_fade.smoothstep(-1.0));
    try std.testing.expectEqual(@as(f32, 1.0), color_fade.smoothstep(2.0));
}

test "smoothstep is eased, not linear, off the midpoint" {
    // At t=0.25 a linear ramp is 0.25; smoothstep is below it (flat start).
    try std.testing.expect(color_fade.smoothstep(0.25) < 0.25);
    // At t=0.75 smoothstep is above the linear 0.75 (flat end).
    try std.testing.expect(color_fade.smoothstep(0.75) > 0.75);
}

test "smoothstep is monotonic non-decreasing" {
    var prev: f32 = color_fade.smoothstep(0.0);
    var i: usize = 1;
    while (i <= 100) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / 100.0;
        const v = color_fade.smoothstep(t);
        try std.testing.expect(v >= prev);
        prev = v;
    }
}

// --- lerpPalette ---

test "lerpPalette at t=0 returns start exactly" {
    try std.testing.expectEqual(a, color_fade.lerpPalette(a, b, 0.0));
}

test "lerpPalette at t=1 returns target exactly" {
    try std.testing.expectEqual(b, color_fade.lerpPalette(a, b, 1.0));
}

test "lerpPalette at t=0.5 blends each channel" {
    const mid = color_fade.lerpPalette(a, b, 0.5);
    // slot 0: 0 -> 255 at 0.5 = 127.5 -> round 128
    try std.testing.expectEqual(@as(u8, 128), mid[0].r);
    // slot 2: 255 -> 0 at 0.5 = 127.5 -> round 128
    try std.testing.expectEqual(@as(u8, 128), mid[2].r);
    // slot 1 g: 20 -> 220 at 0.5 = 120
    try std.testing.expectEqual(@as(u8, 120), mid[1].g);
}

// --- sample ---

test "sample before start returns start, not done" {
    const f = ColorFade{ .start = a, .target = b, .start_ns = 1000, .dur_ns = 600 };
    const s = color_fade.sample(f, 1000);
    try std.testing.expectEqual(a, s.colors);
    try std.testing.expectEqual(false, s.done);
}

test "sample at/after end returns target exactly, done" {
    const f = ColorFade{ .start = a, .target = b, .start_ns = 1000, .dur_ns = 600 };
    const s = color_fade.sample(f, 1000 + 600);
    try std.testing.expectEqual(b, s.colors);
    try std.testing.expectEqual(true, s.done);

    const s2 = color_fade.sample(f, 1000 + 10_000);
    try std.testing.expectEqual(b, s2.colors);
    try std.testing.expectEqual(true, s2.done);
}

test "sample at temporal midpoint is the eased blend, not done" {
    const f = ColorFade{ .start = a, .target = b, .start_ns = 1000, .dur_ns = 600 };
    const s = color_fade.sample(f, 1000 + 300);
    try std.testing.expectEqual(false, s.done);
    // t=0.5 → smoothstep 0.5 → same as lerpPalette at 0.5
    const expected = color_fade.lerpPalette(a, b, color_fade.smoothstep(0.5));
    try std.testing.expectEqual(expected, s.colors);
}
