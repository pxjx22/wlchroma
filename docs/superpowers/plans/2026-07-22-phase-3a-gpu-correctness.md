# Phase 3A GPU Correctness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Close audit findings GPU-M4, GPU-M5, and GPU-M6 with deferred current-context-safe GPU uploads and a functional, idempotent SHM fallback for every permanent effect-pipeline failure.

**Architecture:** App owns a one-byte dirty-state value for program-global GPU state. The first surface that successfully makes the shared EGL context current flushes only the dirty program, palette, and static state; permanent failures use a separate operations-driven transition that closes the Phase 2 GPU epoch, converts GPU-only effects to authoritative-palette colormix, and configures every surface for SHM.

**Tech Stack:** Zig 0.16.0, Wayland client APIs, EGL 1.5, OpenGL ES 2.0, Linux user-systemd/Niri live acceptance, and the existing Zig build graph. No new dependency.

## Global Constraints

- Implement only GPU-M4, GPU-M5, and GPU-M6. Animation/CPU performance remains Phase 3B; reload/config/build modernization remains Phase 3C.
- Never issue a Phase 3A GL state upload without a confirmed current EGL context.
- Preserve pending state until a surface successfully becomes current.
- Preserve Phase 2 EGL epoch ownership and recoverable zero-output behavior.
- A genuinely permanent pipeline failure remains CPU-only for the daemon lifetime.
- No config key, IPC command, response format, or public CLI behavior changes.
- Add no heap allocation, clock syscall, poll wake-up, or extra context switch to the clean render path.
- A clean surface performs one dirty-mask check and zero program-global uploads.
- Program-global state uploads once per change, not once per output.
- The optional blit shader remains a recoverable optimization; blit failure must not trigger permanent CPU fallback.
- Keep commits small and independently reviewable. Do not edit protocol-generated files.

## Source and Test Map

- Create src/render/gpu_upload_state.zig: pure packed dirty state and ordered flush.
- Create src/render/gpu_fallback.zig: pure idempotent permanent-fallback orchestration.
- Create src/render/shader_init_policy.zig: default-off build-time fault gate.
- Modify src/render/effect_shader.zig and all leaf shader wrappers: split program, geometry, palette, and static operations.
- Modify src/wayland/surface_state.zig: flush App-owned state only after makeCurrent succeeds.
- Modify src/app.zig: own dirty/fallback state, remove handler-time GL calls, and route every permanent failure through one transition.
- Modify build.zig and test export roots: focused test and build-option wiring.
- Create tests/wayland_egl/gpu_upload_state_test.zig, effect_shader_api_test.zig, gpu_fallback_test.zig, and shader_init_policy_test.zig.
- Update docs/security/2026-07-19-security-performance-audit.md only after implementation, review, automated verification, and live acceptance succeed.

---

### Task 1: Add the packed GPU upload state machine

**Files:**
- Create: src/render/gpu_upload_state.zig
- Create: tests/wayland_egl/gpu_upload_state_test.zig
- Modify: src/test_exports.zig
- Modify: build.zig

**Interfaces:**
- Consumes: no production GL type; a compile-time Ops adapter with useProgram, bindGeometry, uploadPalette, and uploadStatic.
- Produces: DirtyBits, GpuUploadState.newGeneration, clear, markPaletteDirty, isClean, and flushIfCurrent.

- [ ] **Step 1: Add the test module and failing state-machine tests**

Create tests/wayland_egl/gpu_upload_state_test.zig:

~~~zig
const std = @import("std");
const upload_mod = @import("wlchroma_src").gpu_upload_state;
const GpuUploadState = upload_mod.GpuUploadState;

const Event = enum {
    use_program,
    bind_geometry,
    upload_palette,
    upload_static,
};

const FakeOps = struct {
    events: [8]Event = undefined,
    len: usize = 0,

    fn push(self: *FakeOps, event: Event) void {
        self.events[self.len] = event;
        self.len += 1;
    }

    pub fn useProgram(self: *FakeOps) void {
        self.push(.use_program);
    }
    pub fn bindGeometry(self: *FakeOps) void {
        self.push(.bind_geometry);
    }
    pub fn uploadPalette(self: *FakeOps) void {
        self.push(.upload_palette);
    }
    pub fn uploadStatic(self: *FakeOps) void {
        self.push(.upload_static);
    }
};

fn expectEvents(ops: *const FakeOps, expected: []const Event) !void {
    try std.testing.expectEqual(expected.len, ops.len);
    try std.testing.expectEqualSlices(Event, expected, ops.events[0..ops.len]);
}

test "GPU upload state occupies one byte" {
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(GpuUploadState));
}

test "clean state performs no operation" {
    var state = GpuUploadState{};
    var ops = FakeOps{};
    state.flushIfCurrent(FakeOps, &ops, true);
    try std.testing.expect(state.isClean());
    try expectEvents(&ops, &.{});
}

test "palette mutation dirties only palette for a live shader" {
    var state = GpuUploadState{};
    state.markPaletteDirty(true);
    try std.testing.expect(!state.dirty.program_binding);
    try std.testing.expect(state.dirty.palette);
    try std.testing.expect(!state.dirty.static_uniforms);
}

test "palette mutation without a shader remains clean" {
    var state = GpuUploadState{};
    state.markPaletteDirty(false);
    try std.testing.expect(state.isClean());
}

test "new generation marks every program global field" {
    const state = GpuUploadState.newGeneration();
    try std.testing.expect(state.dirty.program_binding);
    try std.testing.expect(state.dirty.palette);
    try std.testing.expect(state.dirty.static_uniforms);
}

