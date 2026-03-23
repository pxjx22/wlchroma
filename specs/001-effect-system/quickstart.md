# Quickstart: Adding a Third Effect

**Feature**: 001-effect-system
**Audience**: Developer adding the next shader after Glass Drift
**Purpose**: Validates SC-005 — one new file + one registration entry, no changes to
existing effect files.

---

## What "one file + one entry" means

After this feature lands, the effect system uses:
- `src/render/effect.zig` — `Effect` tagged union (owns renderer state)
- `src/render/effect_shader.zig` — `EffectShader` tagged union (owns GPU pipeline)
- `src/config/config.zig` — `EffectType` enum (drives config parsing)

Adding a third effect (e.g. `aurora_bands`) touches exactly:

1. A **new renderer file**: `src/render/aurora_bands.zig`
2. A **new shader file**: `src/render/aurora_bands_shader.zig`
3. **Three registration points** (one line each, no existing logic changed):
   - `EffectType` enum in `config.zig`
   - `Effect` union tag in `effect.zig`
   - `EffectShader` union tag in `effect_shader.zig`

No existing variant code (`colormix.zig`, `glass_drift.zig`, etc.) is touched.

---

## Step-by-step

### 1. Create the renderer (`src/render/aurora_bands.zig`)

Copy `glass_drift.zig` as a starting point. Replace the struct name and any
effect-specific fields. At minimum you need:

```zig
pub const AuroraBandsRenderer = struct {
    frames: u64,
    last_advance_ms: u32,
    frame_advance_ms: u32,
    speed: f32,
    // add any effect-specific state here

    pub fn init(frame_advance_ms: u32, speed: f32) AuroraBandsRenderer { ... }
    pub fn maybeAdvance(self: *AuroraBandsRenderer, time_ms: u32) void { ... }
};
```

### 2. Create the shader (`src/render/aurora_bands_shader.zig`)

Copy `glass_drift_shader.zig` as a starting point. Write your GLSL ES 1.00 fragment
shader. Required uniforms: `u_time` (float), `u_resolution` (vec2). Add any
effect-specific static uniforms (e.g. `u_phase`).

Implement the same interface as `GlassDriftShader`:
- `init() !AuroraBandsShader`
- `bind(...)` — upload static uniforms once
- `setStaticUniforms(...)` — re-upload on configure/resize if needed
- `setUniforms(time, w, h)` — per-frame upload
- `draw()` — fullscreen quad draw call
- `deinit()`

### 3. Register in `src/config/config.zig`

Add one tag to `EffectType`:

```zig
pub const EffectType = enum {
    colormix,
    glass_drift,
    aurora_bands,   // add this
};
```

Add one branch to the `effect.name` parser:

```zig
if (std.mem.eql(u8, val, "aurora_bands")) {
    config.effect_type = .aurora_bands;
}
```

### 4. Register in `src/render/effect.zig`

Add one tag to the union:

```zig
pub const Effect = union(EffectType) {
    colormix: ColormixRenderer,
    glass_drift: GlassDriftRenderer,
    aurora_bands: AuroraBandsRenderer,   // add this
    ...
};
```

Update each dispatch method with one new `switch` branch. The compiler will error if
you miss any — exhaustive switch is enforced.

### 5. Register in `src/render/effect_shader.zig`

Same pattern: add one tag, update each dispatch method.

```zig
pub const EffectShader = union(EffectType) {
    colormix: ColormixShader,
    glass_drift: GlassDriftShader,
    aurora_bands: AuroraBandsShader,   // add this
    ...
};
```

### 6. Build and test

```bash
zig build
./zig-out/bin/wlchroma --config /path/to/test.toml
```

Where `test.toml` contains:
```toml
version = 1
[effect]
name = "aurora_bands"
```

---

## What you do NOT need to change

- `app.zig` — effect creation and shader init are fully generic
- `surface_state.zig` — render path dispatches through `Effect`/`EffectShader` interfaces
- `shader.zig` — `compileShader` is a shared utility; `BlitShader` is effect-agnostic
- Any existing effect files (`colormix.zig`, `glass_drift.zig`, etc.)
- `build.zig` — new `.zig` files are picked up automatically via `@import`
