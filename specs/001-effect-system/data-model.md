# Data Model: Effect System & Multi-Shader Support

**Feature**: 001-effect-system
**Date**: 2026-03-23

---

## Config Layer Changes (`src/config/config.zig`)

### New: `EffectType` enum

```zig
pub const EffectType = enum {
    colormix,
    glass_drift,
};
```

### Modified: `AppConfig`

Add two fields; all existing fields unchanged:

```zig
pub const AppConfig = struct {
    fps: u32,                      // unchanged
    frame_interval_ns: u32,        // unchanged
    frame_advance_ms: u32,         // unchanged
    effect_type: EffectType,       // NEW: default .colormix
    palette: [3]Rgb,               // unchanged (colormix-specific)
    speed: f32,                    // NEW: default 1.0, range 0.25–2.5
    renderer_scale: f32,           // unchanged
    upscale_filter: UpscaleFilter, // unchanged
};
```

### Config parser changes

**`effect.name` section** (was: accepts only `"colormix"`, errors on anything else):
- Accepts `"colormix"` → `config.effect_type = .colormix`
- Accepts `"glass_drift"` → `config.effect_type = .glass_drift`
- Any other value → `error.UnsupportedEffect` (same error, still strict)
- Missing `name` key in `[effect]` section → default `.colormix`, log notice

**`effect.settings` section** (was: accepts only `palette`):
- Keep `palette` handling unchanged
- Add `speed` key: parses as float, validates 0.25 ≤ speed ≤ 2.5
  - Out of range → `error.InvalidValue`
  - Not a valid float → `error.InvalidValue`
- `shouldTrackKey` updated to include `"speed"` for `effect_settings` section

**`defaultConfig()`** additions:
```zig
.effect_type = .colormix,
.speed = 1.0,
```

---

## New: `Effect` Tagged Union (`src/render/effect.zig`)

Central effect abstraction. `App` owns one `Effect` value. `SurfaceState` holds a pointer
to it.

```zig
pub const Effect = union(EffectType) {
    colormix: ColormixRenderer,
    glass_drift: GlassDriftRenderer,

    /// Construct from config. Glass Drift is GPU-only; App.init() ensures
    /// this is only created when EGL is available (or overridden to colormix).
    pub fn init(config: *const AppConfig) Effect

    /// Advance animation frame counter (both paths share the same gate logic).
    pub fn maybeAdvance(self: *Effect, time_ms: u32) void

    /// Current frame count, for computing shader time value.
    pub fn frameCount(self: *const Effect) u64

    /// Speed multiplier from config.
    pub fn speed(self: *const Effect) f32

    /// True for effects that have no CPU/SHM rendering path.
    pub fn isGpuOnly(self: *const Effect) bool

    /// CPU render grid (SHM fallback). Only implemented for colormix.
    /// Returns without doing anything for GPU-only effects (guarded).
    pub fn renderGrid(self: *const Effect, grid_w: usize, grid_h: usize, out: []Rgb) void

    // Colormix-specific accessors (used by ColormixShader.bind):
    pub fn paletteData(self: *const Effect) ?*const [36]f32
    pub fn patternMods(self: *const Effect) ?struct { cos_mod: f32, sin_mod: f32 }

    // GlassDrift-specific accessors (used by GlassDriftShader.bind):
    pub fn phaseOffset(self: *const Effect) ?f32
};
```

---

## New: `GlassDriftRenderer` (`src/render/glass_drift.zig`)

GPU-only renderer state for Glass Drift. No `renderGrid()` method.

```zig
pub const GlassDriftRenderer = struct {
    frames: u64,
    last_advance_ms: u32,
    frame_advance_ms: u32,
    speed: f32,
    /// Random phase offset seeded at init; uploaded once as static uniform.
    /// Gives each session a unique starting visual state.
    phase_offset: f32,

    pub fn init(frame_advance_ms: u32, speed: f32) GlassDriftRenderer
    pub fn maybeAdvance(self: *GlassDriftRenderer, time_ms: u32) void
};
```

---