test "no current context preserves all dirty state" {
    var state = GpuUploadState.newGeneration();
    var ops = FakeOps{};
    state.flushIfCurrent(FakeOps, &ops, false);
    try std.testing.expect(!state.isClean());
    try expectEvents(&ops, &.{});
}

test "full flush is ordered and clears state" {
    var state = GpuUploadState.newGeneration();
    var ops = FakeOps{};
    state.flushIfCurrent(FakeOps, &ops, true);
    try expectEvents(&ops, &.{
        .use_program,
        .bind_geometry,
        .upload_palette,
        .upload_static,
    });
    try std.testing.expect(state.isClean());
}

test "palette only flush performs no geometry or static upload" {
    var state = GpuUploadState{};
    state.markPaletteDirty(true);
    var ops = FakeOps{};
    state.flushIfCurrent(FakeOps, &ops, true);
    try expectEvents(&ops, &.{ .use_program, .upload_palette });
    try std.testing.expect(state.isClean());
}

test "only first current surface consumes a palette mutation" {
    var state = GpuUploadState{};
    state.markPaletteDirty(true);
    var first = FakeOps{};
    var second = FakeOps{};
    state.flushIfCurrent(FakeOps, &first, true);
    state.flushIfCurrent(FakeOps, &second, true);
    try expectEvents(&first, &.{ .use_program, .upload_palette });
    try expectEvents(&second, &.{});
}
~~~

Export the missing module from src/test_exports.zig:

~~~zig
pub const gpu_upload_state = @import("render/gpu_upload_state.zig");
~~~

In build.zig, create a gpu_upload_state_test_mod rooted at the new test, import wlchroma_src from src_exports_mod, and attach its run artifact to both phase2_test_step (the existing test-wayland-egl step) and test_step.

- [ ] **Step 2: Run the RED test**

Run:

~~~sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3a-t1-red zig build test-wayland-egl --summary all
~~~

Expected: FAIL because src/render/gpu_upload_state.zig and GpuUploadState do not exist.

- [ ] **Step 3: Implement the one-byte state machine**

Create src/render/gpu_upload_state.zig:

~~~zig
pub const DirtyBits = packed struct(u8) {
    program_binding: bool = false,
    palette: bool = false,
    static_uniforms: bool = false,
    _padding: u5 = 0,
};

pub const GpuUploadState = packed struct(u8) {
    dirty: DirtyBits = .{},

    pub fn newGeneration() GpuUploadState {
        return .{ .dirty = .{
            .program_binding = true,
            .palette = true,
            .static_uniforms = true,
        } };
    }

    pub fn clear(self: *GpuUploadState) void {
        self.* = .{};
    }

    pub fn markPaletteDirty(self: *GpuUploadState, shader_live: bool) void {
        if (shader_live) self.dirty.palette = true;
    }

    pub fn isClean(self: *const GpuUploadState) bool {
        return !self.dirty.program_binding and
            !self.dirty.palette and
            !self.dirty.static_uniforms;
    }

    pub fn flushIfCurrent(
        self: *GpuUploadState,
        comptime Ops: type,
        ops: *Ops,
        confirmed_current: bool,
    ) void {
        if (!confirmed_current or self.isClean()) return;
        ops.useProgram();
        if (self.dirty.program_binding) {
            ops.bindGeometry();
            self.dirty.program_binding = false;
        }
        if (self.dirty.palette) {
            ops.uploadPalette();
            self.dirty.palette = false;
        }
        if (self.dirty.static_uniforms) {
            ops.uploadStatic();
            self.dirty.static_uniforms = false;
        }
    }
};
~~~

- [ ] **Step 4: Run focused and full GREEN tests**

Run:

~~~sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3a-t1-green zig build test-wayland-egl --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3a-t1-green zig build test --summary all
zig fmt --check build.zig src tests
git diff --check
~~~

Expected: all commands exit zero; the focused test total increases by the nine new tests.

- [ ] **Step 5: Commit Task 1**

~~~sh
git add build.zig src/render/gpu_upload_state.zig src/test_exports.zig tests/wayland_egl/gpu_upload_state_test.zig
git commit -m "feat(renderer): add GPU upload dirty state"
~~~

---

### Task 2: Split shader program, geometry, palette, and static operations

**Files:**
- Modify: src/render/colormix_shader.zig
- Modify: src/render/glass_drift_shader.zig
- Modify: src/render/standard_shader.zig
- Modify: src/render/dither_orb_shader.zig
- Modify: src/render/fract_lattice_shader.zig
- Modify: src/render/frond_haze_shader.zig
- Modify: src/render/gyro_echo_shader.zig
- Modify: src/render/hex_floret_shader.zig
- Modify: src/render/lumen_tunnel_shader.zig
- Modify: src/render/signal_matrix_shader.zig
- Modify: src/render/starfield_fog_shader.zig
- Modify: src/render/velvet_mesh_shader.zig
- Modify: src/render/effect_shader.zig
- Modify: src/app.zig
- Modify: src/wayland/surface_state.zig
- Modify: src/test_wayland_exports.zig
- Create: tests/wayland_egl/effect_shader_api_test.zig
- Modify: build.zig

**Interfaces:**
- Consumes: Effect paletteData, patternMods, gpuPalette, and gpuPhase accessors.
- Produces: EffectShader.useProgram, bindGeometry, uploadPalette, and uploadStatic. No old combined bind or setStaticUniforms method remains.

- [ ] **Step 1: Add the failing API-shape test**

Export these types from src/test_wayland_exports.zig:

