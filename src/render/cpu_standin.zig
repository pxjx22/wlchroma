const std = @import("std");
const Effect = @import("effect.zig").Effect;
const Rgb = @import("../config/defaults.zig").Rgb;

pub const CpuStandin = struct {
    effect: ?Effect = null,
    source_palette: ?[3]Rgb = null,

    pub fn invalidate(self: *CpuStandin) void {
        self.* = .{};
    }

    pub fn resolve(self: *CpuStandin, source: *Effect) *Effect {
        const colors = source.gpuPalette() orelse {
            self.invalidate();
            return source;
        };
        if (self.effect == null or self.source_palette == null) {
            self.effect = Effect.initColormix(colors);
            self.source_palette = colors;
        } else if (!std.meta.eql(self.source_palette.?, colors)) {
            self.effect.?.updatePalette(colors);
            self.source_palette = colors;
        }
        return &self.effect.?;
    }
};
