//! Module root for out-of-tree unit tests under tests/. Rooting the module
//! at src/ keeps relative imports inside src (e.g. render/effect.zig →
//! ../config/config.zig) within the module root directory.

pub const effect = @import("render/effect.zig");
pub const config = @import("config/config.zig");
pub const defaults = @import("config/defaults.zig");
