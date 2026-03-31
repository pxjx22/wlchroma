const config_mod = @import("../config/config.zig");
const EffectType = config_mod.EffectType;
const AppConfig = config_mod.AppConfig;
const ColormixRenderer = @import("colormix.zig").ColormixRenderer;
const GlassDriftRenderer = @import("glass_drift.zig").GlassDriftRenderer;
const FrondHazeRenderer = @import("frond_haze.zig").FrondHazeRenderer;
const LumenTunnelRenderer = @import("lumen_tunnel.zig").LumenTunnelRenderer;
const VelvetMeshRenderer = @import("velvet_mesh.zig").VelvetMeshRenderer;
const StarfieldFogRenderer = @import("starfield_fog.zig").StarfieldFogRenderer;
const GyroEchoRenderer = @import("gyro_echo.zig").GyroEchoRenderer;
const HexFloretRenderer = @import("hex_floret.zig").HexFloretRenderer;
const DitherOrbRenderer = @import("dither_orb.zig").DitherOrbRenderer;
const SignalMatrixRenderer = @import("signal_matrix.zig").SignalMatrixRenderer;
const FractLatticeRenderer = @import("fract_lattice.zig").FractLatticeRenderer;
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
    gyro_echo: GyroEchoRenderer,
    hex_floret: HexFloretRenderer,
    dither_orb: DitherOrbRenderer,
    signal_matrix: SignalMatrixRenderer,
    fract_lattice: FractLatticeRenderer,

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
            .gyro_echo => Effect{ .gyro_echo = GyroEchoRenderer.init(config.frame_advance_ms, config.speed, config.palette) },
            .hex_floret => Effect{ .hex_floret = HexFloretRenderer.init(config.frame_advance_ms, config.speed, config.palette) },
            .dither_orb => Effect{ .dither_orb = DitherOrbRenderer.init(config.frame_advance_ms, config.speed, config.palette) },
            .signal_matrix => Effect{ .signal_matrix = SignalMatrixRenderer.init(config.frame_advance_ms, config.speed, config.palette) },
            .fract_lattice => Effect{ .fract_lattice = FractLatticeRenderer.init(config.frame_advance_ms, config.speed, config.palette) },
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
            .gyro_echo => |*r| r.maybeAdvance(time_ms),
            .hex_floret => |*r| r.maybeAdvance(time_ms),
            .dither_orb => |*r| r.maybeAdvance(time_ms),
            .signal_matrix => |*r| r.maybeAdvance(time_ms),
            .fract_lattice => |*r| r.maybeAdvance(time_ms),
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
            .gyro_echo => |*r| r.frames,
            .hex_floret => |*r| r.frames,
            .dither_orb => |*r| r.frames,
            .signal_matrix => |*r| r.frames,
            .fract_lattice => |*r| r.frames,
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
            .gyro_echo => |*r| r.speed,
            .hex_floret => |*r| r.speed,
            .dither_orb => |*r| r.speed,
            .signal_matrix => |*r| r.speed,
            .fract_lattice => |*r| r.speed,
        };
    }

    pub fn frameAdvanceMs(self: *const Effect) u32 {
        return switch (self.*) {
            .colormix => |*r| r.frame_advance_ms,
            .glass_drift => |*r| r.frame_advance_ms,
            .frond_haze => |*r| r.frame_advance_ms,
            .lumen_tunnel => |*r| r.frame_advance_ms,
            .velvet_mesh => |*r| r.frame_advance_ms,
            .starfield_fog => |*r| r.frame_advance_ms,
            .gyro_echo => |*r| r.frame_advance_ms,
            .hex_floret => |*r| r.frame_advance_ms,
            .dither_orb => |*r| r.frame_advance_ms,
            .signal_matrix => |*r| r.frame_advance_ms,
            .fract_lattice => |*r| r.frame_advance_ms,
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
            .gyro_echo => true,
            .hex_floret => true,
            .dither_orb => true,
            .signal_matrix => true,
            .fract_lattice => true,
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
            .gyro_echo => {},
            .hex_floret => {},
            .dither_orb => {},
            .signal_matrix => {},
            .fract_lattice => {},
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
            .gyro_echo => null,
            .hex_floret => null,
            .dither_orb => null,
            .signal_matrix => null,
            .fract_lattice => null,
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
            .gyro_echo => null,
            .hex_floret => null,
            .dither_orb => null,
            .signal_matrix => null,
            .fract_lattice => null,
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
            .gyro_echo => |*r| r.phase_offset,
            .hex_floret => |*r| r.phase_offset,
            .dither_orb => |*r| r.phase_offset,
            .signal_matrix => |*r| r.phase_offset,
            .fract_lattice => |*r| r.phase_offset,
        };
    }

    /// Update the palette colors in-place without changing the effect type.
    /// For colormix: rebuilds the 12-cell palette and pre-computed GPU data.
    /// For GPU effects: updates the [3]Rgb palette field.
    /// Call effect_shader.bind(&effect) after this to re-upload to the GPU.
    pub fn updatePalette(self: *Effect, colors: [3]Rgb) void {
        const palette_mod = @import("palette.zig");
        const ColormixShader = @import("colormix_shader.zig").ColormixShader;
        switch (self.*) {
            .colormix => |*r| {
                r.palette = palette_mod.buildPalette(colors[0], colors[1], colors[2]);
                r.palette_data = ColormixShader.buildPaletteData(&r.palette);
            },
            .glass_drift => |*r| r.palette = colors,
            .frond_haze => |*r| r.palette = colors,
            .lumen_tunnel => |*r| r.palette = colors,
            .velvet_mesh => |*r| r.palette = colors,
            .starfield_fog => |*r| r.palette = colors,
            .gyro_echo => |*r| r.palette = colors,
            .hex_floret => |*r| r.palette = colors,
            .dither_orb => |*r| r.palette = colors,
            .signal_matrix => |*r| r.palette = colors,
            .fract_lattice => |*r| r.palette = colors,
        }
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
            .gyro_echo => |*r| r.palette,
            .hex_floret => |*r| r.palette,
            .dither_orb => |*r| r.palette,
            .signal_matrix => |*r| r.palette,
            .fract_lattice => |*r| r.palette,
        };
    }
};
