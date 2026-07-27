const std = @import("std");
const src = @import("wlchroma_src");
const CellGridLayout = src.cell_grid.CellGridLayout;
const ColormixRenderer = src.colormix.ColormixRenderer;
const Rgb = src.defaults.Rgb;

const sentinel = Rgb{ .r = 0xa1, .g = 0xb2, .b = 0xc3 };

fn renderer() ColormixRenderer {
    return ColormixRenderer.init(
        src.defaults.DEFAULT_COL1,
        src.defaults.DEFAULT_COL2,
        src.defaults.DEFAULT_COL3,
    );
}

test "grid preserves floor sizing and minimum one cell" {
    try std.testing.expectEqual(
        CellGridLayout{ .width = 192, .height = 67, .len = 12_864 },
        try CellGridLayout.initForPixels(1920, 1080),
    );
    try std.testing.expectEqual(
        CellGridLayout{ .width = 1, .height = 1, .len = 1 },
        try CellGridLayout.initForPixels(1, 1),
    );
}

test "fabricated grid metadata is rejected" {
    const bad = CellGridLayout{ .width = 2, .height = 3, .len = 5 };
    try std.testing.expectError(error.InvalidGridLength, bad.validate());
}

test "fabricated zero grid dimension is rejected" {
    const bad = CellGridLayout{ .width = 0, .height = 3, .len = 0 };
    try std.testing.expectError(error.InvalidGridLength, bad.validate());
}

test "fabricated grid product overflow is rejected" {
    const overflowing = CellGridLayout{
        .width = std.math.maxInt(usize),
        .height = 2,
        .len = 0,
    };
    try std.testing.expectError(error.GridSizeOverflow, overflowing.validate());
}

test "row offset validates metadata and row bounds" {
    const grid = CellGridLayout{ .width = 4, .height = 3, .len = 12 };
    try grid.validate();
    try std.testing.expectEqual(@as(usize, 8), try grid.rowOffset(2));
    try std.testing.expectError(error.RowOutOfBounds, grid.rowOffset(3));

    const bad = CellGridLayout{ .width = 4, .height = 3, .len = 11 };
    try std.testing.expectError(error.InvalidGridLength, bad.rowOffset(0));
}

test "colormix rejects short and oversized outputs before writing" {
    const grid = CellGridLayout{ .width = 2, .height = 2, .len = 4 };
    const colormix = renderer();

    var short = [_]Rgb{sentinel} ** 3;
    const short_before = short;
    try std.testing.expectError(
        error.OutputLengthMismatch,
        colormix.renderGrid(1.0, grid, &short),
    );
    try std.testing.expectEqualSlices(Rgb, &short_before, &short);

    var oversized = [_]Rgb{sentinel} ** 5;
    const oversized_before = oversized;
    try std.testing.expectError(
        error.OutputLengthMismatch,
        colormix.renderGrid(1.0, grid, &oversized),
    );
    try std.testing.expectEqualSlices(Rgb, &oversized_before, &oversized);
}

test "colormix rejects fabricated grid metadata before writing" {
    const bad_grid = CellGridLayout{ .width = 2, .height = 2, .len = 3 };
    const colormix = renderer();
    var output = [_]Rgb{sentinel} ** 3;
    const before = output;

    try std.testing.expectError(
        error.InvalidGridLength,
        colormix.renderGrid(1.0, bad_grid, &output),
    );
    try std.testing.expectEqualSlices(Rgb, &before, &output);
}

test "colormix rejects dimensions that overflow its integer formulas" {
    const unsafe_width: usize = @as(usize, std.math.maxInt(i32)) / 2 + 1;
    const grid = CellGridLayout{
        .width = unsafe_width,
        .height = 1,
        .len = unsafe_width,
    };
    const colormix = renderer();
    var output: [0]Rgb = .{};

    try std.testing.expectError(
        error.GridSizeOverflow,
        colormix.renderGrid(1.0, grid, &output),
    );
}
