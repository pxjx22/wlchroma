# Implementation Plan: Effect System & Multi-Shader Support

**Branch**: `001-effect-system` | **Date**: 2026-03-23 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/001-effect-system/spec.md`

## Summary

Introduce a typed effect system that allows config-based selection of animated wallpaper
shaders, starting with Glass Drift as the second effect alongside the existing colormix.
The design uses Zig tagged unions for both the renderer state (`Effect`) and the GPU
pipeline (`EffectShader`), keeping each effect fully isolated and the main render loop
effect-agnostic. A shared `speed` multiplier is added to `[effect.settings]` in config
and applies uniformly across all effects.

## Technical Context

**Language/Version**: Zig 0.15.2 (pinned in `.zig-version`)
**Primary Dependencies**: `wayland-client`, `wayland-egl`, `EGL`, `GLESv2` (system libs)
**Storage**: TOML config file (`~/.config/wlchroma/config.toml`)
**Testing**: `zig build test` (built-in Zig test runner)
**Target Platform**: Linux Wayland (wlr-layer-shell compositor)
**Project Type**: Single-binary system daemon
**Performance Goals**: Glass Drift at 15 fps with no measurable thermal delta vs. colormix
**Constraints**: GLES 2.0 / GLSL ES 1.00 only; no compute shaders; no third-party packages
**Scale/Scope**: Single binary; 5 new source files, 5 modified source files

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Wayland-Native | ✅ PASS | No new protocols. EGL/GLES2 only. No new system library links. |
| II. Low-Power by Default | ✅ PASS | Glass Drift defaults to 15fps; speed default 1.0 (unchanged). Shader complexity must be validated in code review (not increased beyond colormix). |
| III. Graceful Degradation | ✅ PASS | GPU-only effects fall back to colormix on SHM path (FR-007). Handled in App.init before SurfaceState creation. |
| IV. Minimal Config Surface | ✅ PASS | Two new keys: `effect.name` (existing stub → real) and `effect.settings.speed`. Both added to README v1 surface. |
| V. Single Binary | ✅ PASS | Five new .zig files compile into the existing binary. No new build deps. |

*Post-design re-check*: All principles continue to pass. BlitShader state restoration is
made effect-agnostic by adding `program()`, `vbo()`, `a_pos_loc()` accessors on
`EffectShader`. No new protocols, libs, or build steps introduced.

## Project Structure

### Documentation (this feature)

```text
specs/001-effect-system/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output (add-a-third-effect guide)
├── contracts/
│   └── config-schema.md # Phase 1 output (TOML config contract)
└── tasks.md             # Phase 2 output (/speckit.tasks)
```

### Source Code (repository root)

```text
src/
├── config/
│   ├── config.zig           MODIFIED — EffectType enum; effect_type + speed in AppConfig;
│   │                                   effect.name accepts glass_drift; speed key in
│   │                                   effect.settings; strict range validation for speed
│   └── defaults.zig         unchanged
├── render/
│   ├── effect.zig           NEW — Effect tagged union (colormix | glass_drift);
│   │                               shared interface: maybeAdvance, frames, speed, isGpuOnly
│   ├── effect_shader.zig    NEW — EffectShader tagged union; shared interface:
│   │                               init, bind, setStaticUniforms, setUniforms, draw,
│   │                               program/vbo/a_pos_loc accessors (for BlitShader restore)
│   ├── colormix_shader.zig  NEW — ColormixShader extracted from shader.zig ShaderProgram;
│   │                               identical behavior, renamed struct
│   ├── glass_drift.zig      NEW — GlassDriftRenderer (frames, advance, speed, phase)
│   ├── glass_drift_shader.zig NEW — GlassDriftShader (GLSL ES 1.00 layered pane effect)
│   ├── shader.zig           MODIFIED — remove ShaderProgram (moved to colormix_shader.zig);
│   │                                   make compileShader pub; keep BlitShader unchanged;
│   │                                   rename BlitShader.draw() params to be effect-agnostic
│   ├── colormix.zig         MODIFIED — remove `ShaderProgram` import (no longer needed here)
│   ├── egl_context.zig      unchanged
│   ├── egl_surface.zig      unchanged
│   ├── framebuffer.zig      unchanged
│   ├── offscreen.zig        unchanged
│   └── palette.zig          unchanged
├── wayland/
│   ├── surface_state.zig    MODIFIED — replace ColormixRenderer+ShaderProgram references
│   │                                   with Effect+EffectShader; remove palette_data field
│   │                                   (absorbed into ColormixShader); update render path
│   └── ...                  unchanged
├── app.zig                  MODIFIED — replace renderer:ColormixRenderer+shader:ShaderProgram
│                                       with effect:Effect+effect_shader:EffectShader;
│                                       SHM fallback override when GPU-only + no EGL
├── main.zig                 unchanged
└── wl.zig                   unchanged

README.md                    MODIFIED — document effect.name and effect.settings.speed
                                        in the v1 config surface section
config.toml.example          MODIFIED — add [effect] name example and speed example
```

**Structure Decision**: Single project (Option 1). All new code lives under `src/render/`.
No new top-level directories needed.

## Complexity Tracking

> No constitution violations. Table left blank intentionally.
