const config_mod = @import("../config/config.zig");
const EffectType = config_mod.EffectType;
const AppConfig = config_mod.AppConfig;
const ColormixRenderer = @import("colormix.zig").ColormixRenderer;
const GlassDriftRenderer = @import("glass_drift.zig").GlassDriftRenderer;
const AuroraBandsRenderer = @import("aurora_bands.zig").AuroraBandsRenderer;
const CloudChamberRenderer = @import("cloud_chamber.zig").CloudChamberRenderer;
const RibbonOrbitRenderer = @import("ribbon_orbit.zig").RibbonOrbitRenderer;
const PlasmaQuiltRenderer = @import("plasma_quilt.zig").PlasmaQuiltRenderer;
const LiquidMarbleRenderer = @import("liquid_marble.zig").LiquidMarbleRenderer;
const VelvetMeshRenderer = @import("velvet_mesh.zig").VelvetMeshRenderer;
const SoftInterferenceRenderer = @import("soft_interference.zig").SoftInterferenceRenderer;
const StarfieldFogRenderer = @import("starfield_fog.zig").StarfieldFogRenderer;
const TubeLightsRenderer = @import("tube_lights.zig").TubeLightsRenderer;
const Rgb = @import("../config/defaults.zig").Rgb;

/// Central effect abstraction. App owns one Effect value; SurfaceState holds
/// a pointer to it. The tagged union dispatches renderer operations to the
/// active effect without the render loop knowing which effect is selected.
pub const Effect = union(EffectType) {
    colormix: ColormixRenderer,
    glass_drift: GlassDriftRenderer,
    aurora_bands: AuroraBandsRenderer,
    cloud_chamber: CloudChamberRenderer,
    ribbon_orbit: RibbonOrbitRenderer,
    plasma_quilt: PlasmaQuiltRenderer,
    liquid_marble: LiquidMarbleRenderer,
    velvet_mesh: VelvetMeshRenderer,
    soft_interference: SoftInterferenceRenderer,
    starfield_fog: StarfieldFogRenderer,
    tube_lights: TubeLightsRenderer,

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
            .aurora_bands => Effect{ .aurora_bands = AuroraBandsRenderer.init(config.frame_advance_ms, config.speed, config.palette) },
            .cloud_chamber => Effect{ .cloud_chamber = CloudChamberRenderer.init(config.frame_advance_ms, config.speed, config.palette) },
            .ribbon_orbit => Effect{ .ribbon_orbit = RibbonOrbitRenderer.init(config.frame_advance_ms, config.speed, config.palette) },
            .plasma_quilt => Effect{ .plasma_quilt = PlasmaQuiltRenderer.init(config.frame_advance_ms, config.speed, config.palette) },
            .liquid_marble => Effect{ .liquid_marble = LiquidMarbleRenderer.init(config.frame_advance_ms, config.speed, config.palette) },
            .velvet_mesh => Effect{ .velvet_mesh = VelvetMeshRenderer.init(config.frame_advance_ms, config.speed, config.palette) },
            .soft_interference => Effect{ .soft_interference = SoftInterferenceRenderer.init(config.frame_advance_ms, config.speed, config.palette) },
            .starfield_fog => Effect{ .starfield_fog = StarfieldFogRenderer.init(config.frame_advance_ms, config.speed, config.palette) },
            .tube_lights => Effect{ .tube_lights = TubeLightsRenderer.init(config.frame_advance_ms, config.speed, config.palette) },
        };
    }

    /// Advance animation frame counter. Both effects share the same gate logic.
    pub fn maybeAdvance(self: *Effect, time_ms: u32) void {
        switch (self.*) {
            .colormix => |*r| r.maybeAdvance(time_ms),
            .glass_drift => |*r| r.maybeAdvance(time_ms),
            .aurora_bands => |*r| r.maybeAdvance(time_ms),
            .cloud_chamber => |*r| r.maybeAdvance(time_ms),
            .ribbon_orbit => |*r| r.maybeAdvance(time_ms),
            .plasma_quilt => |*r| r.maybeAdvance(time_ms),
            .liquid_marble => |*r| r.maybeAdvance(time_ms),
            .velvet_mesh => |*r| r.maybeAdvance(time_ms),
            .soft_interference => |*r| r.maybeAdvance(time_ms),
            .starfield_fog => |*r| r.maybeAdvance(time_ms),
            .tube_lights => |*r| r.maybeAdvance(time_ms),
        }
    }

    /// Current frame count, used by EffectShader.setUniforms to compute time.
    pub fn frameCount(self: *const Effect) u64 {
        return switch (self.*) {
            .colormix => |*r| r.frames,
            .glass_drift => |*r| r.frames,
            .aurora_bands => |*r| r.frames,
            .cloud_chamber => |*r| r.frames,
            .ribbon_orbit => |*r| r.frames,
            .plasma_quilt => |*r| r.frames,
            .liquid_marble => |*r| r.frames,
            .velvet_mesh => |*r| r.frames,
            .soft_interference => |*r| r.frames,
            .starfield_fog => |*r| r.frames,
            .tube_lights => |*r| r.frames,
        };
    }

    /// Speed multiplier from config. Applied to time in EffectShader.setUniforms.
    pub fn speed(self: *const Effect) f32 {
        return switch (self.*) {
            .colormix => |*r| r.speed,
            .glass_drift => |*r| r.speed,
            .aurora_bands => |*r| r.speed,
            .cloud_chamber => |*r| r.speed,
            .ribbon_orbit => |*r| r.speed,
            .plasma_quilt => |*r| r.speed,
            .liquid_marble => |*r| r.speed,
            .velvet_mesh => |*r| r.speed,
            .soft_interference => |*r| r.speed,
            .starfield_fog => |*r| r.speed,
            .tube_lights => |*r| r.speed,
        };
    }

    /// True for effects that have no CPU/SHM rendering path.
    /// App.init checks this to apply the colormix fallback when EGL is absent.
    pub fn isGpuOnly(self: *const Effect) bool {
        return switch (self.*) {
            .colormix => false,
            .glass_drift => true,
            .aurora_bands => true,
            .cloud_chamber => true,
            .ribbon_orbit => true,
            .plasma_quilt => true,
            .liquid_marble => true,
            .velvet_mesh => true,
            .soft_interference => true,
            .starfield_fog => true,
            .tube_lights => true,
        };
    }

    /// CPU render grid (SHM fallback path). Only implemented for colormix.
    /// Returns without doing anything for GPU-only effects.
    pub fn renderGrid(self: *const Effect, grid_w: usize, grid_h: usize, out: []Rgb) void {
        switch (self.*) {
            .colormix => |*r| r.renderGrid(grid_w, grid_h, out),
            .glass_drift => {}, // GPU-only: no CPU path
            .aurora_bands => {},
            .cloud_chamber => {},
            .ribbon_orbit => {},
            .plasma_quilt => {},
            .liquid_marble => {},
            .velvet_mesh => {},
            .soft_interference => {},
            .starfield_fog => {},
            .tube_lights => {},
        }
    }

    /// Colormix palette data for ColormixShader.bind. Null for non-colormix effects.
    pub fn paletteData(self: *const Effect) ?*const [36]f32 {
        return switch (self.*) {
            .colormix => |*r| &r.palette_data,
            .glass_drift => null,
            .aurora_bands => null,
            .cloud_chamber => null,
            .ribbon_orbit => null,
            .plasma_quilt => null,
            .liquid_marble => null,
            .velvet_mesh => null,
            .soft_interference => null,
            .starfield_fog => null,
            .tube_lights => null,
        };
    }

    /// Colormix pattern modifiers for setStaticUniforms. Null for non-colormix.
    pub fn patternMods(self: *const Effect) ?struct { cos_mod: f32, sin_mod: f32 } {
        return switch (self.*) {
            .colormix => |*r| .{ .cos_mod = r.pattern_cos_mod, .sin_mod = r.pattern_sin_mod },
            .glass_drift => null,
            .aurora_bands => null,
            .cloud_chamber => null,
            .ribbon_orbit => null,
            .plasma_quilt => null,
            .liquid_marble => null,
            .velvet_mesh => null,
            .soft_interference => null,
            .starfield_fog => null,
            .tube_lights => null,
        };
    }

    /// GPU effect random phase offset for bind/setStaticUniforms. Null for CPU-only effects.
    pub fn gpuPhase(self: *const Effect) ?f32 {
        return switch (self.*) {
            .colormix => null,
            .glass_drift => |*r| r.phase_offset,
            .aurora_bands => |*r| r.phase_offset,
            .cloud_chamber => |*r| r.phase_offset,
            .ribbon_orbit => |*r| r.phase_offset,
            .plasma_quilt => |*r| r.phase_offset,
            .liquid_marble => |*r| r.phase_offset,
            .velvet_mesh => |*r| r.phase_offset,
            .soft_interference => |*r| r.phase_offset,
            .starfield_fog => |*r| r.phase_offset,
            .tube_lights => |*r| r.phase_offset,
        };
    }

    /// GPU effect palette for bind/setStaticUniforms. Null for CPU-only effects.
    pub fn gpuPalette(self: *const Effect) ?[3]Rgb {
        return switch (self.*) {
            .colormix => null,
            .glass_drift => |*r| r.palette,
            .aurora_bands => |*r| r.palette,
            .cloud_chamber => |*r| r.palette,
            .ribbon_orbit => |*r| r.palette,
            .plasma_quilt => |*r| r.palette,
            .liquid_marble => |*r| r.palette,
            .velvet_mesh => |*r| r.palette,
            .soft_interference => |*r| r.palette,
            .starfield_fog => |*r| r.palette,
            .tube_lights => |*r| r.palette,
        };
    }
};