## New: `EffectShader` Tagged Union (`src/render/effect_shader.zig`)

GPU pipeline abstraction. `App` owns one `?EffectShader` value (null when GPU
unavailable). SurfaceState receives a const pointer per renderTick call.

```zig
pub const EffectShader = union(EffectType) {
    colormix: ColormixShader,
    glass_drift: GlassDriftShader,

    /// Compile and link the appropriate shader program for the given Effect.
    pub fn init(effect: *const Effect) !EffectShader

    /// Bind invariant GL state (program, VBO, vertex layout, static uniforms).
    /// Call once after EGL context is current.
    pub fn bind(self: *EffectShader, effect: *const Effect) void

    /// Upload static uniforms that change only on configure/resize.
    /// For colormix: cos_mod, sin_mod. For glass_drift: phase_offset.
    pub fn setStaticUniforms(self: *const EffectShader, effect: *const Effect) void

    /// Upload per-frame uniforms: time (= frameCount * TIME_SCALE * speed)
    /// and resolution. Called every renderTick before draw().
    pub fn setUniforms(self: *const EffectShader, effect: *const Effect,
                        resolution_w: f32, resolution_h: f32) void

    /// Draw the fullscreen quad. Assumes bind() and setUniforms() were called.
    pub fn draw(self: *const EffectShader) void

    /// GL resource cleanup.
    pub fn deinit(self: *EffectShader) void

    // Accessors for BlitShader state restoration after blit pass:
    pub fn glProgram(self: *const EffectShader) c.GLuint
    pub fn glVbo(self: *const EffectShader) c.GLuint
    pub fn glAPosLoc(self: *const EffectShader) c.GLuint
};
```

---

## New: `ColormixShader` (`src/render/colormix_shader.zig`)

Direct extraction of `ShaderProgram` from `shader.zig`. Identical behavior; renamed.
`buildPaletteData()` moves here from `shader.zig`.

```zig
pub const ColormixShader = struct {
    program: c.GLuint,
    vbo: c.GLuint,
    a_pos_loc: c.GLuint,
    u_time_loc: c.GLint,
    u_resolution_loc: c.GLint,
    u_cos_mod_loc: c.GLint,
    u_sin_mod_loc: c.GLint,
    u_palette_loc: c.GLint,
    bound: bool,

    // GLSL shader source: identical to current shader.zig ShaderProgram
    // vert_src and frag_src (colormix warp + palette lookup).

    pub fn init() !ColormixShader
    pub fn bind(self: *ColormixShader, palette_data: *const [36]f32) void
    pub fn setStaticUniforms(self: *const ColormixShader, cos_mod: f32, sin_mod: f32) void
    pub fn setUniforms(self: *const ColormixShader, time: f32, w: f32, h: f32) void
    pub fn draw(self: *const ColormixShader) void
    pub fn deinit(self: *ColormixShader) void
    pub fn buildPaletteData(palette: *const [12]Cell) [36]f32  // moved from shader.zig
};
```

---

## New: `GlassDriftShader` (`src/render/glass_drift_shader.zig`)

GPU pipeline for Glass Drift. Fixed hardcoded color palette (no user-configurable palette
in v1). Static uniform: `u_phase` (per-session random offset).

```zig
pub const GlassDriftShader = struct {
    program: c.GLuint,
    vbo: c.GLuint,
    a_pos_loc: c.GLuint,
    u_time_loc: c.GLint,
    u_resolution_loc: c.GLint,
    u_phase_loc: c.GLint,
    bound: bool,

    // GLSL vert: pass-through (identical to ColormixShader vert)
    // GLSL frag: three sinusoidal pane layers, fixed frosted-glass colors
    //   Colors: ice blue (#7BA9CC), pale silver (#BCC9D8), deep slate (#4A6B88)
    //   Uniforms: u_time (f32), u_resolution (vec2), u_phase (f32)
    //   No palette uniform — colors are constants in the shader source.

    pub fn init() !GlassDriftShader
    pub fn bind(self: *GlassDriftShader, phase_offset: f32) void
    pub fn setStaticUniforms(self: *const GlassDriftShader, phase_offset: f32) void
    pub fn setUniforms(self: *const GlassDriftShader, time: f32, w: f32, h: f32) void
    pub fn draw(self: *const GlassDriftShader) void
    pub fn deinit(self: *GlassDriftShader) void
};
```

