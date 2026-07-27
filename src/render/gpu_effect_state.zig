const std = @import("std");
const Rgb = @import("../config/defaults.zig").Rgb;

pub const GpuEffectState = struct {
    phase_offset: f32,
    palette: [3]Rgb,

    pub fn init(palette: [3]Rgb) GpuEffectState {
        // Monotonic clock is fine as a seed source; only per-run variety matters.
        const seed: u64 = @import("sys").monotonicNs();
        var prng = std.Random.DefaultPrng.init(seed);
        return .{
            .phase_offset = prng.random().float(f32) * std.math.pi * 2.0,
            .palette = palette,
        };
    }
};
