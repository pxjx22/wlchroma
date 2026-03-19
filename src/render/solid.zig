const defaults = @import("../config/defaults.zig");

pub const Rgb = defaults.Rgb;

pub const SolidColorRenderer = struct {
    color: Rgb,

    pub fn init(color: Rgb) SolidColorRenderer {
        return .{ .color = color };
    }

    pub fn renderGrid(self: *const SolidColorRenderer, grid_w: usize, grid_h: usize, out: []Rgb) void {
        _ = grid_w;
        _ = grid_h;
        @memset(out, self.color);
    }
};
