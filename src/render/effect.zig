const config_mod = @import("../config/config.zig");
const EffectType = config_mod.EffectType;
const AppConfig = config_mod.AppConfig;
const ColormixRenderer = @import("colormix.zig").ColormixRenderer;
const GlassDriftRenderer = @import("glass_drift.zig").GlassDriftRenderer;
const FrondHazeRenderer = @import("frond_haze.zig").FrondHazeRenderer;
const LumenTunnelRenderer = @import("lumen_tunnel.zig").LumenTunnelRenderer;
const VelvetMeshRenderer = @import("velvet_mesh.zig").VelvetMeshRenderer;
const StarfieldFogRenderer = @import("starfield_fog.zig").StarfieldFogRenderer;
const Rgb = @import("../config/defaults.zig").Rgb;

/// Central effect abstraction. App owns one Effect value; SurfaceState holds
/// a pointer to it. The tagged union dispatches renderer operations to the
/// active effect without the render loop knowing which effect is selected.
pub const Effect = union(EffectType) {
    colormix: ColormixRenderer,
    glass_drift: GlassDriftRenderer,
    frond_haze: FrondHazeRenderer,
    lumen_tunnel: LumenTunnelRenderer,
    velvet_mesh: VelvetMeshRenderer,
    starfield_fog: StarfieldFogRenderer,

    /// Construct from config. The caller (App.init) is responsible for
    /// applying the GPU-only fallback before calling Effect.init.
    pub fn init(config: *const AppConfig) Effect {
        return switch (config.effect_type) {
            .colormix => Effect{ .colormix = ColormixRenderer.init(
                config.palette[0],
                config.palette[1],
                config.palette[2],
                config.frame_advance_ms,
                config.speed,
            ) },
            .glass_drift => Effect{ .glass_drift = GlassDriftRenderer.init(
                config.frame_advance_ms,
                config.speed,
                config.palette,
            ) },
            .frond_haze => Effect{ .frond_haze = FrondHazeRenderer.init(config.frame_advance_ms, config.speed, config.palette) },
            .lumen_tunnel => Effect{ .lumen_tunnel = LumenTunnelRenderer.init(config.frame_advance_ms, config.speed, config.palette) },
            .velvet_mesh => Effect{ .velvet_mesh = VelvetMeshRenderer.init(config.frame_advance_ms, config.speed, config.palette) },
            .starfield_fog => Effect{ .starfield_fog = StarfieldFogRenderer.init(config.frame_advance_ms, config.speed, config.palette) },
        };
    }

    /// Advance animation frame counter. Both effects share the same gate logic.
    pub fn maybeAdvance(self: *Effect, time_ms: u32) void {
        switch (self.*) {
            .colormix => |*r| r.maybeAdvance(time_ms),
            .glass_drift => |*r| r.maybeAdvance(time_ms),
            .frond_haze => |*r| r.maybeAdvance(time_ms),
            .lumen_tunnel => |*r| r.maybeAdvance(time_ms),
            .velvet_mesh => |*r| r.maybeAdvance(time_ms),
            .starfield_fog => |*r| r.maybeAdvance(time_ms),
        }
    }

    /// Current frame count, used by EffectShader.setUniforms to compute time.
    pub fn frameCount(self: *const Effect) u64 {
        return switch (self.*) {
            .colormix => |*r| r.frames,
            .glass_drift => |*r| r.frames,
            .frond_haze => |*r| r.frames,
            .lumen_tunnel => |*r| r.frames,
            .velvet_mesh => |*r| r.frames,
            .starfield_fog => |*r| r.frames,
        };
    }

    /// Speed multiplier from config. Applied to time in EffectShader.setUniforms.
    pub fn speed(self: *const Effect) f32 {
        return switch (self.*) {
            .colormix => |*r| r.speed,
            .glass_drift => |*r| r.speed,
            .frond_haze => |*r| r.speed,
            .lumen_tunnel => |*r| r.speed,
            .velvet_mesh => |*r| r.speed,
            .starfield_fog => |*r| r.speed,
        };
    }

    /// True for effects that have no CPU/SHM rendering path.
    /// App.init checks this to apply the colormix fallback when EGL is absent.
    pub fn isGpuOnly(self: *const Effect) bool {
        return switch (self.*) {
            .colormix => false,
            .glass_drift => true,
            .frond_haze => true,
            .lumen_tunnel => true,
            .velvet_mesh => true,
            .starfield_fog => true,
        };
    }

    /// CPU render grid (SHM fallback path). Only implemented for colormix.
    /// Returns without doing anything for GPU-only effects.
    pub fn renderGrid(self: *const Effect, grid_w: usize, grid_h: usize, out: []Rgb) void {
        switch (self.*) {
            .colormix => |*r| r.renderGrid(grid_w, grid_h, out),
            .glass_drift => {}, // GPU-only: no CPU path
            .frond_haze => {},
            .lumen_tunnel => {},
            .velvet_mesh => {},
            .starfield_fog => {},
        }
    }

    /// Colormix palette data for ColormixShader.bind. Null for non-colormix effects.
    pub fn paletteData(self: *const Effect) ?*const [36]f32 {
        return switch (self.*) {
            .colormix => |*r| &r.palette_data,
            .glass_drift => null,
            .frond_haze => null,
            .lumen_tunnel => null,
            .velvet_mesh => null,
            .starfield_fog => null,
        };
    }

    /// Colormix pattern modifiers for setStaticUniforms. Null for non-colormix.
    pub fn patternMods(self: *const Effect) ?struct { cos_mod: f32, sin_mod: f32 } {
        return switch (self.*) {
            .colormix => |*r| .{ .cos_mod = r.pattern_cos_mod, .sin_mod = r.pattern_sin_mod },
            .glass_drift => null,
            .frond_haze => null,
            .lumen_tunnel => null,
            .velvet_mesh => null,
            .starfield_fog => null,
        };
    }

    /// GPU effect random phase offset for bind/setStaticUniforms. Null for CPU-only effects.
    pub fn gpuPhase(self: *const Effect) ?f32 {
        return switch (self.*) {
            .colormix => null,
            .glass_drift => |*r| r.phase_offset,
            .frond_haze => |*r| r.phase_offset,
            .lumen_tunnel => |*r| r.phase_offset,
            .velvet_mesh => |*r| r.phase_offset,
            .starfield_fog => |*r| r.phase_offset,
        };
    }

    /// GPU effect palette for bind/setStaticUniforms. Null for CPU-only effects.
    pub fn gpuPalette(self: *const Effect) ?[3]Rgb {
        return switch (self.*) {
            .colormix => null,
            .glass_drift => |*r| r.palette,
            .frond_haze => |*r| r.palette,
            .lumen_tunnel => |*r| r.palette,
            .velvet_mesh => |*r| r.palette,
            .starfield_fog => |*r| r.palette,
        };
    }
};