~~~zig
pub const effect_shader = @import("render/effect_shader.zig");
pub const colormix_shader = @import("render/colormix_shader.zig");
pub const glass_drift_shader = @import("render/glass_drift_shader.zig");
pub const standard_shader = @import("render/standard_shader.zig");
~~~

Create tests/wayland_egl/effect_shader_api_test.zig:

~~~zig
const std = @import("std");
const wayland = @import("wayland_test");

fn expectSplitApi(comptime T: type) !void {
    try std.testing.expect(@hasDecl(T, "useProgram"));
    try std.testing.expect(@hasDecl(T, "bindGeometry"));
    try std.testing.expect(@hasDecl(T, "uploadPalette"));
    try std.testing.expect(@hasDecl(T, "uploadStatic"));
    try std.testing.expect(!@hasDecl(T, "bind"));
    try std.testing.expect(!@hasDecl(T, "setStaticUniforms"));
}

test "effect and leaf shaders expose only split state operations" {
    try expectSplitApi(wayland.effect_shader.EffectShader);
    try expectSplitApi(wayland.colormix_shader.ColormixShader);
    try expectSplitApi(wayland.glass_drift_shader.GlassDriftShader);
    try expectSplitApi(wayland.standard_shader.StandardShader);
}
~~~

Wire the test into test-wayland-egl and test using wayland_exports_mod.

- [ ] **Step 2: Run the RED API test**

Run:

~~~sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3a-t2-red zig build test-wayland-egl --summary all
~~~

Expected: FAIL because the new declarations are absent and the combined declarations remain.

- [ ] **Step 3: Split ColormixShader and GlassDriftShader**

Replace the combined methods with these exact responsibilities:

~~~zig
// ColormixShader
pub fn useProgram(self: *const ColormixShader) void {
    c.glUseProgram(self.program);
}
pub fn bindGeometry(self: *ColormixShader) void {
    c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
    c.glEnableVertexAttribArray(self.a_pos_loc);
    c.glVertexAttribPointer(
        self.a_pos_loc, 2, c.GL_FLOAT, c.GL_FALSE, 0,
        @as(?*const anyopaque, null),
    );
    self.bound = true;
}
pub fn uploadPalette(self: *const ColormixShader, data: *const [36]f32) void {
    c.glUniform3fv(
        self.u_palette_loc,
        12,
        @as([*c]const c.GLfloat, @ptrCast(data)),
    );
}
pub fn uploadStatic(
    self: *const ColormixShader,
    cos_mod: f32,
    sin_mod: f32,
) void {
    c.glUniform1f(self.u_cos_mod_loc, cos_mod);
    c.glUniform1f(self.u_sin_mod_loc, sin_mod);
}
~~~

~~~zig
// GlassDriftShader
pub fn useProgram(self: *const GlassDriftShader) void {
    c.glUseProgram(self.program);
}
pub fn bindGeometry(self: *GlassDriftShader) void {
    c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
    c.glEnableVertexAttribArray(self.a_pos_loc);
    c.glVertexAttribPointer(
        self.a_pos_loc, 2, c.GL_FLOAT, c.GL_FALSE, 0,
        @as(?*const anyopaque, null),
    );
    self.bound = true;
}
pub fn uploadPalette(self: *const GlassDriftShader, palette: [3]Rgb) void {
    inline for (palette, 0..) |rgb, i| {
        const loc = switch (i) {
            0 => self.u_col0_loc,
            1 => self.u_col1_loc,
            2 => self.u_col2_loc,
            else => unreachable,
        };
        c.glUniform3f(
            loc,
            @as(f32, @floatFromInt(rgb.r)) / 255.0,
            @as(f32, @floatFromInt(rgb.g)) / 255.0,
            @as(f32, @floatFromInt(rgb.b)) / 255.0,
        );
    }
}
pub fn uploadStatic(self: *const GlassDriftShader, phase: f32) void {
    c.glUniform1f(self.u_phase_loc, phase);
}
~~~

- [ ] **Step 4: Split StandardShader and every standard wrapper**

StandardShader gets:

~~~zig
pub fn useProgram(self: *const StandardShader) void {
    c.glUseProgram(self.program);
}

pub fn bindGeometry(self: *StandardShader) void {
    c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
    c.glEnableVertexAttribArray(self.a_pos_loc);
    c.glVertexAttribPointer(
        self.a_pos_loc, 2, c.GL_FLOAT, c.GL_FALSE, 0,
        @as(?*const anyopaque, null),
    );
    self.bound = true;
}

pub fn uploadPalette(self: *const StandardShader, palette: [3]Rgb) void {
    inline for (palette, 0..) |rgb, i| {
        const loc = switch (i) {
            0 => self.u_col0_loc,
            1 => self.u_col1_loc,
            2 => self.u_col2_loc,
            else => unreachable,
        };
        if (loc >= 0) {
            c.glUniform3f(
                loc,
                @as(f32, @floatFromInt(rgb.r)) / 255.0,
                @as(f32, @floatFromInt(rgb.g)) / 255.0,
                @as(f32, @floatFromInt(rgb.b)) / 255.0,
            );
        }
    }
}

pub fn uploadStatic(self: *const StandardShader, phase: f32) void {
    if (self.u_phase_loc >= 0) c.glUniform1f(self.u_phase_loc, phase);
}
~~~

The nine StandardShader wrappers do not duplicate these methods. Remove each
wrapper's combined bind and setStaticUniforms declarations. EffectShader already
accesses each public inner field for GL handles and will dispatch the four split
operations directly to inner. This keeps StandardShader as the single
implementation of standard-effect program state.

- [ ] **Step 5: Replace EffectShader dispatch**

Implement:

