---

description: "Task list for Effect System & Multi-Shader Support"
---

# Tasks: Effect System & Multi-Shader Support

**Input**: Design documents from `/specs/001-effect-system/`
**Prerequisites**: plan.md ✅ spec.md ✅ research.md ✅ data-model.md ✅ contracts/ ✅ quickstart.md ✅

**Tests**: Not requested — no test tasks generated.

**Organization**: Tasks grouped by user story for independent implementation and testing.

## Format: `[ID] [P?] [Story?] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1, US2, US3)
- Include exact file paths in descriptions

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Extract `compileShader` as a public utility and create the new file stubs so
all subsequent phases can build without import errors.

- [X] T001 Make `compileShader` public in `src/render/shader.zig` (change `fn compileShader` to `pub fn compileShader`)
- [X] T002 [P] Remove `ShaderProgram` struct from `src/render/shader.zig` (it moves to `colormix_shader.zig` in T004 — do T004 before T002, or keep stub until T004 lands)
- [X] T003 [P] Rename `BlitShader.draw()` parameters in `src/render/shader.zig`: `colormix_program` → `effect_program`, `colormix_vbo` → `effect_vbo`, `colormix_a_pos` → `effect_a_pos` (cosmetic rename only, no logic change)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The new type hierarchy and config changes that every user story depends on.
No user story implementation can begin until this phase is complete.

**⚠️ CRITICAL**: All Phase 3, 4, and 5 work is blocked until this phase is done.

- [X] T004 [P] Create `src/render/colormix_shader.zig` — extract `ShaderProgram` from `src/render/shader.zig`, rename struct to `ColormixShader`, move `buildPaletteData()` here; keep all GLSL source, uniforms, VBO setup, `init/bind/setStaticUniforms/setUniforms/draw/deinit` methods identical to current `ShaderProgram`
  - @agent: `specialized/shader-graphics-engineer`
- [X] T005 [P] Update `src/render/colormix.zig` — remove the `ShaderProgram` import (line 4: `const ShaderProgram = @import("shader.zig").ShaderProgram;`) since `ColormixRenderer` no longer owns a shader; fix any remaining references
  - @agent: `language-experts/zig-developer`
- [X] T006 Add `EffectType` enum to `src/config/config.zig`:
  ```zig
  pub const EffectType = enum { colormix, glass_drift };
  ```
  Add `effect_type: EffectType` (default `.colormix`) and `speed: f32` (default `1.0`) to `AppConfig`. Update `defaultConfig()`.
  - @agent: `language-experts/zig-developer`
- [X] T007 Update config parser in `src/config/config.zig` for `effect.name`:
  - Accept `"glass_drift"` → `config.effect_type = .glass_drift`
  - Keep `"colormix"` acceptance unchanged
  - Missing `name` key in `[effect]` section → default `.colormix` + log notice
  - Any other value → `error.UnsupportedEffect` (unchanged behaviour)
  - @agent: `language-experts/zig-developer`
- [X] T008 Update config parser in `src/config/config.zig` for `effect.settings.speed`:
  - Parse as float; validate `0.25 ≤ speed ≤ 2.5`; default `1.0` when absent
  - Out of range or non-float → `error.InvalidValue`
  - Add `"speed"` to `shouldTrackKey` for `effect_settings` section
  - Add config tests: valid speed, speed too low, speed too high, speed missing uses default
  - @agent: `language-experts/zig-developer`
- [X] T009 Create `src/render/glass_drift.zig` — `GlassDriftRenderer` struct with `frames: u64`, `last_advance_ms: u32`, `frame_advance_ms: u32`, `speed: f32`, `phase_offset: f32` (random at init via `std.Random.DefaultPrng`). Implement `init(frame_advance_ms, speed)` and `maybeAdvance(time_ms)` mirroring `ColormixRenderer.maybeAdvance`
  - @agent: `language-experts/zig-developer`
- [X] T010 Create `src/render/effect.zig` — `Effect` tagged union over `EffectType`:
  ```zig
  pub const Effect = union(EffectType) {
      colormix: ColormixRenderer,
      glass_drift: GlassDriftRenderer,
  };
  ```
  Implement: `init(config)`, `maybeAdvance(time_ms)`, `frameCount()`, `speed()`, `isGpuOnly()`, `renderGrid(w, h, out)` (dispatches to colormix; returns early for GPU-only), `paletteData()`, `patternMods()`, `phaseOffset()`
  - @agent: `language-experts/zig-developer`
