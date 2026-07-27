const std = @import("std");
const src = @import("wlchroma_src");

const Rgb = src.defaults.Rgb;
const CellGridLayout = src.cell_grid.CellGridLayout;
const ColormixRenderer = src.colormix.ColormixRenderer;
const Effect = src.effect.Effect;

const colors = [3]Rgb{
    .{ .r = 0x1e, .g = 0x1e, .b = 0x2e },
    .{ .r = 0x89, .g = 0xb4, .b = 0xfa },
    .{ .r = 0xa6, .g = 0xe3, .b = 0xa1 },
};

fn makeRenderer() ColormixRenderer {
    return ColormixRenderer.init(colors[0], colors[1], colors[2]);
}

fn blendReference(fg: Rgb, bg: Rgb, alpha: f32) Rgb {
    const inv = 1.0 - alpha;
    return .{
        .r = @intFromFloat(@min(255.0, @max(0.0, @round(
            @as(f32, @floatFromInt(bg.r)) * inv +
                @as(f32, @floatFromInt(fg.r)) * alpha,
        )))),
        .g = @intFromFloat(@min(255.0, @max(0.0, @round(
            @as(f32, @floatFromInt(bg.g)) * inv +
                @as(f32, @floatFromInt(fg.g)) * alpha,
        )))),
        .b = @intFromFloat(@min(255.0, @max(0.0, @round(
            @as(f32, @floatFromInt(bg.b)) * inv +
                @as(f32, @floatFromInt(fg.b)) * alpha,
        )))),
    };
}

fn vecLength(x: f32, y: f32) f32 {
    return @sqrt(x * x + y * y);
}

fn renderReference(
    renderer: *const ColormixRenderer,
    time: f32,
    grid: CellGridLayout,
    out: []Rgb,
) !void {
    for (0..grid.width) |x| {
        for (0..grid.height) |y| {
            const xi: i32 = @intCast(x);
            const yi: i32 = @intCast(y);
            const wi: i32 = @intCast(grid.width);
            const hi: i32 = @intCast(grid.height);

            var uvx = @as(f32, @floatFromInt(xi * 2 - wi)) /
                @as(f32, @floatFromInt(hi * 2));
            var uvy = @as(f32, @floatFromInt(yi * 2 - hi)) /
                @as(f32, @floatFromInt(hi));
            var uv2x = uvx + uvy;
            var uv2y = uvx + uvy;
            for (0..3) |_| {
                const len = vecLength(uvx, uvy);
                uv2x += uvx + len;
                uv2y += uvy + len;
                uvx += 0.5 * @cos(
                    renderer.pattern_cos_mod + uv2y * 0.2 + time * 0.1,
                );
                uvy += 0.5 * @sin(
                    renderer.pattern_sin_mod + uv2x - time * 0.1,
                );
                const warp = 1.0 * @cos(uvx + uvy) -
                    @sin(uvx * 0.7 - uvy);
                uvx -= warp;
                uvy -= warp;
            }

            const len = vecLength(uvx, uvy);
            const palette_index = @mod(
                @as(usize, @intFromFloat(@floor(len * 5.0))),
                renderer.palette.len,
            );
            const cell = renderer.palette[palette_index];
            const row_base = try grid.rowOffset(y);
            out[row_base + x] = blendReference(cell.fg, cell.bg, cell.alpha);
        }
    }
}

test "colormix stores reference colors in row-major order" {
    const renderer = makeRenderer();
    const grids = [_]CellGridLayout{
        .{ .width = 3, .height = 2, .len = 6 },
        .{ .width = 2, .height = 5, .len = 10 },
        .{ .width = 7, .height = 3, .len = 21 },
    };
    const times = [_]f32{ 0.0, 2.11, 16_383.75 };

    for (grids) |grid| {
        const actual = try std.testing.allocator.alloc(Rgb, grid.len);
        defer std.testing.allocator.free(actual);
        const expected = try std.testing.allocator.alloc(Rgb, grid.len);
        defer std.testing.allocator.free(expected);

        for (times) |time| {
            try renderer.renderGrid(time, grid, actual);
            try renderReference(&renderer, time, grid, expected);
            try std.testing.expectEqualSlices(Rgb, expected, actual);
        }
    }
}

test "colormix initializes every cached blend from its source cell" {
    const renderer = makeRenderer();

    for (renderer.palette, renderer.blended_palette) |cell, cached| {
        try std.testing.expectEqual(
            blendReference(cell.fg, cell.bg, cell.alpha),
            cached,
        );
    }
}

test "Effect palette mutation rebuilds all cached colormix entries" {
    const replacement = [3]Rgb{
        .{ .r = 0x24, .g = 0x19, .b = 0x2f },
        .{ .r = 0xf3, .g = 0x8b, .b = 0xa8 },
        .{ .r = 0x94, .g = 0xe2, .b = 0xd5 },
    };
    const sentinel = Rgb{ .r = 1, .g = 2, .b = 3 };
    var effect = Effect.initColormix(colors);
    @memset(effect.colormix.blended_palette[0..], sentinel);

    effect.updatePalette(replacement);

    for (effect.colormix.palette, effect.colormix.blended_palette) |cell, cached| {
        const expected = blendReference(cell.fg, cell.bg, cell.alpha);
        try std.testing.expectEqual(expected, cached);
        try std.testing.expect(!std.meta.eql(sentinel, cached));
    }
}

test "colormix rendering preserves palette source shader and cache data" {
    const renderer = makeRenderer();
    const source_before = renderer.palette;
    const shader_before = renderer.palette_data;
    const cache_before = renderer.blended_palette;
    const grid = CellGridLayout{ .width = 5, .height = 3, .len = 15 };
    var output: [15]Rgb = undefined;

    try renderer.renderGrid(7.25, grid, &output);

    try std.testing.expectEqual(source_before, renderer.palette);
    try std.testing.expectEqual(shader_before, renderer.palette_data);
    try std.testing.expectEqual(cache_before, renderer.blended_palette);
}

test "cached colormix output matches old per-cell blending" {
    const renderer = makeRenderer();
    const grid = CellGridLayout{ .width = 4, .height = 7, .len = 28 };
    var actual: [28]Rgb = undefined;
    var expected: [28]Rgb = undefined;

    try renderer.renderGrid(31.75, grid, &actual);
    try renderReference(&renderer, 31.75, grid, &expected);

    try std.testing.expectEqualSlices(Rgb, &expected, &actual);
}
