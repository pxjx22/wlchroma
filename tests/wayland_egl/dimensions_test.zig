const std = @import("std");
const src = @import("wlchroma_src");
const dimensions = src.dimensions;
const CellGridLayout = src.cell_grid.CellGridLayout;

test "resolve returns null until both axes are known" {
    try std.testing.expectEqual(@as(?dimensions.Extent, null), try dimensions.resolve(null, 0, 0));
    try std.testing.expectEqual(@as(?dimensions.Extent, null), try dimensions.resolve(null, 1920, 0));
}

test "resolve reuses only zero protocol axes" {
    const previous = try dimensions.Extent.init(1920, 1080);
    const height_change = (try dimensions.resolve(previous, 0, 720)).?;
    try std.testing.expectEqual(@as(u32, 1920), height_change.width);
    try std.testing.expectEqual(@as(u32, 720), height_change.height);
    const width_change = (try dimensions.resolve(previous, 1280, 0)).?;
    try std.testing.expectEqual(@as(u32, 1280), width_change.width);
    try std.testing.expectEqual(@as(u32, 1080), width_change.height);
}

test "extent accepts the C ABI maximum and rejects the next value" {
    const maximum = try dimensions.Extent.init(2_147_483_647, 1);
    try std.testing.expectEqual(@as(i32, 2_147_483_647), maximum.c_width);
    try std.testing.expectError(
        error.WidthExceedsCInt,
        dimensions.Extent.init(2_147_483_648, 1),
    );
    try std.testing.expectError(
        error.HeightExceedsCInt,
        dimensions.Extent.init(1, 2_147_483_648),
    );
}

test "invalid configure does not require overwriting the previous extent" {
    const previous = try dimensions.Extent.init(1920, 1080);
    try std.testing.expectError(
        error.WidthExceedsCInt,
        dimensions.resolve(previous, 2_147_483_648, 720),
    );
    try std.testing.expectEqual(@as(u32, 1920), previous.width);
    try std.testing.expectEqual(@as(u32, 1080), previous.height);
}

test "SHM layout computes two XRGB8888 buffers and the CPU grid" {
    const layout = try dimensions.ShmLayout.init(try dimensions.Extent.init(1920, 1080));
    try std.testing.expectEqual(@as(i32, 7680), layout.stride);
    try std.testing.expectEqual(@as(usize, 8_294_400), layout.buffer_bytes);
    try std.testing.expectEqual(@as(usize, 16_588_800), layout.total_bytes);
    try std.testing.expectEqual([2]i32{ 0, 8_294_400 }, layout.offsets);
    try std.testing.expectEqual(
        CellGridLayout{ .width = 192, .height = 67, .len = 12_864 },
        layout.grid,
    );
    try layout.validate();
}

test "SHM layout validation rejects every fabricated derived field" {
    const valid = try dimensions.ShmLayout.init(try dimensions.Extent.init(20, 32));

    var bad_c_width = valid;
    bad_c_width.extent.c_width += 1;
    try std.testing.expectError(error.InvalidShmLayout, bad_c_width.validate());

    var bad_c_height = valid;
    bad_c_height.extent.c_height += 1;
    try std.testing.expectError(error.InvalidShmLayout, bad_c_height.validate());

    var bad_stride = valid;
    bad_stride.stride += 4;
    try std.testing.expectError(error.InvalidShmLayout, bad_stride.validate());

    var bad_buffer_bytes = valid;
    bad_buffer_bytes.buffer_bytes += 4;
    try std.testing.expectError(error.InvalidShmLayout, bad_buffer_bytes.validate());

    var bad_total_bytes = valid;
    bad_total_bytes.total_bytes += 4;
    try std.testing.expectError(error.InvalidShmLayout, bad_total_bytes.validate());

    var bad_first_offset = valid;
    bad_first_offset.offsets[0] = 4;
    try std.testing.expectError(error.InvalidShmLayout, bad_first_offset.validate());

    var bad_second_offset = valid;
    bad_second_offset.offsets[1] += 4;
    try std.testing.expectError(error.InvalidShmLayout, bad_second_offset.validate());

    var bad_grid = valid;
    bad_grid.grid.len -= 1;
    try std.testing.expectError(error.InvalidShmLayout, bad_grid.validate());
}

test "SHM layout accepts the exact pool boundary" {
    const layout = try dimensions.ShmLayout.init(try dimensions.Extent.init(1, 268_435_455));
    try std.testing.expectEqual(@as(usize, 1_073_741_820), layout.buffer_bytes);
    try std.testing.expectEqual(@as(usize, 2_147_483_640), layout.total_bytes);
    try std.testing.expectEqual(
        dimensions.BufferRange{ .start = 1_073_741_820, .end = 2_147_483_640 },
        layout.bufferRange(1),
    );
}

test "SHM layout rejects ABI overflow before narrowing" {
    try std.testing.expectError(
        error.PoolSizeExceedsCInt,
        dimensions.ShmLayout.init(try dimensions.Extent.init(1, 268_435_456)),
    );
    try std.testing.expectError(
        error.StrideExceedsCInt,
        dimensions.ShmLayout.init(try dimensions.Extent.init(536_870_912, 1)),
    );
}

test "scaled extent stays nonzero and within the signed ABI" {
    const native = try dimensions.Extent.init(1920, 1080);
    const scaled = try native.scaled(0.5);
    try std.testing.expectEqual(@as(u32, 960), scaled.width);
    try std.testing.expectEqual(@as(u32, 540), scaled.height);
    const tiny = try (try dimensions.Extent.init(1, 1)).scaled(0.1);
    try std.testing.expectEqual(@as(u32, 1), tiny.width);
    try std.testing.expectEqual(@as(u32, 1), tiny.height);
}

test "buffer ranges exactly partition the stored mapping" {
    const layout = try dimensions.ShmLayout.init(try dimensions.Extent.init(8, 4));
    try std.testing.expectEqual(dimensions.BufferRange{ .start = 0, .end = 128 }, layout.bufferRange(0));
    try std.testing.expectEqual(dimensions.BufferRange{ .start = 128, .end = 256 }, layout.bufferRange(1));
    try std.testing.expectEqual(layout.total_bytes, layout.bufferRange(1).end);
}

test "scaled C dimensions are produced once by the checked extent" {
    const scaled = try (try dimensions.Extent.init(3840, 2160)).scaled(0.5);
    try std.testing.expectEqual(@as(i32, 1920), scaled.c_width);
    try std.testing.expectEqual(@as(i32, 1080), scaled.c_height);
}