~~~zig
pub fn useProgram(self: *const EffectShader) void {
    switch (self.*) {
        .colormix => |*shader| shader.useProgram(),
        .glass_drift => |*shader| shader.useProgram(),
        inline else => |*shader| shader.inner.useProgram(),
    }
}

pub fn bindGeometry(self: *EffectShader) void {
    switch (self.*) {
        .colormix => |*shader| shader.bindGeometry(),
        .glass_drift => |*shader| shader.bindGeometry(),
        inline else => |*shader| shader.inner.bindGeometry(),
    }
}
~~~

For uploadPalette, dispatch colormix to paletteData and every other tag to
gpuPalette. For uploadStatic, dispatch colormix to patternMods and every other
tag to gpuPhase:

~~~zig
pub fn uploadPalette(self: *const EffectShader, effect: *const Effect) void {
    switch (self.*) {
        .colormix => |*shader| shader.uploadPalette(effect.paletteData().?),
        .glass_drift => |*shader| shader.uploadPalette(effect.gpuPalette().?),
        inline else => |*shader| {
            shader.inner.uploadPalette(effect.gpuPalette().?);
        },
    }
}

pub fn uploadStatic(self: *const EffectShader, effect: *const Effect) void {
    switch (self.*) {
        .colormix => |*shader| {
            const mods = effect.patternMods().?;
            shader.uploadStatic(mods.cos_mod, mods.sin_mod);
        },
        .glass_drift => |*shader| shader.uploadStatic(effect.gpuPhase().?),
        inline else => |*shader| {
            shader.inner.uploadStatic(effect.gpuPhase().?);
        },
    }
}
~~~

Retain the existing effect/shader tag assertions or replace force unwraps with
debug assertions immediately before them. Remove EffectShader.bind and
EffectShader.setStaticUniforms.

- [ ] **Step 6: Migrate current callers without changing their timing yet**

Keep Task 2 behavior buildable while Task 3 introduces deferral:

- ensureGpuPipeline: useProgram, bindGeometry, uploadPalette after init.
- ensureBlitShader: restore with useProgram and bindGeometry only; do not upload
  palette/static a second time.
- palette mutation handlers: useProgram, bindGeometry, uploadPalette in the
  same places that currently call bind. Task 3 removes these unsafe calls.
- SurfaceState's current needs_static_uniforms branch calls uploadStatic.

This commit must not add compatibility wrappers for the removed APIs.

- [ ] **Step 7: Run GREEN tests and commit**

~~~sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3a-t2-green zig build test-wayland-egl --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3a-t2-green zig build test --summary all
zig fmt --check build.zig src tests
git diff --check
git add build.zig src/render src/app.zig src/wayland/surface_state.zig src/test_wayland_exports.zig tests/wayland_egl/effect_shader_api_test.zig
git commit -m "refactor(renderer): split shader upload operations"
~~~

Expected: all tests pass; the API test proves no combined API remains.

---

### Task 3: Defer uploads to the first current render surface

**Files:**
- Modify: src/app.zig
- Modify: src/wayland/surface_state.zig
- Modify: src/test_wayland_exports.zig
- Modify: tests/wayland_egl/surface_detach_test.zig
- Modify: tests/wayland_egl/gpu_upload_state_test.zig

**Interfaces:**
- Consumes: GpuUploadState and the split EffectShader API.
- Produces: App.gpu_upload_state ownership and SurfaceState.renderTick(self, shader, upload_state, blit_shader).

- [ ] **Step 1: Add failing ownership and signature tests**

Add to tests/wayland_egl/surface_detach_test.zig:

~~~zig
test "program global upload state is app owned" {
    try std.testing.expect(@hasField(App, "gpu_upload_state"));
    try std.testing.expect(!@hasField(SurfaceState, "needs_static_uniforms"));
}

test "render tick receives mutable shader and app upload state" {
    const info = @typeInfo(@TypeOf(SurfaceState.renderTick)).@"fn";
    try std.testing.expectEqual(@as(usize, 4), info.params.len);
    try std.testing.expect(
        info.params[1].type.? == ?*wayland.effect_shader.EffectShader,
    );
    try std.testing.expect(
        info.params[2].type.? ==
            *wayland.gpu_upload_state.GpuUploadState,
    );
}
~~~

Export gpu_upload_state and effect_shader from src/test_wayland_exports.zig.

- [ ] **Step 2: Run the RED integration tests**

~~~sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3a-t3-red zig build test-wayland-egl --summary all
~~~

Expected: FAIL because App lacks gpu_upload_state, SurfaceState still has
needs_static_uniforms, and renderTick has the old signature.

- [ ] **Step 3: Make App own and reset upload state**

Add:

~~~zig
const GpuUploadState =
    @import("render/gpu_upload_state.zig").GpuUploadState;
~~~

Add App field and initializer:

~~~zig
gpu_upload_state: GpuUploadState,
// App.init:
.gpu_upload_state = .{},
~~~

Use:

~~~zig
fn markGpuPaletteDirty(self: *App) void {
    self.gpu_upload_state.markPaletteDirty(self.effect_shader != null);
}
~~~

After successful EffectShader.init:

~~~zig
self.gpu_upload_state = GpuUploadState.newGeneration();
~~~

Clear upload state in both GpuEpochOps.deleteAppGl and
GpuEpochOps.clearHandles, and whenever effect_shader is explicitly deinitialized
and set null during a successful effect switch:

~~~zig
self.app.gpu_upload_state.clear();
~~~

- [ ] **Step 4: Remove handler-time GL calls**

In fade tick, handleSetPalette, immediate handleSetColors, and same-effect
handleReload, keep Effect/current_palette mutation but replace shader bind calls
with:

