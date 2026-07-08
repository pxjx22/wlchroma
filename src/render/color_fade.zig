//! Pure palette-transition math for the `set-colors` fade (spec 009). Kept free
//! of Wayland/GL state so it is unit-testable without a live display: `sample`
//! is the whole progression (start → eased blend → exact target), driven only by
//! two timestamps. `App` owns the `ColorFade` value and calls `sample` once per
//! rendered frame.

const std = @import("std");
const Rgb = @import("../config/defaults.zig").Rgb;

/// An in-flight palette transition. `dur_ns` is always > 0 for an active fade
/// (the daemon takes the instant path when the requested duration is 0).
pub const ColorFade = struct {
    start: [3]Rgb,
    target: [3]Rgb,
    start_ns: u64,
    dur_ns: u64,
};

/// Smoothstep easing (3t² − 2t³) over a clamped t ∈ [0, 1]. Flat slope at both
/// ends, so a fade eases in and out rather than moving at a constant rate.
pub fn smoothstep(t: f32) f32 {
    const c = std.math.clamp(t, 0.0, 1.0);
    return c * c * (3.0 - 2.0 * c);
}

/// Per-channel blend of two triples at already-eased position `t`. `t = 0`
/// returns `a` exactly and `t = 1` returns `b` exactly (round-trip safe).
pub fn lerpPalette(a: [3]Rgb, b: [3]Rgb, t: f32) [3]Rgb {
    var out: [3]Rgb = undefined;
    for (0..3) |i| {
        out[i] = .{
            .r = lerpChannel(a[i].r, b[i].r, t),
            .g = lerpChannel(a[i].g, b[i].g, t),
            .b = lerpChannel(a[i].b, b[i].b, t),
        };
    }
    return out;
}

fn lerpChannel(a: u8, b: u8, t: f32) u8 {
    const af: f32 = @floatFromInt(a);
    const bf: f32 = @floatFromInt(b);
    const v = std.math.clamp(@round(af + (bf - af) * t), 0.0, 255.0);
    return @intFromFloat(v);
}

/// The full transition at wall-clock `now_ns`:
/// - `now_ns <= start_ns`      → `{ start, done = false }`
/// - `elapsed >= dur_ns`       → `{ target, done = true }` (exact settle)
/// - otherwise                 → `{ eased blend, done = false }`
pub fn sample(f: ColorFade, now_ns: u64) struct { colors: [3]Rgb, done: bool } {
    if (now_ns <= f.start_ns) return .{ .colors = f.start, .done = false };
    const elapsed = now_ns - f.start_ns;
    if (elapsed >= f.dur_ns) return .{ .colors = f.target, .done = true };
    const t = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(f.dur_ns));
    return .{ .colors = lerpPalette(f.start, f.target, smoothstep(t)), .done = false };
}
