const std = @import("std");
const defaults = @import("../config/defaults.zig");

pub const GridError = error{
    GridSizeOverflow,
    InvalidGridLength,
    RowOutOfBounds,
};

pub const CellGridLayout = struct {
    width: usize,
    height: usize,
    len: usize,

    pub fn initForPixels(
        pixel_width: u32,
        pixel_height: u32,
    ) error{GridSizeOverflow}!CellGridLayout {
        const width = @max(
            @divFloor(@as(usize, pixel_width), defaults.CELL_W),
            1,
        );
        const height = @max(
            @divFloor(@as(usize, pixel_height), defaults.CELL_H),
            1,
        );
        const len = std.math.mul(usize, width, height) catch
            return error.GridSizeOverflow;
        return .{ .width = width, .height = height, .len = len };
    }

    pub fn validate(
        self: CellGridLayout,
    ) error{ GridSizeOverflow, InvalidGridLength }!void {
        if (self.width == 0 or self.height == 0) {
            return error.InvalidGridLength;
        }
        const expected = std.math.mul(usize, self.width, self.height) catch
            return error.GridSizeOverflow;
        if (expected != self.len) return error.InvalidGridLength;
    }

    pub fn rowOffset(self: CellGridLayout, y: usize) GridError!usize {
        try self.validate();
        if (y >= self.height) return error.RowOutOfBounds;
        return std.math.mul(usize, y, self.width) catch
            return error.GridSizeOverflow;
    }
};
