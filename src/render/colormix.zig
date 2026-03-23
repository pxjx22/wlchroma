const std = @import("std");
const defaults = @import("../config/defaults.zig");
const palette_mod = @import("palette.zig");
const ColormixShader = @import("colormix_shader.zig").ColormixShader;

pub const Rgb = defaults.Rgb;
const Cell = defaults.Cell;
const PALETTE_LEN: usize = 12;

pub const ColormixRenderer = struct {
    frames: u64,
    pattern_cos_mod: f32,
    pattern_sin_mod: f32,
    palette: [12]Cell,
    last_advance_ms: u32,
    frame_advance_ms: u32,
    speed: f32,
    /// Pre-blended palette colors for GPU shader: 12 vec3s as 36 floats.
    /// Computed once at init from the palette; shared across all outputs.
    palette_data: [36]f32,

    pub fn init(col1: Rgb, col2: Rgb, col3: Rgb, frame_advance_ms: u32, speed: f32) ColormixRenderer {
        var prng = std.Random.DefaultPrng.init(defaults.SEED);
        const random = prng.random();
        const pal = palette_mod.buildPalette(col1, col2, col3);
        return .{
            .frames = 0,
            .pattern_cos_mod = random.float(f32) * std.math.pi * 2.0,
            .pattern_sin_mod = random.float(f32) * std.math.pi * 2.0,
            .palette = pal,
            .last_advance_ms = 0,
            .frame_advance_ms = frame_advance_ms,
            .speed = speed,
            .palette_data = ColormixShader.buildPaletteData(&pal),
        };
    }

    /// Advance the frame counter at most once per frame interval (~15fps).
    /// The gate threshold (FRAME_ADVANCE_MS = 60ms) is intentionally below
    /// the timer period (FRAME_INTERVAL_NS ~ 66.67ms) to absorb up to ~10%
    /// scheduler jitter without skipping frames, while still preventing
    /// double-advance within a single timer period.
    /// Multiple outputs calling this with the same (or close) timestamp
    /// will only increment frames once, keeping all outputs in sync.
    pub fn maybeAdvance(self: *ColormixRenderer, time_ms: u32) void {
        const delta = time_ms -% self.last_advance_ms;
        if (self.last_advance_ms == 0 or delta >= self.frame_advance_ms) {
            self.frames += 1;
            self.last_advance_ms = time_ms;
        }
    }

    pub fn renderGrid(self: *const ColormixRenderer, grid_w: usize, grid_h: usize, out: []Rgb) void {
        const time = @as(f32, @floatFromInt(self.frames)) * defaults.TIME_SCALE;

        for (0..grid_w) |x| {
            for (0..grid_h) |y| {
                const xi: i32 = @intCast(x);
                const yi: i32 = @intCast(y);
                const wi: i32 = @intCast(grid_w);
                const hi: i32 = @intCast(grid_h);

                var uvx = @as(f32, @floatFromInt(xi * 2 - wi)) / @as(f32, @floatFromInt(hi * 2));
                var uvy = @as(f32, @floatFromInt(yi * 2 - hi)) / @as(f32, @floatFromInt(hi));
                var uv2x = uvx + uvy;
                var uv2y = uvx + uvy;

                // NOTE: Inner loop iteration order (len -> uv2 update ->
                // uvx/uvy update -> warp) is intentional and must stay
                // matched with the GPU path in shader.zig frag_src.
                for (0..3) |_| {
                    const len = vecLength(uvx, uvy);
                    uv2x += uvx + len;
                    uv2y += uvy + len;
                    uvx += 0.5 * @cos(self.pattern_cos_mod + uv2y * 0.2 + time * 0.1);
                    uvy += 0.5 * @sin(self.pattern_sin_mod + uv2x - time * 0.1);
                    const warp = 1.0 * @cos(uvx + uvy) - @sin(uvx * 0.7 - uvy);
                    uvx -= warp;
                    uvy -= warp;
                }

                const len = vecLength(uvx, uvy);
                const palette_index = @mod(@as(usize, @intFromFloat(@floor(len * 5.0))), PALETTE_LEN);
                const cell = self.palette[palette_index];
                // Column-major layout: x is the outer index, y is the inner.
                // This matches the iteration order in framebuffer.expandCells.
                out[x * grid_h + y] = palette_mod.blend(cell.fg, cell.bg, cell.alpha);
            }
        }
    }
};

fn vecLength(x: f32, y: f32) f32 {
    return @sqrt(x * x + y * y);
}