- [X] T011 Create `src/render/effect_shader.zig` — `EffectShader` tagged union over `EffectType`:
  ```zig
  pub const EffectShader = union(EffectType) {
      colormix: ColormixShader,
      glass_drift: GlassDriftShader,
  };
  ```
  Implement: `init(effect)`, `bind(effect)`, `setStaticUniforms(effect)`, `setUniforms(effect, w, h)` (computes `time = frameCount * TIME_SCALE * speed` internally), `draw()`, `glProgram()`, `glVbo()`, `glAPosLoc()`, `deinit()`
  - @agent: `language-experts/zig-developer`

**Checkpoint**: `zig build` MUST pass before any Phase 3+ work begins. The Effect/EffectShader
unions reference `GlassDriftShader` which is created in Phase 3 — use a forward-compatible
stub (`GlassDriftShader = struct {}`) in T011 until T013 lands.

---

## Phase 3: User Story 1 — Select an Effect via Config (Priority: P1) 🎯 MVP

**Goal**: Config-based effect selection works. Glass Drift renders instead of colormix when
`[effect] name = "glass_drift"` is set. Colormix continues to work identically.

**Independent Test**: Set `[effect] name = "glass_drift"` in `~/.config/wlchroma/config.toml`,
run `zig build run`. Wallpaper should render the Glass Drift layered pane animation. Then set
`name = "colormix"` (or remove the section) and confirm colormix renders unchanged.

### Implementation for User Story 1

- [X] T012 [US1] Create `src/render/glass_drift_shader.zig` — `GlassDriftShader` with GLSL ES 1.00 fragment shader (three sinusoidal pane layers, fixed frosted-glass palette: ice blue `#7BA9CC`, pale silver `#BCC9D8`, deep slate `#4A6B88`). Uniforms: `u_time` (float), `u_resolution` (vec2), `u_phase` (float, static). Vertex shader: identical pass-through to `ColormixShader`. Implement `init/bind(phase_offset)/setStaticUniforms(phase_offset)/setUniforms(time,w,h)/draw/deinit`. Replace the stub from T011.
  - @agent: `specialized/shader-graphics-engineer`
- [X] T013 [US1] Refactor `src/app.zig` — replace `renderer: ColormixRenderer` + `shader: ?ShaderProgram` with `effect: Effect` + `effect_shader: ?EffectShader`. Update `App.init()`: build `Effect.init(&config)`; if `egl_ctx == null` AND `effect.isGpuOnly()`, log warning and override to colormix. Update `App.run()` shader init: `EffectShader.init(&self.effect)` then `effect_shader.bind(&self.effect)`. Update `App.deinit()` to call `effect_shader.deinit()`. Update the render tick call: pass `effect_shader` pointer instead of `shader`.
  - @agent: `language-experts/zig-developer`
- [X] T014 [US1] Refactor `src/wayland/surface_state.zig` — replace `renderer: *ColormixRenderer` with `effect: *Effect`; remove `palette_data: [36]f32` field (absorbed into `ColormixShader`). Update `SurfaceState.create()` signature. Update `renderTick()` EGL path: `sh.setStaticUniforms(self.effect)`, `sh.setUniforms(self.effect, w, h)`, `bs.draw(ofs.tex, sh.glProgram(), sh.glVbo(), sh.glAPosLoc())`. Update SHM path: `self.effect.maybeAdvance(now_ms)`, `self.effect.renderGrid(...)`.
  - @agent: `language-experts/zig-developer`
- [X] T015 [US1] Wire `EffectShader.init/bind/setStaticUniforms/setUniforms/draw` dispatch in `src/render/effect_shader.zig` — replace any stubs with real dispatch to `ColormixShader` and `GlassDriftShader`. Ensure `setUniforms` computes `time = effect.frameCount() * TIME_SCALE * effect.speed()`.
  - @agent: `language-experts/zig-developer`
- [X] T016 [US1] Build verification and smoke test: run `zig build`; confirm zero compile errors. Run `zig build test`; confirm all existing config tests pass. Manually test colormix renders unchanged (no config or `name = "colormix"`).
  - @agent: `quality-assurance/code-reviewer`

**Checkpoint**: US1 fully functional. Glass Drift renders via GPU. Colormix unchanged.
Invalid effect name exits with clear error. `zig build test` green.

---

## Phase 4: User Story 2 — Per-Effect Speed Control (Priority: P2)

**Goal**: `[effect.settings] speed = <value>` scales animation velocity for any active
effect. Default is 1.0. Out-of-range values are rejected at startup.

**Independent Test**: Set `[effect] name = "glass_drift"` and `[effect.settings] speed = 0.5`.
Glass Drift animation runs visibly slower. Change to `speed = 2.0`; animation runs faster.
Remove `speed`; default 1.0 applies. Set `speed = 3.0`; startup error, non-zero exit.