~~~zig
self.markGpuPaletteDirty();
~~~

No IPC handler, fade handler, or reload handler may call useProgram,
bindGeometry, uploadPalette, uploadStatic, or a raw glUniform operation.

Remove startup uploads from ensureGpuPipeline. Immediately after publishing a
successful shader, set newGeneration before optional blit initialization.

ensureBlitShader already runs with a current context. After binding a newly
created blit shader:

~~~zig
if (!self.gpu_upload_state.dirty.program_binding) {
    effect_shader.useProgram();
    effect_shader.bindGeometry();
}
~~~

When a shader generation is new, program_binding remains dirty and the first
render flush performs the one required effect binding. When blit is enabled
mid-session on a clean generation, ensureBlitShader restores the effect program
and geometry immediately so the next clean render is correct. Neither path
uploads palette/static state or clears dirty bits, and neither duplicates
new-generation geometry work.

- [ ] **Step 5: Flush after makeCurrent inside SurfaceState**

Remove needs_static_uniforms from SurfaceState, its initializer, resize path, and
render path.

Add imports and adapter:

~~~zig
const GpuUploadState =
    @import("../render/gpu_upload_state.zig").GpuUploadState;

const EffectUploadOps = struct {
    shader: *EffectShader,
    effect: *const Effect,

    pub fn useProgram(self: *EffectUploadOps) void {
        self.shader.useProgram();
    }
    pub fn bindGeometry(self: *EffectUploadOps) void {
        self.shader.bindGeometry();
    }
    pub fn uploadPalette(self: *EffectUploadOps) void {
        self.shader.uploadPalette(self.effect);
    }
    pub fn uploadStatic(self: *EffectUploadOps) void {
        self.shader.uploadStatic(self.effect);
    }
};
~~~

Change the signature:

~~~zig
pub fn renderTick(
    self: *SurfaceState,
    shader: ?*EffectShader,
    upload_state: *GpuUploadState,
    blit_shader: ?*const BlitShader,
) void
~~~

Immediately after a successful egl_surf.makeCurrent(ctx):

~~~zig
if (shader) |active_shader| {
    var upload_ops = EffectUploadOps{
        .shader = active_shader,
        .effect = self.effect,
    };
    upload_state.flushIfCurrent(EffectUploadOps, &upload_ops, true);
    // existing per-frame uniforms and draw follow
}
~~~

Update App's render loop to pass mutable effect_shader, the address of
gpu_upload_state, and blit_shader in that order. Do not add an App-level
makeCurrent pass.

- [ ] **Step 6: Verify no unsafe legacy path remains**

Run:

~~~sh
rg -n 'needs_static_uniforms|setStaticUniforms|\.bind\(&self\.effect\)' src
rg -n 'useProgram|bindGeometry|uploadPalette|uploadStatic|glUniform' \
  src/app.zig
~~~

Expected: the first scan returns no matches. The second scan finds no handler,
fade, or reload upload call; only type declarations/imports are acceptable.

- [ ] **Step 7: Run GREEN tests and commit**

~~~sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3a-t3-green zig build test-wayland-egl --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3a-t3-green zig build test --summary all
zig fmt --check build.zig src tests
git diff --check
git add src/app.zig src/wayland/surface_state.zig src/test_wayland_exports.zig tests/wayland_egl
git commit -m "fix(renderer): defer GPU uploads until context current"
~~~

Expected: focused and full graphs pass; shader generation remains fully dirty
until the first current surface, palette-only changes upload once, and clean
frames make no program-global upload.

---

### Task 4: Model permanent GPU fallback independently

**Files:**
- Create: src/render/gpu_fallback.zig
- Create: tests/wayland_egl/gpu_fallback_test.zig
- Modify: src/render/effect.zig
- Modify: tests/effect_mutation_test.zig
- Modify: src/test_exports.zig
- Modify: build.zig

**Interfaces:**
- Consumes: an operations adapter describing failure, latch, epoch, effect, palette, stand-ins, and surfaces.
- Produces: gpu_fallback.apply(Ops, ops) bool and Effect.fallbackToColormix(colors) bool.

- [ ] **Step 1: Add failing fallback orchestration tests**

Create tests/wayland_egl/gpu_fallback_test.zig with an Event enum:

~~~zig
const Event = enum {
    close_epoch,
    replace_colormix,
    invalidate_standins,
    configure_cpu,
    mark_applied,
};
~~~

The FakeOps stores permanent_failure, applied, gpu_only, authoritative_palette,
replacement_palette, event array, and counters. It implements:

~~~zig
pub fn permanentFailure(self: *FakeOps) bool;
pub fn fallbackApplied(self: *FakeOps) bool;
pub fn closeGpuEpoch(self: *FakeOps) void;
pub fn effectIsGpuOnly(self: *FakeOps) bool;
pub fn currentPalette(self: *FakeOps) [3]Rgb;
pub fn replaceWithColormix(self: *FakeOps, colors: [3]Rgb) void;
pub fn invalidateCpuStandins(self: *FakeOps) void;
pub fn configureCpuSurfaces(self: *FakeOps) void;
pub fn markFallbackApplied(self: *FakeOps) void;
~~~

Add tests with these exact expectations:

- recoverable failure=false: apply returns false and records no events;
- permanent colormix: close_epoch, invalidate_standins, configure_cpu,
  mark_applied;
- permanent GPU-only: the same order with replace_colormix after close_epoch,
  using authoritative_palette rather than a different embedded fake palette;
- call apply twice: first true, second false, every counter remains one.

Add tests/effect_mutation_test.zig cases that call
Effect.fallbackToColormix(colors):

