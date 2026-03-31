const std = @import("std");
const config_mod = @import("../config/config.zig");
const EffectType = config_mod.EffectType;
const defaults = @import("../config/defaults.zig");
const c = @import("../wl.zig").c;
const Effect = @import("effect.zig").Effect;
const ColormixShader = @import("colormix_shader.zig").ColormixShader;
const GlassDriftShader = @import("glass_drift_shader.zig").GlassDriftShader;
const FrondHazeShader = @import("frond_haze_shader.zig").FrondHazeShader;
const LumenTunnelShader = @import("lumen_tunnel_shader.zig").LumenTunnelShader;
const VelvetMeshShader = @import("velvet_mesh_shader.zig").VelvetMeshShader;
const StarfieldFogShader = @import("starfield_fog_shader.zig").StarfieldFogShader;
const GyroEchoShader = @import("gyro_echo_shader.zig").GyroEchoShader;
const HexFloretShader = @import("hex_floret_shader.zig").HexFloretShader;
const DitherOrbShader = @import("dither_orb_shader.zig").DitherOrbShader;
const SignalMatrixShader = @import("signal_matrix_shader.zig").SignalMatrixShader;
const FractLatticeShader = @import("fract_lattice_shader.zig").FractLatticeShader;

/// GPU pipeline abstraction. App owns one ?EffectShader (null when GPU
/// unavailable). SurfaceState receives a const pointer per renderTick call.
/// The tagged union dispatches all GL operations to the active shader without
/// the render loop knowing which effect is selected.
pub const EffectShader = union(EffectType) {
    colormix: ColormixShader,
    glass_drift: GlassDriftShader,
    frond_haze: FrondHazeShader,
    lumen_tunnel: LumenTunnelShader,
    velvet_mesh: VelvetMeshShader,
    starfield_fog: StarfieldFogShader,
    gyro_echo: GyroEchoShader,
    hex_floret: HexFloretShader,
    dither_orb: DitherOrbShader,
    signal_matrix: SignalMatrixShader,
    fract_lattice: FractLatticeShader,

    /// Compile and link the appropriate shader program for the given Effect.
    pub fn init(effect: *const Effect) !EffectShader {
        return switch (effect.*) {
            .colormix => EffectShader{ .colormix = try ColormixShader.init() },
            .glass_drift => EffectShader{ .glass_drift = try GlassDriftShader.init() },
            .frond_haze => EffectShader{ .frond_haze = try FrondHazeShader.init() },
            .lumen_tunnel => EffectShader{ .lumen_tunnel = try LumenTunnelShader.init() },
            .velvet_mesh => EffectShader{ .velvet_mesh = try VelvetMeshShader.init() },
            .starfield_fog => EffectShader{ .starfield_fog = try StarfieldFogShader.init() },
            .gyro_echo => EffectShader{ .gyro_echo = try GyroEchoShader.init() },
            .hex_floret => EffectShader{ .hex_floret = try HexFloretShader.init() },
            .dither_orb => EffectShader{ .dither_orb = try DitherOrbShader.init() },
            .signal_matrix => EffectShader{ .signal_matrix = try SignalMatrixShader.init() },
            .fract_lattice => EffectShader{ .fract_lattice = try FractLatticeShader.init() },
        };
    }

    /// Bind invariant GL state (program, VBO, vertex layout, static data).
    /// Call once after EGL context is current. For colormix: uploads palette.
    /// For glass_drift: uploads phase offset + palette.
    pub fn bind(self: *EffectShader, effect: *const Effect) void {
        switch (self.*) {
            .colormix => |*sh| {
                std.debug.assert(effect.paletteData() != null); // Effect and EffectShader variants must match
                sh.bind(effect.paletteData().?);
            },
            .glass_drift => |*sh| {
                std.debug.assert(effect.gpuPhase() != null); // Effect and EffectShader variants must match
                sh.bind(effect.gpuPhase().?, effect.gpuPalette().?);
            },
            .frond_haze => |*sh| {
                std.debug.assert(effect.gpuPhase() != null); // Effect and EffectShader variants must match
                sh.bind(effect.gpuPhase().?, effect.gpuPalette().?);
            },
            .lumen_tunnel => |*sh| {
                std.debug.assert(effect.gpuPhase() != null); // Effect and EffectShader variants must match
                sh.bind(effect.gpuPhase().?, effect.gpuPalette().?);
            },
            .velvet_mesh => |*sh| {
                std.debug.assert(effect.gpuPhase() != null); // Effect and EffectShader variants must match
                sh.bind(effect.gpuPhase().?, effect.gpuPalette().?);
            },
            .starfield_fog => |*sh| {
                std.debug.assert(effect.gpuPhase() != null); // Effect and EffectShader variants must match
                sh.bind(effect.gpuPhase().?, effect.gpuPalette().?);
            },
            .gyro_echo => |*sh| {
                std.debug.assert(effect.gpuPhase() != null); // Effect and EffectShader variants must match
                sh.bind(effect.gpuPhase().?, effect.gpuPalette().?);
            },
            .hex_floret => |*sh| {
                std.debug.assert(effect.gpuPhase() != null); // Effect and EffectShader variants must match
                sh.bind(effect.gpuPhase().?, effect.gpuPalette().?);
            },
            .dither_orb => |*sh| {
                std.debug.assert(effect.gpuPhase() != null); // Effect and EffectShader variants must match
                sh.bind(effect.gpuPhase().?, effect.gpuPalette().?);
            },
            .signal_matrix => |*sh| {
                std.debug.assert(effect.gpuPhase() != null); // Effect and EffectShader variants must match
                sh.bind(effect.gpuPhase().?, effect.gpuPalette().?);
            },
            .fract_lattice => |*sh| {
                std.debug.assert(effect.gpuPhase() != null); // Effect and EffectShader variants must match
                sh.bind(effect.gpuPhase().?, effect.gpuPalette().?);
            },
        }
    }

    /// Upload static uniforms that change only on configure/resize.
    /// For colormix: cos_mod + sin_mod. For glass_drift: phase_offset + palette.
    /// Assumes the effect program is already current (bound via bind()).
    pub fn setStaticUniforms(self: *const EffectShader, effect: *const Effect) void {
        switch (self.*) {
            .colormix => |*sh| {
                std.debug.assert(effect.patternMods() != null); // Effect and EffectShader variants must match
                const mods = effect.patternMods().?;
                sh.setStaticUniforms(mods.cos_mod, mods.sin_mod);
            },
            .glass_drift => |*sh| {
                std.debug.assert(effect.gpuPhase() != null); // Effect and EffectShader variants must match
                sh.setStaticUniforms(effect.gpuPhase().?, effect.gpuPalette().?);
            },
            .frond_haze => |*sh| {
                std.debug.assert(effect.gpuPhase() != null); // Effect and EffectShader variants must match
                sh.setStaticUniforms(effect.gpuPhase().?, effect.gpuPalette().?);
            },
            .lumen_tunnel => |*sh| {
                std.debug.assert(effect.gpuPhase() != null); // Effect and EffectShader variants must match
                sh.setStaticUniforms(effect.gpuPhase().?, effect.gpuPalette().?);
            },
            .velvet_mesh => |*sh| {
                std.debug.assert(effect.gpuPhase() != null); // Effect and EffectShader variants must match
                sh.setStaticUniforms(effect.gpuPhase().?, effect.gpuPalette().?);
            },
            .starfield_fog => |*sh| {
                std.debug.assert(effect.gpuPhase() != null); // Effect and EffectShader variants must match
                sh.setStaticUniforms(effect.gpuPhase().?, effect.gpuPalette().?);
            },
            .gyro_echo => |*sh| {
                std.debug.assert(effect.gpuPhase() != null); // Effect and EffectShader variants must match
                sh.setStaticUniforms(effect.gpuPhase().?, effect.gpuPalette().?);
            },
            .hex_floret => |*sh| {
                std.debug.assert(effect.gpuPhase() != null); // Effect and EffectShader variants must match
                sh.setStaticUniforms(effect.gpuPhase().?, effect.gpuPalette().?);
            },
            .dither_orb => |*sh| {
                std.debug.assert(effect.gpuPhase() != null); // Effect and EffectShader variants must match
                sh.setStaticUniforms(effect.gpuPhase().?, effect.gpuPalette().?);
            },
            .signal_matrix => |*sh| {
                std.debug.assert(effect.gpuPhase() != null); // Effect and EffectShader variants must match
                sh.setStaticUniforms(effect.gpuPhase().?, effect.gpuPalette().?);
            },
            .fract_lattice => |*sh| {
                std.debug.assert(effect.gpuPhase() != null); // Effect and EffectShader variants must match
                sh.setStaticUniforms(effect.gpuPhase().?, effect.gpuPalette().?);
            },
        }
    }

    /// Upload per-frame uniforms: time (= frameCount * TIME_SCALE * speed)
    /// and resolution. Called every renderTick before draw().
    /// T032 verification: all 9 new GPU effects reach setUniforms via their
    /// StandardShader.inner wrapper. effect.speed() returns r.speed for all
    /// new effect arms in effect.zig. Speed control is correctly wired.
    /// T033 verification: config speed validation (0.25–2.5) is not effect-type-
    /// gated — it applies globally in the effect_settings section handler.
    pub fn setUniforms(self: *const EffectShader, effect: *const Effect, resolution_w: f32, resolution_h: f32) void {
        const time = @as(f32, @floatFromInt(effect.frameCount())) * defaults.TIME_SCALE * effect.speed();
        switch (self.*) {
            .colormix => |*sh| sh.setUniforms(time, resolution_w, resolution_h),
            .glass_drift => |*sh| sh.setUniforms(time, resolution_w, resolution_h),
            .frond_haze => |*sh| sh.setUniforms(time, resolution_w, resolution_h),
            .lumen_tunnel => |*sh| sh.setUniforms(time, resolution_w, resolution_h),
            .velvet_mesh => |*sh| sh.setUniforms(time, resolution_w, resolution_h),
            .starfield_fog => |*sh| sh.setUniforms(time, resolution_w, resolution_h),
            .gyro_echo => |*sh| sh.setUniforms(time, resolution_w, resolution_h),
            .hex_floret => |*sh| sh.setUniforms(time, resolution_w, resolution_h),
            .dither_orb => |*sh| sh.setUniforms(time, resolution_w, resolution_h),
            .signal_matrix => |*sh| sh.setUniforms(time, resolution_w, resolution_h),
            .fract_lattice => |*sh| sh.setUniforms(time, resolution_w, resolution_h),
        }
    }

    /// Draw the fullscreen quad. Assumes bind() and setUniforms() were called.
    pub fn draw(self: *const EffectShader) void {
        switch (self.*) {
            .colormix => |*sh| sh.draw(),
            .glass_drift => |*sh| sh.draw(),
            .frond_haze => |*sh| sh.draw(),
            .lumen_tunnel => |*sh| sh.draw(),
            .velvet_mesh => |*sh| sh.draw(),
            .starfield_fog => |*sh| sh.draw(),
            .gyro_echo => |*sh| sh.draw(),
            .hex_floret => |*sh| sh.draw(),
            .dither_orb => |*sh| sh.draw(),
            .signal_matrix => |*sh| sh.draw(),
            .fract_lattice => |*sh| sh.draw(),
        }
    }

    /// GL program handle — for BlitShader state restoration after blit pass.
    pub fn glProgram(self: *const EffectShader) c.GLuint {
        return switch (self.*) {
            .colormix => |*sh| sh.program,
            .glass_drift => |*sh| sh.program,
            .frond_haze => |*sh| sh.inner.program,
            .lumen_tunnel => |*sh| sh.inner.program,
            .velvet_mesh => |*sh| sh.inner.program,
            .starfield_fog => |*sh| sh.inner.program,
            .gyro_echo => |*sh| sh.inner.program,
            .hex_floret => |*sh| sh.inner.program,
            .dither_orb => |*sh| sh.inner.program,
            .signal_matrix => |*sh| sh.inner.program,
            .fract_lattice => |*sh| sh.inner.program,
        };
    }

    /// GL VBO handle — for BlitShader state restoration after blit pass.
    pub fn glVbo(self: *const EffectShader) c.GLuint {
        return switch (self.*) {
            .colormix => |*sh| sh.vbo,
            .glass_drift => |*sh| sh.vbo,
            .frond_haze => |*sh| sh.inner.vbo,
            .lumen_tunnel => |*sh| sh.inner.vbo,
            .velvet_mesh => |*sh| sh.inner.vbo,
            .starfield_fog => |*sh| sh.inner.vbo,
            .gyro_echo => |*sh| sh.inner.vbo,
            .hex_floret => |*sh| sh.inner.vbo,
            .dither_orb => |*sh| sh.inner.vbo,
            .signal_matrix => |*sh| sh.inner.vbo,
            .fract_lattice => |*sh| sh.inner.vbo,
        };
    }

    /// GL attribute location — for BlitShader state restoration after blit pass.
    pub fn glAPosLoc(self: *const EffectShader) c.GLuint {
        return switch (self.*) {
            .colormix => |*sh| sh.a_pos_loc,
            .glass_drift => |*sh| sh.a_pos_loc,
            .frond_haze => |*sh| sh.inner.a_pos_loc,
            .lumen_tunnel => |*sh| sh.inner.a_pos_loc,
            .velvet_mesh => |*sh| sh.inner.a_pos_loc,
            .starfield_fog => |*sh| sh.inner.a_pos_loc,
            .gyro_echo => |*sh| sh.inner.a_pos_loc,
            .hex_floret => |*sh| sh.inner.a_pos_loc,
            .dither_orb => |*sh| sh.inner.a_pos_loc,
            .signal_matrix => |*sh| sh.inner.a_pos_loc,
            .fract_lattice => |*sh| sh.inner.a_pos_loc,
        };
    }

    pub fn deinit(self: *EffectShader) void {
        switch (self.*) {
            .colormix => |*sh| sh.deinit(),
            .glass_drift => |*sh| sh.deinit(),
            .frond_haze => |*sh| sh.deinit(),
            .lumen_tunnel => |*sh| sh.deinit(),
            .velvet_mesh => |*sh| sh.deinit(),
            .starfield_fog => |*sh| sh.deinit(),
            .gyro_echo => |*sh| sh.deinit(),
            .hex_floret => |*sh| sh.deinit(),
            .dither_orb => |*sh| sh.deinit(),
            .signal_matrix => |*sh| sh.deinit(),
            .fract_lattice => |*sh| sh.deinit(),
        }
    }
};
