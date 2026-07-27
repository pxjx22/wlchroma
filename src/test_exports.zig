//! Module root for out-of-tree unit tests under tests/. Rooting the module
//! at src/ keeps relative imports inside src (e.g. render/effect.zig →
//! ../config/config.zig) within the module root directory.

pub const effect = @import("render/effect.zig");
pub const config = @import("config/config.zig");
pub const defaults = @import("config/defaults.zig");
pub const color_fade = @import("render/color_fade.zig");
pub const colormix = @import("render/colormix.zig");
pub const framebuffer = @import("render/framebuffer.zig");
pub const dimensions = @import("wayland/dimensions.zig");
pub const gpu_epoch = @import("render/gpu_epoch.zig");
pub const gpu_upload_state = @import("render/gpu_upload_state.zig");
pub const gpu_fallback = @import("render/gpu_fallback.zig");
pub const animation_state = @import("render/animation_state.zig");
pub const timer_expirations = @import("render/timer_expirations.zig");