### Implementation for User Story 2

- [X] T017 [US2] Verify `src/config/config.zig` speed parsing from T008 is complete and wired into `AppConfig.speed`. Confirm `Effect.init(&config)` passes `config.speed` into both `ColormixRenderer.init` and `GlassDriftRenderer.init`.
  - @agent: `language-experts/zig-developer`
- [X] T018 [US2] Update `ColormixRenderer.init` in `src/render/colormix.zig` to accept and store `speed: f32`. Update `Effect.speed()` accessor to return the stored value.
  - @agent: `language-experts/zig-developer`
- [X] T019 [US2] Verify `src/render/effect_shader.zig` `setUniforms()` uses `effect.speed()` in time computation: `time = @as(f32, @floatFromInt(effect.frameCount())) * TIME_SCALE * effect.speed()`. Test with colormix + speed 0.5 and glass_drift + speed 2.0 visually.
  - @agent: `specialized/shader-graphics-engineer`
- [X] T020 [US2] Add config tests to `src/config/config.zig` (if not already done in T008): `speed = 0.25` accepted, `speed = 2.5` accepted, `speed = 0.24` rejected, `speed = 2.51` rejected, missing speed defaults to 1.0.
  - @agent: `language-experts/zig-developer`

**Checkpoint**: US1 + US2 both independently functional. Speed applies to both effects.

---

## Phase 5: User Story 3 — Graceful Fallback When GPU Unavailable (Priority: P3)

**Goal**: When EGL fails and glass_drift is selected, wlchroma logs a clear warning, falls
back to colormix on the CPU path, and continues running.

**Independent Test**: Temporarily break EGL init (e.g. run in a headless environment or
rename the EGL lib), set `[effect] name = "glass_drift"`, start wlchroma. Should log
`"effect glass_drift requires GPU; falling back to colormix on CPU path"` and render
colormix via SHM. Colormix with no GPU should continue unchanged.

### Implementation for User Story 3

- [X] T021 [US3] Verify the fallback logic added in T013 (`App.init()`) is correct: when `egl_ctx == null` AND `effect.isGpuOnly()`, the effect is overridden to colormix with the original palette/frame_advance_ms from config, and the warning is logged. Review log message matches spec wording exactly.
  - @agent: `language-experts/zig-developer`
- [X] T022 [US3] Verify `Effect.isGpuOnly()` returns `true` for `.glass_drift` and `false` for `.colormix`. Add any missing case coverage for future GPU-only effects (compiler will enforce exhaustive switch when new tags are added).
  - @agent: `language-experts/zig-developer`
- [X] T023 [US3] Code review of the full effect system refactor across all modified files: `app.zig`, `surface_state.zig`, `effect.zig`, `effect_shader.zig`, `colormix_shader.zig`, `glass_drift.zig`, `glass_drift_shader.zig`, `shader.zig`, `config.zig`. Check for: missing `errdefer`, GL resource leaks on init failure, correct `bound` flag reset, EGL context assumptions.
  - @agent: `quality-assurance/code-reviewer`
- [X] T024 [US3] Performance review of `GlassDriftShader` fragment shader: confirm arithmetic cost is comparable to or lower than colormix (no iterative loops, no texture samples, no sqrt in hot path). Review `maybeAdvance` gate logic in `GlassDriftRenderer`.
  - @agent: `quality-assurance/performance-engineer`

**Checkpoint**: All 3 user stories functional. Full regression: colormix unchanged, glass_drift
renders, speed works, GPU fallback logs and continues.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Documentation, example config, and final hardening.

- [X] T025 [P] Update `README.md` — add `[effect] name` and `[effect.settings] speed` to the "Configuration" section under the v1 config surface list. Document Glass Drift's fixed color palette. Document that speed applies to all effects.
  - @agent: `language-experts/zig-developer`
- [X] T026 [P] Update `config.toml.example` — add `[effect]` section with `name = "colormix"` (commented example of `"glass_drift"`), and `[effect.settings]` with `speed = 1.0` with inline comment explaining the range.
  - @agent: `language-experts/zig-developer`
- [ ] T027 Checkpoint commit: `refactor: scaffold effect system for multiple shaders`
  - @agent: `engineering/git-workflow-master`
- [ ] T028 Checkpoint commit: `feat: add glass drift shader effect`
  - @agent: `engineering/git-workflow-master`
- [ ] T029 Checkpoint commit: `feat: add effect.settings.speed config`
  - @agent: `engineering/git-workflow-master`
