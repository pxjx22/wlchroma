pub const CELL_W: usize = 10;
pub const CELL_H: usize = 16;
pub const TIME_SCALE: f32 = 0.01;
pub const SEED: u64 = 7;

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const Cell = struct {
    alpha: f32,
    fg: Rgb,
    bg: Rgb,
};

pub const DEFAULT_COLOR: Rgb = .{ .r = 0x1e, .g = 0x1e, .b = 0x2e };
pub const DEFAULT_COL1: Rgb = .{ .r = 0x1e, .g = 0x1e, .b = 0x2e };
pub const DEFAULT_COL2: Rgb = .{ .r = 0x89, .g = 0xb4, .b = 0xfa };
pub const DEFAULT_COL3: Rgb = .{ .r = 0xa6, .g = 0xe3, .b = 0xa1 };
