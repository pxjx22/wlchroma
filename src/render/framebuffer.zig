const defaults = @import("../config/defaults.zig");
pub const Rgb = defaults.Rgb;

/// Expand cell_grid (grid_w * grid_h Rgb values, indexed [x * grid_h + y])
/// into pixel_buf as XRGB8888 (4 bytes/pixel, little-endian: [B, G, R, 0x00]).
pub fn expandCells(
    cells: []const Rgb,
    grid_w: usize,
    grid_h: usize,
    pixel_buf: []u8,
    w: u32,
    h: u32,
) void {
    for (0..h) |py| {
        const cell_y = @min(grid_h - 1, @divFloor(py, defaults.CELL_H));
        for (0..w) |px| {
            const cell_x = @min(grid_w - 1, @divFloor(px, defaults.CELL_W));
            const color = cells[cell_x * grid_h + cell_y];
            const base = (py * w + px) * 4;
            pixel_buf[base + 0] = color.b; // B
            pixel_buf[base + 1] = color.g; // G
            pixel_buf[base + 2] = color.r; // R
            pixel_buf[base + 3] = 0x00; // X (padding)
        }
    }
}
