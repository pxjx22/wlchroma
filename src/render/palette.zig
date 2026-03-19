const defaults = @import("../config/defaults.zig");
pub const Rgb = defaults.Rgb;
pub const Cell = defaults.Cell;

pub fn blend(fg: Rgb, bg: Rgb, alpha: f32) Rgb {
    const inv = 1.0 - alpha;
    return .{
        .r = @intFromFloat(@min(255.0, @max(0.0, @round(@as(f32, @floatFromInt(bg.r)) * inv + @as(f32, @floatFromInt(fg.r)) * alpha)))),
        .g = @intFromFloat(@min(255.0, @max(0.0, @round(@as(f32, @floatFromInt(bg.g)) * inv + @as(f32, @floatFromInt(fg.g)) * alpha)))),
        .b = @intFromFloat(@min(255.0, @max(0.0, @round(@as(f32, @floatFromInt(bg.b)) * inv + @as(f32, @floatFromInt(fg.b)) * alpha)))),
    };
}

pub fn buildPalette(col1: Rgb, col2: Rgb, col3: Rgb) [12]Cell {
    return [12]Cell{
        .{ .alpha = 1.00, .fg = col1, .bg = col2 },
        .{ .alpha = 0.72, .fg = col1, .bg = col2 },
        .{ .alpha = 0.50, .fg = col1, .bg = col2 },
        .{ .alpha = 0.28, .fg = col1, .bg = col2 },
        .{ .alpha = 1.00, .fg = col2, .bg = col3 },
        .{ .alpha = 0.72, .fg = col2, .bg = col3 },
        .{ .alpha = 0.50, .fg = col2, .bg = col3 },
        .{ .alpha = 0.28, .fg = col2, .bg = col3 },
        .{ .alpha = 1.00, .fg = col3, .bg = col1 },
        .{ .alpha = 0.72, .fg = col3, .bg = col1 },
        .{ .alpha = 0.50, .fg = col3, .bg = col1 },
        .{ .alpha = 0.28, .fg = col3, .bg = col1 },
    };
}