- existing colormix returns false and preserves frames and pattern modifiers;
- every GPU-only EffectType returns true and becomes colormix;
- converted colormix preserves frameAdvanceMs and speed;
- converted paletteData equals a freshly initialized colormix built from the
  supplied colors.

- [ ] **Step 2: Run RED fallback tests**

~~~sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3a-t4-red zig build test-wayland-egl --summary all
~~~

Expected: FAIL because gpu_fallback and Effect.fallbackToColormix do not exist.

- [ ] **Step 3: Implement the pure fallback transition**

Create src/render/gpu_fallback.zig:

~~~zig
pub fn apply(comptime Ops: type, ops: *Ops) bool {
    if (!ops.permanentFailure() or ops.fallbackApplied()) return false;

    ops.closeGpuEpoch();
    if (ops.effectIsGpuOnly()) {
        ops.replaceWithColormix(ops.currentPalette());
    }
    ops.invalidateCpuStandins();
    ops.configureCpuSurfaces();
    ops.markFallbackApplied();
    return true;
}
~~~

Add Effect.fallbackToColormix. Capture speed and frameAdvanceMs before replacing
the tagged union. Return false for colormix. For every other tag:

~~~zig
pub fn fallbackToColormix(self: *Effect, colors: [3]Rgb) bool {
    if (!self.isGpuOnly()) return false;
    const advance_ms = self.frameAdvanceMs();
    const current_speed = self.speed();
    self.* = .{ .colormix = ColormixRenderer.init(
        colors[0],
        colors[1],
        colors[2],
        advance_ms,
        current_speed,
    ) };
    return true;
}
~~~

Export gpu_fallback and wire the test into test-wayland-egl and test.

- [ ] **Step 4: Run GREEN tests and commit**

~~~sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3a-t4-green zig build test-wayland-egl --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3a-t4-green zig build test --summary all
zig fmt --check build.zig src tests
git diff --check
git add build.zig src/render/gpu_fallback.zig src/render/effect.zig src/test_exports.zig tests
git commit -m "refactor(renderer): model permanent GPU fallback"
~~~

---

### Task 5: Route every permanent failure through one App transition

**Files:**
- Modify: src/app.zig
- Modify: src/render/gpu_epoch.zig
- Modify: tests/wayland_egl/gpu_epoch_test.zig
- Modify: tests/wayland_egl/gpu_fallback_test.zig
- Modify: src/test_wayland_exports.zig

**Interfaces:**
- Consumes: gpu_fallback.apply, Effect.fallbackToColormix, closeGpuEpoch, GpuUploadState.
- Produces: App.gpu_fallback_applied, latchPermanentGpuFailure, the
  production-used public applyPermanentGpuFallback method, and
  enterPermanentGpuFallback.

- [ ] **Step 1: Add failing App-level state and idempotence tests**

In tests/wayland_egl/gpu_fallback_test.zig, add focused App fixtures with empty
surfaces/detached_gpu, null EGL/shader handles, gpu_pipeline_failed,
gpu_fallback_applied, effect, current_palette, and gpu_upload_state initialized
explicitly. Call app.applyPermanentGpuFallback directly. The method is part of
the production transition and is called by production code; do not add a
test-only App adapter. Required tests:

- permanent colormix failure sets gpu_fallback_applied and retains colormix;
- permanent GPU-only failure converts from app.current_palette even when the
  selected effect's embedded palette differs;
- a second apply preserves a manually advanced colormix frame counter;
- failure=false leaves state and effect unchanged.

Update gpu_epoch_test by deleting the old requiresCpuFallback expectations.
Add a compile-time expectation that gpu_epoch no longer declares
requiresCpuFallback.

- [ ] **Step 2: Run RED App fallback tests**

~~~sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3a-t5-red zig build test-wayland-egl --summary all
~~~

Expected: FAIL because gpu_fallback_applied and the public production transition
are absent.

- [ ] **Step 3: Add the App operations adapter and central methods**

Add App field initialized false:

~~~zig
gpu_fallback_applied: bool,
~~~

Add PermanentGpuFallbackOps with exact behavior:

~~~zig
const PermanentGpuFallbackOps = struct {
    app: *App,

    pub fn permanentFailure(self: *@This()) bool {
        return self.app.gpu_pipeline_failed;
    }
    pub fn fallbackApplied(self: *@This()) bool {
        return self.app.gpu_fallback_applied;
    }
    pub fn closeGpuEpoch(self: *@This()) void {
        self.app.closeGpuEpoch();
    }
    pub fn effectIsGpuOnly(self: *@This()) bool {
        return self.app.effect.isGpuOnly();
    }
    pub fn currentPalette(self: *@This()) [3]defaults.Rgb {
        return self.app.current_palette;
    }
    pub fn replaceWithColormix(
        self: *@This(),
        colors: [3]defaults.Rgb,
    ) void {
        _ = self.app.effect.fallbackToColormix(colors);
    }
    pub fn invalidateCpuStandins(self: *@This()) void {
        for (self.app.surfaces.items) |surface| surface.shm_effect = null;
    }
    pub fn configureCpuSurfaces(self: *@This()) void {
        for (self.app.surfaces.items) |surface| {
            surface.configureCpuFallbackAfterDetach();
        }
    }
    pub fn markFallbackApplied(self: *@This()) void {
        self.app.gpu_fallback_applied = true;
    }
};
~~~

Add:

~~~zig
fn latchPermanentGpuFailure(self: *App) void {
    self.gpu_pipeline_failed = true;
}

