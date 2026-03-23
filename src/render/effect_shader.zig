const config_mod = @import("../config/config.zig");
const EffectType = config_mod.EffectType;
const defaults = @import("../config/defaults.zig");
const c = @import("../wl.zig").c;
const Effect = @import("effect.zig").Effect;
const ColormixShader = @import("colormix_shader.zig").ColormixShader;
const GlassDriftShader = @import("glass_drift_shader.zig").GlassDriftShader;

/// GPU pipeline abstraction. App owns one ?EffectShader (null when GPU
/// unavailable). SurfaceState receives a const pointer per renderTick call.
/// The tagged union dispatches all GL operations to the active shader without
/// the render loop knowing which effect is selected.
pub const EffectShader = union(EffectType) {
    colormix: ColormixShader,
    glass_drift: GlassDriftShader,

    /// Compile and link the appropriate shader program for the given Effect.
    pub fn init(effect: *const Effect) !EffectShader {
        return switch (effect.*) {
            .colormix => EffectShader{ .colormix = try ColormixShader.init() },
            .glass_drift => EffectShader{ .glass_drift = try GlassDriftShader.init() },
        };
    }

    /// Bind invariant GL state (program, VBO, vertex layout, static data).
    /// Call once after EGL context is current. For colormix: uploads palette.
    /// For glass_drift: uploads phase offset.
    pub fn bind(self: *EffectShader, effect: *const Effect) void {
        switch (self.*) {
            .colormix => |*sh| sh.bind(effect.paletteData().?),
            .glass_drift => |*sh| sh.bind(effect.phaseOffset().?),
        }
    }

    /// Upload static uniforms that change only on configure/resize.
    /// For colormix: cos_mod + sin_mod. For glass_drift: phase_offset.
    /// Assumes the effect program is already current (bound via bind()).
    pub fn setStaticUniforms(self: *const EffectShader, effect: *const Effect) void {
        switch (self.*) {
            .colormix => |*sh| {
                const mods = effect.patternMods().?;
                sh.setStaticUniforms(mods.cos_mod, mods.sin_mod);
            },
            .glass_drift => |*sh| sh.setStaticUniforms(effect.phaseOffset().?),
        }
    }

    /// Upload per-frame uniforms: time (= frameCount * TIME_SCALE * speed)
    /// and resolution. Called every renderTick before draw().
    pub fn setUniforms(self: *const EffectShader, effect: *const Effect, resolution_w: f32, resolution_h: f32) void {
        const time = @as(f32, @floatFromInt(effect.frameCount())) * defaults.TIME_SCALE * effect.speed();
        switch (self.*) {
            .colormix => |*sh| sh.setUniforms(time, resolution_w, resolution_h),
            .glass_drift => |*sh| sh.setUniforms(time, resolution_w, resolution_h),
        }
    }

    /// Draw the fullscreen quad. Assumes bind() and setUniforms() were called.
    pub fn draw(self: *const EffectShader) void {
        switch (self.*) {
            .colormix => |*sh| sh.draw(),
            .glass_drift => |*sh| sh.draw(),
        }
    }

    /// GL program handle — for BlitShader state restoration after blit pass.
    pub fn glProgram(self: *const EffectShader) c.GLuint {
        return switch (self.*) {
            .colormix => |*sh| sh.program,
            .glass_drift => |*sh| sh.program,
        };
    }

    /// GL VBO handle — for BlitShader state restoration after blit pass.
    pub fn glVbo(self: *const EffectShader) c.GLuint {
        return switch (self.*) {
            .colormix => |*sh| sh.vbo,
            .glass_drift => |*sh| sh.vbo,
        };
    }

    /// GL attribute location — for BlitShader state restoration after blit pass.
    pub fn glAPosLoc(self: *const EffectShader) c.GLuint {
        return switch (self.*) {
            .colormix => |*sh| sh.a_pos_loc,
            .glass_drift => |*sh| sh.a_pos_loc,
        };
    }

    pub fn deinit(self: *EffectShader) void {
        switch (self.*) {
            .colormix => |*sh| sh.deinit(),
            .glass_drift => |*sh| sh.deinit(),
        }
    }
};