- [X] T030 Final hardening pass: run `zig build test`; confirm all tests pass including new speed validation tests. Confirm `zig build` with no config produces colormix at 15fps (constitution Principle II). Confirm quickstart.md add-a-third-effect steps are accurate against the final code.
  - @agent: `quality-assurance/code-reviewer`

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately. T001/T002/T003 are independent.
- **Foundational (Phase 2)**: Depends on Phase 1. T004–T011 can run in parallel groups:
  - Group A (parallel): T004, T005, T006, T009
  - T007, T008 depend on T006 (need `EffectType` and `AppConfig` with new fields)
  - T010 depends on T004, T005, T009 (needs `ColormixRenderer` and `GlassDriftRenderer`)
  - T011 depends on T004, T009 (needs shader types — use stubs for `GlassDriftShader`)
- **User Story 1 (Phase 3)**: Depends on Phase 2 complete. T012–T015 can partially parallel:
  - T012 independent (shader file only)
  - T013 depends on T010, T011
  - T014 depends on T010, T011, T013
  - T015 depends on T012, T011
  - T016 depends on T012–T015
- **User Story 2 (Phase 4)**: Depends on Phase 3. T017–T020 mostly sequential.
- **User Story 3 (Phase 5)**: Depends on Phase 3. T021–T024 can parallel after T013.
- **Polish (Phase 6)**: Depends on Phases 3–5 complete.

### User Story Dependencies

- **US1 (P1)**: No dependency on US2 or US3 — independently testable after Phase 2.
- **US2 (P2)**: Speed parsing (T008) is in Phase 2; wiring (T017–T019) builds on US1.
- **US3 (P3)**: Fallback logic (T021–T022) builds on US1 (T013 already implements it).

### Within Each Phase

- Models/types before services/dispatch
- Compile and build-test after each phase before advancing
- Commit at each checkpoint (T027–T029)

---

## Parallel Execution Examples

### Phase 2 Group A (launch together)

```
Task: "Create src/render/colormix_shader.zig (T004)"
Task: "Update src/render/colormix.zig remove ShaderProgram import (T005)"
Task: "Add EffectType enum and new AppConfig fields in src/config/config.zig (T006)"
Task: "Create src/render/glass_drift.zig GlassDriftRenderer (T009)"
```

### Phase 3 parallel start

```
Task: "Create src/render/glass_drift_shader.zig GLSL shader (T012)"
Task: "Refactor src/app.zig Effect/EffectShader (T013)" — after T010/T011
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (T001–T003)
2. Complete Phase 2: Foundational (T004–T011) — CRITICAL
3. Complete Phase 3: User Story 1 (T012–T016)
4. **STOP and VALIDATE**: `zig build test` passes; Glass Drift renders; colormix unchanged
5. Commit: `refactor: scaffold effect system` + `feat: add glass drift shader effect`

### Incremental Delivery

1. Setup + Foundational → effect system scaffold committed
2. US1 → Glass Drift works → commit + demo
3. US2 → Speed control → commit
4. US3 → Fallback verified → commit
5. Polish → README + example config → final commit, open PR to main

---

## Agent Assignments Summary

| Phase | Tasks | Agent |
|-------|-------|-------|
| Phase 1 | T001–T003 | `language-experts/zig-developer` |
| Phase 2 | T004 | `specialized/shader-graphics-engineer` |
| Phase 2 | T005–T011 | `language-experts/zig-developer` |
| Phase 3 | T012 | `specialized/shader-graphics-engineer` |
| Phase 3 | T013–T015 | `language-experts/zig-developer` |
| Phase 3 | T016 | `quality-assurance/code-reviewer` |
| Phase 4 | T017–T020 | `language-experts/zig-developer` |
| Phase 4 | T019 | `specialized/shader-graphics-engineer` |
| Phase 5 | T021–T022 | `language-experts/zig-developer` |
| Phase 5 | T023 | `quality-assurance/code-reviewer` |
| Phase 5 | T024 | `quality-assurance/performance-engineer` |
| Phase 6 | T025–T026 | `language-experts/zig-developer` |
| Phase 6 | T027–T029 | `engineering/git-workflow-master` |
| Phase 6 | T030 | `quality-assurance/code-reviewer` |

## Notes

- `[P]` tasks = different files, no shared state dependencies
- `[Story]` label maps task to spec user story for traceability
- Each user story is independently completable and testable after Phase 2
- `zig build` must pass at every checkpoint — Zig's exhaustive switch catches missing cases
- The stub pattern (T011 stubs `GlassDriftShader`) allows Phase 2 to compile before T012 lands
- Glass Drift shader visual design can be iterated after T012 — the contract is the uniform interface, not the exact GLSL coefficients
