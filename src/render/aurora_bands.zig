const std = @import("std");
const Rgb = @import("../config/defaults.zig").Rgb;

pub const AuroraBandsRenderer = struct {
    frames: u64,
    last_advance_ms: u32,
    frame_advance_ms: u32,
    speed: f32,
    /// Random phase offset seeded at init via std.Random.DefaultPrng.
    /// Uploaded once as a static uniform to give each session a unique
    /// starting visual state.
    phase_offset: f32,
    /// Three-color palette from config. Uploaded as static uniforms.
    /// palette[0] = base, palette[1] = primary tint, palette[2] = secondary tint.
    palette: [3]Rgb,

    pub fn init(frame_advance_ms: u32, speed: f32, palette: [3]Rgb) AuroraBandsRenderer {
        const ts = std.time.milliTimestamp();
        const seed: u64 = @bitCast(ts);
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

    /// Advance the frame counter at most once per frame interval.
    /// Mirrors GlassDriftRenderer.maybeAdvance gate logic exactly.
    pub fn maybeAdvance(self: *AuroraBandsRenderer, time_ms: u32) void {
        const delta = time_ms -% self.last_advance_ms;
        if (self.last_advance_ms == 0 or delta >= self.frame_advance_ms) {
            self.frames += 1;
            self.last_advance_ms = time_ms;
        }
    }
};
