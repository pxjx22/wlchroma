const defaults = @import("../config/defaults.zig");
pub const Rgb = defaults.Rgb;

/// Expand cell_grid (grid_w * grid_h Rgb values, indexed [x * grid_h + y])
/// into pixel_buf as XRGB8888 (4 bytes/pixel, little-endian: [B, G, R, 0x00]).
///
/// Iterates over cells and fills their pixel rectangles directly, avoiding
/// per-pixel division and clamping.
pub fn expandCells(
    cells: []const Rgb,
    grid_w: usize,
    grid_h: usize,
    pixel_buf: []u8,
    w: u32,
    h: u32,
) void {
    const pw: usize = w;
    const ph: usize = h;

    for (0..grid_h) |cy| {
        const py_start = cy * defaults.CELL_H;
        // Last cell row extends to the pixel boundary (handles partial cells).
        const py_end = if (cy + 1 < grid_h) (cy + 1) * defaults.CELL_H else ph;
        if (py_start >= ph) break;
        const py_limit = @min(py_end, ph);

        for (0..grid_w) |cx| {
            const px_start = cx * defaults.CELL_W;
            const px_end = if (cx + 1 < grid_w) (cx + 1) * defaults.CELL_W else pw;
            if (px_start >= pw) break;
            const px_limit = @min(px_end, pw);

            // Column-major: x is outer index, y is inner (matches colormix.zig renderGrid).
            const color = cells[cx * grid_h + cy];
            const pixel: [4]u8 = .{ color.b, color.g, color.r, 0x00 };

            for (py_start..py_limit) |py| {
                const row_offset = py * pw;
                for (px_start..px_limit) |px| {
                    const base = (row_offset + px) * 4;
                    pixel_buf[base..][0..4].* = pixel;
                }
            }
        }
    }
}
