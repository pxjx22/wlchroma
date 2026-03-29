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

    /// Compile and link the appropriate shader program for the given Effect.
    pub fn init(effect: *const Effect) !EffectShader {
        return switch (effect.*) {
            .colormix => EffectShader{ .colormix = try ColormixShader.init() },
            .glass_drift => EffectShader{ .glass_drift = try GlassDriftShader.init() },
            .frond_haze => EffectShader{ .frond_haze = try FrondHazeShader.init() },
            .lumen_tunnel => EffectShader{ .lumen_tunnel = try LumenTunnelShader.init() },
            .velvet_mesh => EffectShader{ .velvet_mesh = try VelvetMeshShader.init() },
            .starfield_fog => EffectShader{ .starfield_fog = try StarfieldFogShader.init() },
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
        }
    }
};
