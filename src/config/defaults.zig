pub const CELL_W: usize = 10;
pub const CELL_H: usize = 16;

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const DEFAULT_COLOR: Rgb = .{ .r = 0x1e, .g = 0x1e, .b = 0x2e };
