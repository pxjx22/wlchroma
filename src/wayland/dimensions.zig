const std = @import("std");
const defaults = @import("../config/defaults.zig");

pub const ExtentError = error{
    ZeroDimension,
    WidthExceedsCInt,
    HeightExceedsCInt,
    InvalidScale,
};

pub const LayoutError = error{
    StrideOverflow,
    StrideExceedsCInt,
    BufferBytesOverflow,
    TotalBytesOverflow,
    PoolSizeExceedsCInt,
    OffsetExceedsCInt,
    GridSizeOverflow,
};

pub const Extent = struct {
    width: u32,
    height: u32,
    c_width: i32,
    c_height: i32,

    pub fn init(width: u32, height: u32) ExtentError!Extent {
        if (width == 0 or height == 0) return error.ZeroDimension;
        const c_max: u32 = @intCast(std.math.maxInt(i32));
        if (width > c_max) return error.WidthExceedsCInt;
        if (height > c_max) return error.HeightExceedsCInt;
        return .{
            .width = width,
            .height = height,
            .c_width = @intCast(width),
            .c_height = @intCast(height),
        };
    }

    pub fn scaled(self: Extent, scale: f32) ExtentError!Extent {
        if (!std.math.isFinite(scale) or scale <= 0.0 or scale > 1.0) {
            return error.InvalidScale;
        }
        if (scale == 1.0) return self;
        const width_f = @as(f64, @floatFromInt(self.width)) * @as(f64, scale);
        const height_f = @as(f64, @floatFromInt(self.height)) * @as(f64, scale);
        const width: u32 = @intFromFloat(@max(1.0, width_f));
        const height: u32 = @intFromFloat(@max(1.0, height_f));
        return init(width, height);
    }
};

pub fn resolve(previous: ?Extent, event_width: u32, event_height: u32) ExtentError!?Extent {
    const c_max: u32 = @intCast(std.math.maxInt(i32));
    if (event_width > c_max) return error.WidthExceedsCInt;
    if (event_height > c_max) return error.HeightExceedsCInt;
    const width = if (event_width == 0)
        if (previous) |extent| extent.width else 0
    else
        event_width;
    const height = if (event_height == 0)
        if (previous) |extent| extent.height else 0
    else
        event_height;
    if (width == 0 or height == 0) return null;
    return try Extent.init(width, height);
}

pub const BufferRange = struct { start: usize, end: usize };

pub const ShmLayout = struct {
    extent: Extent,
    stride: i32,
    buffer_bytes: usize,
    total_bytes: usize,
    offsets: [2]i32,
    grid_w: usize,
    grid_h: usize,
    grid_len: usize,

    pub fn init(extent: Extent) LayoutError!ShmLayout {
        const stride = std.math.mul(usize, @as(usize, extent.width), 4) catch
            return error.StrideOverflow;
        if (stride > std.math.maxInt(i32)) return error.StrideExceedsCInt;
        const buffer_bytes = std.math.mul(usize, stride, @as(usize, extent.height)) catch
            return error.BufferBytesOverflow;
        const total_bytes = std.math.mul(usize, buffer_bytes, 2) catch
            return error.TotalBytesOverflow;
        if (total_bytes > std.math.maxInt(i32)) return error.PoolSizeExceedsCInt;
        if (buffer_bytes > std.math.maxInt(i32)) return error.OffsetExceedsCInt;
        const grid_w = @max(@divFloor(@as(usize, extent.width), defaults.CELL_W), 1);
        const grid_h = @max(@divFloor(@as(usize, extent.height), defaults.CELL_H), 1);
        const grid_len = std.math.mul(usize, grid_w, grid_h) catch
            return error.GridSizeOverflow;
        return .{
            .extent = extent,
            .stride = @intCast(stride),
            .buffer_bytes = buffer_bytes,
            .total_bytes = total_bytes,
            .offsets = .{ 0, @intCast(buffer_bytes) },
            .grid_w = grid_w,
            .grid_h = grid_h,
            .grid_len = grid_len,
        };
    }

    pub fn bufferRange(self: ShmLayout, index: u1) BufferRange {
        const start = @as(usize, index) * self.buffer_bytes;
        return .{ .start = start, .end = start + self.buffer_bytes };
    }
};
