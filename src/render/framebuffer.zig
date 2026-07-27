const defaults = @import("../config/defaults.zig");
const dimensions = @import("../wayland/dimensions.zig");
const ShmLayout = dimensions.ShmLayout;
const cell_grid = @import("cell_grid.zig");
pub const Rgb = defaults.Rgb;

pub const ExpandError = dimensions.LayoutError || cell_grid.GridError || error{
    CellLengthMismatch,
    PixelLengthMismatch,
};

/// Expand a validated row-major cell grid (indexed [y * grid.width + x])
/// into pixel_buf as XRGB8888 (4 bytes/pixel, little-endian: [B, G, R, 0x00]).
///
/// Iterates over cells and fills their pixel rectangles directly, avoiding
/// per-pixel division and clamping.
pub fn expandCells(
    cells: []const Rgb,
    pixel_buf: []u8,
    layout: ShmLayout,
) ExpandError!void {
    try layout.validate();
    if (cells.len != layout.grid.len) return error.CellLengthMismatch;
    if (pixel_buf.len != layout.buffer_bytes) return error.PixelLengthMismatch;

    const pw: usize = layout.extent.width;
    const ph: usize = layout.extent.height;

    for (0..layout.grid.height) |cy| {
        const py_start = cy * defaults.CELL_H;
        // Last cell row extends to the pixel boundary (handles partial cells).
        const py_end = if (cy + 1 < layout.grid.height) (cy + 1) * defaults.CELL_H else ph;
        if (py_start >= ph) break;
        const py_limit = @min(py_end, ph);

        for (0..layout.grid.width) |cx| {
            const px_start = cx * defaults.CELL_W;
            const px_end = if (cx + 1 < layout.grid.width) (cx + 1) * defaults.CELL_W else pw;
            if (px_start >= pw) break;
            const px_limit = @min(px_end, pw);

            const color = cells[cy * layout.grid.width + cx];
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
