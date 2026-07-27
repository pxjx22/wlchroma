const std = @import("std");
const defaults = @import("../config/defaults.zig");
const palette_mod = @import("palette.zig");
const ColormixShader = @import("colormix_shader.zig").ColormixShader;
const cell_grid = @import("cell_grid.zig");
const CellGridLayout = cell_grid.CellGridLayout;

pub const Rgb = defaults.Rgb;
const Cell = defaults.Cell;
const PALETTE_LEN: usize = 12;

pub const RenderGridError = cell_grid.GridError || error{OutputLengthMismatch};

pub const ColormixRenderer = struct {
    pattern_cos_mod: f32,
    pattern_sin_mod: f32,
    palette: [12]Cell,
    /// Pre-blended palette colors for GPU shader: 12 vec3s as 36 floats.
    /// Computed once at init from the palette; shared across all outputs.
    palette_data: [36]f32,
    blended_palette: [12]Rgb,

    pub fn init(col1: Rgb, col2: Rgb, col3: Rgb) ColormixRenderer {
        var prng = std.Random.DefaultPrng.init(defaults.SEED);
        const random = prng.random();
        var renderer = ColormixRenderer{
            .pattern_cos_mod = random.float(f32) * std.math.pi * 2.0,
            .pattern_sin_mod = random.float(f32) * std.math.pi * 2.0,
            .palette = undefined,
            .palette_data = undefined,
            .blended_palette = undefined,
        };
        renderer.rebuildPalette(.{ col1, col2, col3 });
        return renderer;
    }

    pub fn rebuildPalette(self: *ColormixRenderer, colors: [3]Rgb) void {
        self.palette = palette_mod.buildPalette(colors[0], colors[1], colors[2]);
        self.palette_data = ColormixShader.buildPaletteData(&self.palette);
        for (self.palette, 0..) |cell, i| {
            self.blended_palette[i] = palette_mod.blend(cell.fg, cell.bg, cell.alpha);
        }
    }

    pub fn renderGrid(
        self: *const ColormixRenderer,
        time: f32,
        grid: CellGridLayout,
        out: []Rgb,
    ) RenderGridError!void {
        try grid.validate();
        const max_doubled_dimension: usize = @intCast(std.math.maxInt(i32) / 2);
        if (grid.width > max_doubled_dimension or
            grid.height > max_doubled_dimension)
        {
            return error.GridSizeOverflow;
        }
        if (out.len != grid.len) return error.OutputLengthMismatch;

        const wi: i32 = @intCast(grid.width);
        const hi: i32 = @intCast(grid.height);
        const height_f: f32 = @floatFromInt(hi);
        const reciprocal_height = 1.0 / height_f;
        const reciprocal_double_height = 1.0 / (height_f * 2.0);
        const scaled_time = time * 0.1;

        for (0..grid.height) |y| {
            const yi: i32 = @intCast(y);
            const vertical_numerator = yi * 2 - hi;
            const vertical_component = @as(f32, @floatFromInt(vertical_numerator)) * reciprocal_height;
            const row_base = try grid.rowOffset(y);

            for (0..grid.width) |x| {
                const xi: i32 = @intCast(x);
                const horizontal_numerator = xi * 2 - wi;
                var uvx = @as(f32, @floatFromInt(horizontal_numerator)) * reciprocal_double_height;
                var uvy = vertical_component;
                var uv2x = uvx + uvy;
                var uv2y = uvx + uvy;

                // NOTE: Inner loop iteration order (len -> uv2 update ->
                // uvx/uvy update -> warp) is intentional and must stay
                // matched with the GPU path in shader.zig frag_src.
                for (0..3) |_| {
                    const len = vecLength(uvx, uvy);
                    uv2x += uvx + len;
                    uv2y += uvy + len;
                    uvx += 0.5 * @cos(self.pattern_cos_mod + uv2y * 0.2 + scaled_time);
                    uvy += 0.5 * @sin(self.pattern_sin_mod + uv2x - scaled_time);
                    const warp = 1.0 * @cos(uvx + uvy) - @sin(uvx * 0.7 - uvy);
                    uvx -= warp;
                    uvy -= warp;
                }

                const len = vecLength(uvx, uvy);
                const palette_index = @mod(@as(usize, @intFromFloat(@floor(len * 5.0))), PALETTE_LEN);
                out[row_base + x] = self.blended_palette[palette_index];
            }
        }
    }
};

fn vecLength(x: f32, y: f32) f32 {
    return @sqrt(x * x + y * y);
}