---

## Modified: `App` (`src/app.zig`)

| Field | Before | After |
|-------|--------|-------|
| `renderer` | `ColormixRenderer` | `effect: Effect` |
| `shader` | `?ShaderProgram` | `effect_shader: ?EffectShader` |
| `blit_shader` | `?BlitShader` | `blit_shader: ?BlitShader` (unchanged) |

**App.init() new logic**:
1. Build `Effect` from config (`Effect.init(&config)`)
2. If `egl_ctx == null` AND `effect.isGpuOnly()`:
   - Log: `"effect <name> requires GPU; falling back to colormix on CPU path"`
   - Override effect to colormix: `effect = Effect{ .colormix = ColormixRenderer.init(...) }`

**App.run() shader init**:
- `self.effect_shader = EffectShader.init(&self.effect)` (replaces `ShaderProgram.init()`)
- `self.effect_shader.?.bind(&self.effect)` (replaces `sh.bind(&self.renderer.palette_data)`)

---

## Modified: `SurfaceState` (`src/wayland/surface_state.zig`)

| Field | Before | After |
|-------|--------|-------|
| `renderer` | `*ColormixRenderer` | `effect: *Effect` |
| `palette_data` | `[36]f32` | **removed** (absorbed into ColormixShader) |
| `needs_static_uniforms` | `bool` | `bool` (unchanged, now effect-agnostic) |

**renderTick() EGL path changes**:
- Replace `sh.setStaticUniforms(self.renderer.pattern_cos_mod, ...)` with
  `sh.setStaticUniforms(self.effect)` — dispatches internally
- Replace `time = frames * TIME_SCALE` computation with call to
  `sh.setUniforms(self.effect, w, h)` which computes `frameCount * TIME_SCALE * speed` internally
- `sh.draw()` unchanged
- `bs.draw(ofs.tex, sh.glProgram(), sh.glVbo(), sh.glAPosLoc())` — updated accessor names

**renderTick() SHM path changes**:
- Replace `self.renderer.maybeAdvance(now_ms)` with `self.effect.maybeAdvance(now_ms)`
- Replace `self.renderer.renderGrid(...)` with `self.effect.renderGrid(...)`

**SurfaceState.create() signature change**:
- Parameter `renderer: *ColormixRenderer` → `effect: *Effect`
- Remove `palette_data` initialization (field removed)

---

## Modified: `shader.zig` (`src/render/shader.zig`)

- **Remove**: `ShaderProgram` struct (moved to `colormix_shader.zig`)
- **Change**: `compileShader` from `fn` (private) to `pub fn` (shared utility)
- **Keep**: `BlitShader` unchanged except parameter rename in `draw()`
- **Rename** in `BlitShader.draw()`:
  - `colormix_program` → `effect_program`
  - `colormix_vbo` → `effect_vbo`
  - `colormix_a_pos` → `effect_a_pos`

---

## State Transition: Effect Selection at Startup

```text
loadConfig()
    └── effect_type: .colormix | .glass_drift
        speed: f32

App.init()
    └── Effect.init(&config)
            ├── .colormix → ColormixRenderer.init(palette, frame_advance_ms, speed)
            └── .glass_drift → GlassDriftRenderer.init(frame_advance_ms, speed)
        if egl unavailable AND effect.isGpuOnly():
            log warning → override to ColormixRenderer

App.run()  [EGL path only]
    └── EffectShader.init(&effect)
            ├── .colormix → ColormixShader.init()
            └── .glass_drift → GlassDriftShader.init()
        EffectShader.bind(&effect)  [uploads static uniforms, VBO, palette]

renderTick() [per frame, per surface]
    └── EffectShader.setUniforms(&effect, w, h)  [time = frames * TIME_SCALE * speed]
        EffectShader.draw()
```
