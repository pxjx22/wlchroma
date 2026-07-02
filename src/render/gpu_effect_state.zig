const std = @import("std");
const Rgb = @import("../config/defaults.zig").Rgb;

pub const GpuEffectState = struct {
    frames: u64,
    last_advance_ms: u32,
    frame_advance_ms: u32,
    speed: f32,
    phase_offset: f32,
    palette: [3]Rgb,

    pub fn init(frame_advance_ms: u32, speed: f32, palette: [3]Rgb) GpuEffectState {
        // Monotonic clock is fine as a seed source; only per-run variety matters.
        const seed: u64 = @import("sys").monotonicNs();
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        return .{
            .frames = 0,
            .last_advance_ms = 0,
            .frame_advance_ms = frame_advance_ms,
            .speed = speed,
            .phase_offset = random.float(f32) * std.math.pi * 2.0,
            .palette = palette,
        };
    }

    pub fn maybeAdvance(self: *GpuEffectState, time_ms: u32) void {
        const delta = time_ms -% self.last_advance_ms;
        if (self.last_advance_ms == 0 or delta >= self.frame_advance_ms) {
            self.frames += 1;
            self.last_advance_ms = time_ms;
        }
    }
};
