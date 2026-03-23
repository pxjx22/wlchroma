# Research: Effect System & Multi-Shader Support

**Feature**: 001-effect-system
**Date**: 2026-03-23
**Status**: Complete — all unknowns resolved

---

## Decision 1: Effect Architecture Pattern

**Decision**: Zig tagged unions for both `Effect` (renderer state) and `EffectShader` (GPU
pipeline). Each effect is a variant of the union; the render loop dispatches through the
union interface without knowing which effect is active.

**Rationale**: This was the design chosen in the prior session (per `appbreaker.md`).
Zig tagged unions are zero-cost abstractions with exhaustive switch dispatch enforced by the
compiler. Adding a new effect requires adding one new tag + one new struct; no existing
variant code is touched. No vtable indirection, no dynamic allocation per call.

**Alternatives considered**:
- Vtable/function pointer approach: avoids tagged unions but requires pointer stability
  guarantees and is less idiomatic in Zig.
- Single `ShaderProgram` struct with an internal mode: would require growing the struct and
  adding branch logic inside existing methods, violating FR-009 (isolation requirement).

---

## Decision 2: Glass Drift Shader Design

**Decision**: Layered sinusoidal UV distortion with three independent pane layers at
different orientations and drift speeds. Fixed frosted-glass color palette (3 hardcoded
colors: ice blue `#7BA9CC`, pale silver `#BCC9D8`, deep slate `#4A6B88`). No palette
config for Glass Drift in v1 (palette is a colormix-only setting).

**Rationale**: The shader ideas doc describes "soft translucent color panes sliding past
each other, less turbulent warp". Three sinusoidal layers at different angles achieves
this with GLSL ES 1.00 compatibility and low arithmetic cost. The shader is structurally
simpler than colormix (no iterative warp loop), so thermal impact should be lower.

GLSL structure sketch:
```
- Normalize UV to [-1, 1] range
- Layer 1: sin(uv.x * A1 + uv.y * B1 + time * S1 + phase)
- Layer 2: sin(uv.x * A2 - uv.y * B2 + time * S2 + phase + PI/3)
- Layer 3: sin(uv.x * A3 + uv.y * B3 - time * S3 + phase + 2*PI/3)
- Blend 3 hardcoded RGB colors using layers as weights
```

`phase` is a per-session random offset (from `GlassDriftRenderer.phase_offset`) uploaded
as a static uniform once after bind, so the animation is not identical every run.

**Alternatives considered**:
- Noise-based approach: higher arithmetic cost, harder to keep low-power.
- Reusing colormix palette: would require passing palette through to Glass Drift;
  keeps the effect-specific settings entangled. Deferred to a future per-effect spec.

---

## Decision 3: BlitShader Coupling Resolution

**Decision**: Add `program()`, `vbo()`, and `a_pos_loc()` accessor methods to
`EffectShader`. Rename `BlitShader.draw()` parameters from `colormix_*` to `effect_*`
(purely cosmetic — the callers pass values through the new accessors). No behavioral
change.

**Rationale**: `BlitShader.draw()` currently restores the colormix shader state after the
blit pass (so the next colormix draw doesn't need a full re-bind). With the effect system,
it needs to restore whatever the *active* effect shader is. The parameter types are the same
(`GLuint`); only the naming and call site change.

**Alternatives considered**:
- Pass the `EffectShader*` into `BlitShader.draw()`: tighter coupling in the other
  direction; would require BlitShader to import EffectShader.
- Remove state restoration from draw(): would require `EffectShader.bind()` to be called
  after every blit, adding one program switch per frame. Cost is negligible but
  the restoration approach keeps the current design invariant.

---

## Decision 4: Speed Multiplier Application

**Decision**: Speed scales the time value passed to the shader uniforms, not the frame
advance rate. `time_for_shader = frames * TIME_SCALE * speed`. The `speed` field is
stored in `AppConfig` and propagated to `Effect.init()`. It is exposed via `Effect.speed()`
and used in `EffectShader.setUniforms()` when computing the time value.

**Rationale**: Scaling time rather than frame rate keeps the pacing constant (still 15fps)
while changing animation velocity. This is simpler to implement (no timer changes) and
matches user expectation: `speed = 0.5` = half-speed animation, not half-FPS.

`speed` is NOT uploaded as a GLSL uniform — it is multiplied into `time` on the CPU side
before upload. This avoids adding a uniform location to every shader.

**Alternatives considered**:
- `u_speed` GLSL uniform: would require every shader to declare it and every EffectShader
  to query its location. Unnecessary since time is already a float computed per-frame.
- Scaling `frame_advance_ms`: changes the pacing gate, harder to reason about.

---

## Decision 5: SHM Fallback for GPU-Only Effects

**Decision**: Override at `App.init()` level. If `egl_ctx` is null (GPU unavailable) AND
`effect_type` is a GPU-only effect (currently: `glass_drift`), log a clear warning and
change the `Effect` to `colormix` before creating any `SurfaceState`. SurfaceState is
always handed a fully valid `Effect` that can render on whatever path is active.

**Rationale**: Simplest correctness boundary. `SurfaceState` does not need to know about
GPU-only effects. The fallback decision is made once in `App.init()`. No branching
added to the hot render path.

**Alternatives considered**:
- Check in `SurfaceState.renderTick()`: adds a branch to the hot path every tick.
- `Effect.fallback()` method: more abstract but unnecessary indirection for a single
  decision made once at startup.

---

## Decision 6: colormix.zig SHM path unchanged

**Decision**: `ColormixRenderer.renderGrid()` stays identical. On the SHM path,
`SurfaceState.renderTick()` calls `self.effect.renderGrid(...)` which dispatches to the
colormix variant. Glass Drift has no `renderGrid()` (GPU-only). The dispatch in
`Effect.renderGrid()` returns early if the active variant is GPU-only (should not be
reachable after Decision 5, but guarded for safety).

---

## Summary Table

| Unknown | Decision | Rationale |
|---------|----------|-----------|
| Architecture pattern | Tagged unions | Zero-cost, compiler-enforced exhaustive dispatch |
| Glass Drift shader | 3-layer sinusoidal pane blend | Low-power, GLES2-compatible, distinct from colormix |
| BlitShader coupling | `EffectShader` accessors | Minimal change, no new coupling direction |
| Speed application | Multiply into `time` pre-upload | Simple, no new uniforms, no FPS change |
| SHM fallback | Override in `App.init()` | Single decision point, hot path stays clean |
| SHM colormix | `renderGrid()` dispatch on Effect | Existing CPU path unchanged |
