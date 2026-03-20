pub const CELL_W: usize = 10;
pub const CELL_H: usize = 16;
pub const TIME_SCALE: f32 = 0.01;
pub const SEED: u64 = 7;

/// Timerfd period in nanoseconds (~15fps). 1_000_000_000 / 15 rounded.
pub const FRAME_INTERVAL_NS: u32 = 66_666_667;
/// maybeAdvance gate in milliseconds. Slightly below the timer period
/// (66.67ms) to absorb up to ~10% scheduler jitter without skipping frames.
pub const FRAME_ADVANCE_MS: u32 = 60;

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
