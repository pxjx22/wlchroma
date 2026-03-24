const std = @import("std");
const config_mod = @import("../config/config.zig");
const EffectType = config_mod.EffectType;
const defaults = @import("../config/defaults.zig");
const c = @import("../wl.zig").c;
const Effect = @import("effect.zig").Effect;
const ColormixShader = @import("colormix_shader.zig").ColormixShader;
const GlassDriftShader = @import("glass_drift_shader.zig").GlassDriftShader;
const AuroraBandsShader = @import("aurora_bands_shader.zig").AuroraBandsShader;
const CloudChamberShader = @import("cloud_chamber_shader.zig").CloudChamberShader;
const RibbonOrbitShader = @import("ribbon_orbit_shader.zig").RibbonOrbitShader;
const PlasmaQuiltShader = @import("plasma_quilt_shader.zig").PlasmaQuiltShader;
const LiquidMarbleShader = @import("liquid_marble_shader.zig").LiquidMarbleShader;
const VelvetMeshShader = @import("velvet_mesh_shader.zig").VelvetMeshShader;
const SoftInterferenceShader = @import("soft_interference_shader.zig").SoftInterferenceShader;
const StarfieldFogShader = @import("starfield_fog_shader.zig").StarfieldFogShader;
const TubeLightsShader = @import("tube_lights_shader.zig").TubeLightsShader;