pub fn applyPermanentGpuFallback(self: *App) void {
    var ops = PermanentGpuFallbackOps{ .app = self };
    _ = gpu_fallback.apply(PermanentGpuFallbackOps, &ops);
}

fn enterPermanentGpuFallback(self: *App) void {
    self.latchPermanentGpuFailure();
    self.applyPermanentGpuFallback();
}
~~~

- [ ] **Step 4: Route all permanent failures and preserve switch ordering**

Replace direct failure assignments and forceCpuFallbackForGpuOnly in:

- EGL context initialization failure;
- shader initialization failure;
- all-candidate pipeline makeCurrent failure;
- surface retirement with GL-owned state but no compatible current surface;
- effect-switch cleanup failure.

Remove gpu_epoch.requiresCpuFallback, forceCpuFallbackForGpuOnly, and the old
conversion-only applyPermanentGpuFallback.

For switchEffect cleanup failure, use this required order:

~~~zig
// Old program could not be safely retired.
self.latchPermanentGpuFailure();

// Publish the requested effect and palette before fallback policy runs.
self.effect = Effect.init(cfg);
self.current_palette = cfg.palette;
self.applyPermanentGpuFallback();
~~~

Do not close the epoch or mark gpu_fallback_applied for the old effect before
publishing the new effect. applyPermanentGpuFallback closes the epoch exactly
once, then evaluates the new effect. On every switch path, current_palette must
equal cfg.palette before a faulted shader can convert a GPU-only selection.

For shader init failure after the new effect is already published:

~~~zig
self.enterPermanentGpuFallback();
return;
~~~

Zero-output closeGpuEpoch remains unlatching and recoverable. BlitShader.init
failure only removes offscreen FBOs and keeps direct GPU rendering.

- [ ] **Step 5: Verify routing statically**

~~~sh
rg -n 'forceCpuFallbackForGpuOnly|requiresCpuFallback' src tests
rg -n 'gpu_pipeline_failed = true' src/app.zig
rg -n 'effect\.isGpuOnly\\(\\).*force|shader init.*isGpuOnly' src/app.zig
~~~

Expected: first and third scans return no matches. The second finds only
latchPermanentGpuFailure.

- [ ] **Step 6: Run GREEN tests and commit**

~~~sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3a-t5-green zig build test-wayland-egl --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3a-t5-green zig build test --summary all
zig fmt --check build.zig src tests
git diff --check
git add src/app.zig src/render/gpu_epoch.zig src/test_wayland_exports.zig tests/wayland_egl
git commit -m "fix(app): centralize permanent GPU fallback"
~~~

---

### Task 6: Add deterministic pre-GL shader-init fault injection

**Files:**
- Create: src/render/shader_init_policy.zig
- Create: tests/wayland_egl/shader_init_policy_test.zig
- Modify: src/render/effect_shader.zig
- Modify: build.zig

**Interfaces:**
- Consumes: build_options.phase3a_force_shader_init_failure.
- Produces: shader_init_policy.beforeInitialization and the build option phase3a-force-shader-init-failure.

- [ ] **Step 1: Add false and true policy modules plus failing tests**

Create tests/wayland_egl/shader_init_policy_test.zig:

~~~zig
const std = @import("std");
const normal_policy = @import("normal_policy");
const forced_policy = @import("forced_policy");

test "normal build permits shader initialization" {
    try normal_policy.beforeInitialization();
}

test "fault build fails before shader initialization" {
    try std.testing.expectError(
        error.Phase3aForcedShaderInitFailure,
        forced_policy.beforeInitialization(),
    );
}
~~~

In build.zig, compile src/render/shader_init_policy.zig twice as normal_policy
and forced_policy. Give each module its own addOptions import named
build_options, with phase3a_force_shader_init_failure false and true
respectively. Wire the test into test-wayland-egl and test.

- [ ] **Step 2: Run the RED policy test**

~~~sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3a-t6-red zig build test-wayland-egl --summary all
~~~

Expected: FAIL because shader_init_policy.zig and beforeInitialization are absent.

- [ ] **Step 3: Implement the policy and production option**

Create src/render/shader_init_policy.zig:

~~~zig
const build_options = @import("build_options");

pub const Error = error{Phase3aForcedShaderInitFailure};

pub fn beforeInitialization() Error!void {
    if (build_options.phase3a_force_shader_init_failure) {
        return error.Phase3aForcedShaderInitFailure;
    }
}
~~~

In build.zig:

~~~zig
const force_shader_failure = b.option(
    bool,
    "phase3a-force-shader-init-failure",
    "Force effect shader initialization to fail before any GL object is created",
) orelse false;
const daemon_options = b.addOptions();
daemon_options.addOption(
    bool,
    "phase3a_force_shader_init_failure",
    force_shader_failure,
);
mod.addOptions("build_options", daemon_options);
wayland_exports_mod.addOptions("build_options", daemon_options);
~~~

If src_exports_mod reaches app.zig in a build configuration, give it the same
build_options import. Do not give the control-client module an unused option.

At the first line of EffectShader.init before its switch:

~~~zig
try @import("shader_init_policy.zig").beforeInitialization();
~~~

The hook must run before any leaf init or GL object creation. It does not affect
BlitShader.init.

- [ ] **Step 4: Run GREEN policy, normal, and forced builds**

~~~sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3a-t6-green zig build test-wayland-egl --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3a-t6-green zig build test --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3a-t6-fault \
  zig build -Doptimize=ReleaseSafe \
  -Dphase3a-force-shader-init-failure=true \
  --prefix /tmp/wlchroma-phase3a-fault --summary all
zig fmt --check build.zig src tests
git diff --check
~~~

