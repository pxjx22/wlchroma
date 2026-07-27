const std = @import("std");
const src = @import("wlchroma_src");

const Rgb = src.defaults.Rgb;
const ShmLayout = src.dimensions.ShmLayout;

const cell_sentinel = Rgb{ .r = 0x11, .g = 0x22, .b = 0x33 };
const pixel_sentinel: u8 = 0xa5;

fn layout2x2() !ShmLayout {
    return ShmLayout.init(try src.dimensions.Extent.init(20, 32));
}

fn expectPixel(
    pixels: []const u8,
    layout: ShmLayout,
    x: usize,
    y: usize,
    color: Rgb,
) !void {
    const base = (y * @as(usize, layout.extent.width) + x) * 4;
    try std.testing.expectEqualSlices(
        u8,
        &.{ color.b, color.g, color.r, 0x00 },
        pixels[base..][0..4],
    );
}

test "framebuffer expands row-major cells into matching quadrants" {
    const layout = try layout2x2();
    const red = Rgb{ .r = 0xff, .g = 0, .b = 0 };
    const green = Rgb{ .r = 0, .g = 0xff, .b = 0 };
    const blue = Rgb{ .r = 0, .g = 0, .b = 0xff };
    const white = Rgb{ .r = 0xff, .g = 0xff, .b = 0xff };
    const cells = [_]Rgb{
        red,  green,
        blue, white,
    };
    const pixels = try std.testing.allocator.alloc(u8, layout.buffer_bytes);
    defer std.testing.allocator.free(pixels);

    try src.framebuffer.expandCells(&cells, pixels, layout);

    try expectPixel(pixels, layout, 0, 0, red);
    try expectPixel(pixels, layout, 10, 0, green);
    try expectPixel(pixels, layout, 0, 16, blue);
    try expectPixel(pixels, layout, 10, 16, white);
}

test "framebuffer rejects short and oversized cell slices before writing" {
    const layout = try layout2x2();
    const pixels = try std.testing.allocator.alloc(u8, layout.buffer_bytes);
    defer std.testing.allocator.free(pixels);

    const short = [_]Rgb{cell_sentinel} ** 3;
    @memset(pixels, pixel_sentinel);
    try std.testing.expectError(
        error.CellLengthMismatch,
        src.framebuffer.expandCells(&short, pixels, layout),
    );
    for (pixels) |byte| try std.testing.expectEqual(pixel_sentinel, byte);

    const oversized = [_]Rgb{cell_sentinel} ** 5;
    @memset(pixels, pixel_sentinel);
    try std.testing.expectError(
        error.CellLengthMismatch,
        src.framebuffer.expandCells(&oversized, pixels, layout),
    );
    for (pixels) |byte| try std.testing.expectEqual(pixel_sentinel, byte);
}

test "framebuffer rejects short and oversized pixel slices before writing" {
    const layout = try layout2x2();
    const cells = [_]Rgb{cell_sentinel} ** 4;

    const short = try std.testing.allocator.alloc(u8, layout.buffer_bytes - 1);
    defer std.testing.allocator.free(short);
    @memset(short, pixel_sentinel);
    try std.testing.expectError(
        error.PixelLengthMismatch,
        src.framebuffer.expandCells(&cells, short, layout),
    );
    for (short) |byte| try std.testing.expectEqual(pixel_sentinel, byte);

    const oversized = try std.testing.allocator.alloc(u8, layout.buffer_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, pixel_sentinel);
    try std.testing.expectError(
        error.PixelLengthMismatch,
        src.framebuffer.expandCells(&cells, oversized, layout),
    );
    for (oversized) |byte| try std.testing.expectEqual(pixel_sentinel, byte);
}

test "framebuffer rejects fabricated SHM grid before writing" {
    var layout = try layout2x2();
    layout.grid.len -= 1;
    const cells = [_]Rgb{cell_sentinel} ** 4;
    const pixels = try std.testing.allocator.alloc(u8, layout.buffer_bytes);
    defer std.testing.allocator.free(pixels);
    @memset(pixels, pixel_sentinel);

    try std.testing.expectError(
        error.InvalidShmLayout,
        src.framebuffer.expandCells(&cells, pixels, layout),
    );
    for (pixels) |byte| try std.testing.expectEqual(pixel_sentinel, byte);
}