/// GPU pipeline abstraction. App owns one ?EffectShader (null when GPU
/// unavailable). SurfaceState receives a const pointer per renderTick call.
/// The tagged union dispatches all GL operations to the active shader without
/// the render loop knowing which effect is selected.
pub const EffectShader = union(EffectType) {
    colormix: ColormixShader,
    glass_drift: GlassDriftShader,
    aurora_bands: AuroraBandsShader,
    cloud_chamber: CloudChamberShader,
    ribbon_orbit: RibbonOrbitShader,
    plasma_quilt: PlasmaQuiltShader,
    liquid_marble: LiquidMarbleShader,
    velvet_mesh: VelvetMeshShader,
    soft_interference: SoftInterferenceShader,
    starfield_fog: StarfieldFogShader,
    tube_lights: TubeLightsShader,

    /// Compile and link the appropriate shader program for the given Effect.
    pub fn init(effect: *const Effect) !EffectShader {
        return switch (effect.*) {
            .colormix => EffectShader{ .colormix = try ColormixShader.init() },
            .glass_drift => EffectShader{ .glass_drift = try GlassDriftShader.init() },
            .aurora_bands => EffectShader{ .aurora_bands = try AuroraBandsShader.init() },
            .cloud_chamber => EffectShader{ .cloud_chamber = try CloudChamberShader.init() },
            .ribbon_orbit => EffectShader{ .ribbon_orbit = try RibbonOrbitShader.init() },
            .plasma_quilt => EffectShader{ .plasma_quilt = try PlasmaQuiltShader.init() },
            .liquid_marble => EffectShader{ .liquid_marble = try LiquidMarbleShader.init() },
            .velvet_mesh => EffectShader{ .velvet_mesh = try VelvetMeshShader.init() },
            .soft_interference => EffectShader{ .soft_interference = try SoftInterferenceShader.init() },
            .starfield_fog => EffectShader{ .starfield_fog = try StarfieldFogShader.init() },
            .tube_lights => EffectShader{ .tube_lights = try TubeLightsShader.init() },
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
            .aurora_bands => |*sh| {
                std.debug.assert(effect.gpuPhase() != null); // Effect and EffectShader variants must match
                sh.bind(effect.gpuPhase().?, effect.gpuPalette().?);
            },
            .cloud_chamber => |*sh| {
                std.debug.assert(effect.gpuPhase() != null); // Effect and EffectShader variants must match
                sh.bind(effect.gpuPhase().?, effect.gpuPalette().?);
            },
            .ribbon_orbit => |*sh| {
                std.debug.assert(effect.gpuPhase() != null); // Effect and EffectShader variants must match
                sh.bind(effect.gpuPhase().?, effect.gpuPalette().?);
            },
            .plasma_quilt => |*sh| {
                std.debug.assert(effect.gpuPhase() != null); // Effect and EffectShader variants must match
                sh.bind(effect.gpuPhase().?, effect.gpuPalette().?);
            },
            .liquid_marble => |*sh| {
                std.debug.assert(effect.gpuPhase() != null); // Effect and EffectShader variants must match
                sh.bind(effect.gpuPhase().?, effect.gpuPalette().?);
            },
            .velvet_mesh => |*sh| {
                std.debug.assert(effect.gpuPhase() != null); // Effect and EffectShader variants must match
                sh.bind(effect.gpuPhase().?, effect.gpuPalette().?);
            },
            .soft_interference => |*sh| {
                std.debug.assert(effect.gpuPhase() != null); // Effect and EffectShader variants must match
                sh.bind(effect.gpuPhase().?, effect.gpuPalette().?);
            },
            .starfield_fog => |*sh| {
                std.debug.assert(effect.gpuPhase() != null); // Effect and EffectShader variants must match
                sh.bind(effect.gpuPhase().?, effect.gpuPalette().?);
            },
            .tube_lights => |*sh| {
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
            .aurora_bands => |*sh| {
                std.debug.assert(effect.gpuPhase() != null); // Effect and EffectShader variants must match
                sh.setStaticUniforms(effect.gpuPhase().?, effect.gpuPalette().?);
            },
            .cloud_chamber => |*sh| {
                std.debug.assert(effect.gpuPhase() != null); // Effect and EffectShader variants must match
                sh.setStaticUniforms(effect.gpuPhase().?, effect.gpuPalette().?);
            },
            .ribbon_orbit => |*sh| {
                std.debug.assert(effect.gpuPhase() != null); // Effect and EffectShader variants must match
                sh.setStaticUniforms(effect.gpuPhase().?, effect.gpuPalette().?);
            },
            .plasma_quilt => |*sh| {
                std.debug.assert(effect.gpuPhase() != null); // Effect and EffectShader variants must match
                sh.setStaticUniforms(effect.gpuPhase().?, effect.gpuPalette().?);
            },
            .liquid_marble => |*sh| {
                std.debug.assert(effect.gpuPhase() != null); // Effect and EffectShader variants must match
                sh.setStaticUniforms(effect.gpuPhase().?, effect.gpuPalette().?);
            },
            .velvet_mesh => |*sh| {
                std.debug.assert(effect.gpuPhase() != null); // Effect and EffectShader variants must match
                sh.setStaticUniforms(effect.gpuPhase().?, effect.gpuPalette().?);
            },
            .soft_interference => |*sh| {
                std.debug.assert(effect.gpuPhase() != null); // Effect and EffectShader variants must match
                sh.setStaticUniforms(effect.gpuPhase().?, effect.gpuPalette().?);
            },
            .starfield_fog => |*sh| {
                std.debug.assert(effect.gpuPhase() != null); // Effect and EffectShader variants must match
                sh.setStaticUniforms(effect.gpuPhase().?, effect.gpuPalette().?);
            },
            .tube_lights => |*sh| {
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
            .aurora_bands => |*sh| sh.setUniforms(time, resolution_w, resolution_h),
            .cloud_chamber => |*sh| sh.setUniforms(time, resolution_w, resolution_h),
            .ribbon_orbit => |*sh| sh.setUniforms(time, resolution_w, resolution_h),
            .plasma_quilt => |*sh| sh.setUniforms(time, resolution_w, resolution_h),
            .liquid_marble => |*sh| sh.setUniforms(time, resolution_w, resolution_h),
            .velvet_mesh => |*sh| sh.setUniforms(time, resolution_w, resolution_h),
            .soft_interference => |*sh| sh.setUniforms(time, resolution_w, resolution_h),
            .starfield_fog => |*sh| sh.setUniforms(time, resolution_w, resolution_h),
            .tube_lights => |*sh| sh.setUniforms(time, resolution_w, resolution_h),
        }
    }

    /// Draw the fullscreen quad. Assumes bind() and setUniforms() were called.
    pub fn draw(self: *const EffectShader) void {
        switch (self.*) {
            .colormix => |*sh| sh.draw(),
            .glass_drift => |*sh| sh.draw(),
            .aurora_bands => |*sh| sh.draw(),
            .cloud_chamber => |*sh| sh.draw(),
            .ribbon_orbit => |*sh| sh.draw(),
            .plasma_quilt => |*sh| sh.draw(),
            .liquid_marble => |*sh| sh.draw(),
            .velvet_mesh => |*sh| sh.draw(),
            .soft_interference => |*sh| sh.draw(),
            .starfield_fog => |*sh| sh.draw(),
            .tube_lights => |*sh| sh.draw(),
        }
    }

    /// GL program handle — for BlitShader state restoration after blit pass.
    pub fn glProgram(self: *const EffectShader) c.GLuint {
        return switch (self.*) {
            .colormix => |*sh| sh.program,
            .glass_drift => |*sh| sh.program,
            .aurora_bands => |*sh| sh.inner.program,
            .cloud_chamber => |*sh| sh.inner.program,
            .ribbon_orbit => |*sh| sh.inner.program,
            .plasma_quilt => |*sh| sh.inner.program,
            .liquid_marble => |*sh| sh.inner.program,
            .velvet_mesh => |*sh| sh.inner.program,
            .soft_interference => |*sh| sh.inner.program,
            .starfield_fog => |*sh| sh.inner.program,
            .tube_lights => |*sh| sh.inner.program,
        };
    }

    /// GL VBO handle — for BlitShader state restoration after blit pass.
    pub fn glVbo(self: *const EffectShader) c.GLuint {
        return switch (self.*) {
            .colormix => |*sh| sh.vbo,
            .glass_drift => |*sh| sh.vbo,
            .aurora_bands => |*sh| sh.inner.vbo,
            .cloud_chamber => |*sh| sh.inner.vbo,
            .ribbon_orbit => |*sh| sh.inner.vbo,
            .plasma_quilt => |*sh| sh.inner.vbo,
            .liquid_marble => |*sh| sh.inner.vbo,
            .velvet_mesh => |*sh| sh.inner.vbo,
            .soft_interference => |*sh| sh.inner.vbo,
            .starfield_fog => |*sh| sh.inner.vbo,
            .tube_lights => |*sh| sh.inner.vbo,
        };
    }

    /// GL attribute location — for BlitShader state restoration after blit pass.
    pub fn glAPosLoc(self: *const EffectShader) c.GLuint {
        return switch (self.*) {
            .colormix => |*sh| sh.a_pos_loc,
            .glass_drift => |*sh| sh.a_pos_loc,
            .aurora_bands => |*sh| sh.inner.a_pos_loc,
            .cloud_chamber => |*sh| sh.inner.a_pos_loc,
            .ribbon_orbit => |*sh| sh.inner.a_pos_loc,
            .plasma_quilt => |*sh| sh.inner.a_pos_loc,
            .liquid_marble => |*sh| sh.inner.a_pos_loc,
            .velvet_mesh => |*sh| sh.inner.a_pos_loc,
            .soft_interference => |*sh| sh.inner.a_pos_loc,
            .starfield_fog => |*sh| sh.inner.a_pos_loc,
            .tube_lights => |*sh| sh.inner.a_pos_loc,
        };
    }

    pub fn deinit(self: *EffectShader) void {
        switch (self.*) {
            .colormix => |*sh| sh.deinit(),
            .glass_drift => |*sh| sh.deinit(),
            .aurora_bands => |*sh| sh.deinit(),
            .cloud_chamber => |*sh| sh.deinit(),
            .ribbon_orbit => |*sh| sh.deinit(),
            .plasma_quilt => |*sh| sh.deinit(),
            .liquid_marble => |*sh| sh.deinit(),
            .velvet_mesh => |*sh| sh.deinit(),
            .soft_interference => |*sh| sh.deinit(),
            .starfield_fog => |*sh| sh.deinit(),
            .tube_lights => |*sh| sh.deinit(),
        }
    }
};