Expected: tests pass, the default build remains normal, and the opt-in
ReleaseSafe binary builds at /tmp/wlchroma-phase3a-fault/bin/wlchroma.

- [ ] **Step 5: Commit Task 6**

~~~sh
git add build.zig src/render/effect_shader.zig src/render/shader_init_policy.zig tests/wayland_egl/shader_init_policy_test.zig
git commit -m "test(renderer): add shader-init fault injection"
~~~

---

### Task 7: Complete automated, live, review, and audit closeout

**Files:**
- Modify after evidence exists: docs/security/2026-07-19-security-performance-audit.md
- No production file is modified solely to make verification pass; failures return to the responsible task.

**Interfaces:**
- Consumes: all Task 1-6 commits and the approved Phase 3A design.
- Produces: independent final review, complete evidence, and Fixed dispositions for GPU-M4, GPU-M5, and GPU-M6.

- [ ] **Step 1: Run formatting and static invariants**

~~~sh
zig fmt --check build.zig src tests
git diff --check
rg -n 'needs_static_uniforms|setStaticUniforms|forceCpuFallbackForGpuOnly|requiresCpuFallback' src tests
rg -n 'gpu_pipeline_failed = true' src/app.zig
rg -n 'phase3a_force_shader_init_failure' build.zig src/render
~~~

Expected: formatting/diff pass; the legacy-symbol scan is empty; permanent
failure assignment exists only in the latch method; the fault option is false
by default and checked before EffectShader's first leaf init.

- [ ] **Step 2: Run the complete Debug graph**

~~~sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3a-debug zig build --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3a-debug zig build test-wayland-egl --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3a-debug zig build test --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3a-config zig test src/config/config.zig
~~~

Expected: every build step and test passes with normal host Unix-socket
syscalls. Record exact step/test totals.

- [ ] **Step 3: Run ReleaseSafe and ReleaseFast graphs**

~~~sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3a-safe \
  zig build -Doptimize=ReleaseSafe --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3a-safe \
  zig build test -Doptimize=ReleaseSafe --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3a-fast \
  zig build -Doptimize=ReleaseFast --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3a-fast \
  zig build test -Doptimize=ReleaseFast --summary all
~~~

Expected: all graphs pass with no overflow-, optional-, union-, or
undefined-behavior-sensitive failure.

- [ ] **Step 4: Prepare safe live acceptance**

Read-only checks first:

~~~sh
pgrep -a wlchroma
systemctl --user --no-pager --full status wlchroma-session-restore.service
niri msg outputs
printf '%s\n' "$NIRI_SOCKET"
~~~

Record the exact original PID, binary, config, IPC socket, Niri socket, and
output state. Never use name-wide pkill. Arm and dry-run an independent
user-systemd output-recovery action using the explicit current NIRI_SOCKET and
absolute niri binary before disabling the final output.

- [ ] **Step 5: Run normal GPU dirty-state acceptance**

Build/install an isolated ReleaseSafe normal binary under /tmp. Start it with a
temporary IPC socket and config after gracefully stopping only the exact
original daemon.

Verify:

1. a GPU-only effect animates;
2. GPU-only to colormix switch without resize immediately shows the normal
   non-default colormix pattern;
3. two screenshots taken across frames differ;
4. output-less set-colors, followed by watchdog restoration, renders the newest
   palette;
5. IPC query remains responsive;
6. journal contains no repeated program-state uploads, EGL errors, stale
   ownership warning, allocation warning, or retry loop.

If a second output exists, confirm both outputs update while logs/test
instrumentation report one program-global upload per mutation. Otherwise record
the hardware limitation.

- [ ] **Step 6: Run forced shader-failure acceptance**

Use:

~~~sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3a-live-fault \
  zig build -Doptimize=ReleaseSafe \
  -Dphase3a-force-shader-init-failure=true \
  --prefix /tmp/wlchroma-phase3a-live-fault --summary all
~~~

Start the isolated fault binary with colormix. Verify:

- the forced error occurs once before any effect shader is published;
- the GPU epoch closes;
- the same selected colormix renders through SHM rather than a black EGL clear;
- IPC stays responsive across multiple ticks;
- no shader retry/fallback loop or resource warning appears.

Stop through the exact IPC socket, restore the exact original binary/config,
confirm its PID/query, and confirm every output is enabled at its original
scale.

- [ ] **Step 7: Request final independent review**

Generate a review package from merge base 4822791 through HEAD. The reviewer
must inspect the approved design, this plan, commit list, full diff, test
evidence, static scans, and live evidence. Critical and Important findings are
fixed by one follow-up agent and re-reviewed. Minor findings are either fixed or
explicitly dispositioned before merge.

- [ ] **Step 8: Update the audit ledger only after approval**

Change only these rows:

- GPU-M4 to Fixed with exact responsible commit IDs;
- GPU-M5 to Fixed with exact responsible commit IDs;
- GPU-M6 to Fixed with exact responsible commit IDs.

Append a Phase 3A completion record containing:

- disposition and implementation commits;
- focused/full/config totals;
- Debug/ReleaseSafe/ReleaseFast results;
- static invariant scans;
- independent task and final review evidence;
- normal and forced-failure live evidence;
- compositor/output/watchdog details;
- exact normal-daemon restoration;
- unavailable multi-output acceptance, if applicable.

Preserve every original finding description.

- [ ] **Step 9: Commit the ledger**

~~~sh
git add docs/security/2026-07-19-security-performance-audit.md
git commit -m "docs(security): close phase 3a GPU findings"
git status --short --branch
~~~

Expected: clean phase-3a-gpu-correctness worktree with every Phase 3A
requirement implemented, verified, reviewed, and documented.
