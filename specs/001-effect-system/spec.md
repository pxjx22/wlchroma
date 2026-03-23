# Feature Specification: Effect System & Multi-Shader Support

**Feature Branch**: `001-effect-system`
**Created**: 2026-03-23
**Status**: Draft
**Input**: User description: "I want to start adding other shaders will need an effect system so can change in the config, was almost complete on a glass drift one but had to revert back because i was using a cheap model that broke it. there was a list of 10 effects somewhere but im not sure if they were lost when i reverted to an old commit"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Select an Effect via Config (Priority: P1)

A user who wants a different visual style than the default colormix animation edits their
`config.toml`, sets `[effect] name = "glass_drift"`, and restarts wlchroma. The wallpaper
now renders the Glass Drift animation instead of colormix, with no other changes required.

**Why this priority**: This is the core deliverable. Without config-based effect selection,
no other effects can be shipped. Glass Drift is the first new effect and the most developed;
finishing it validates the whole effect system.

**Independent Test**: Set `[effect] name = "glass_drift"` in config, restart wlchroma, and
visually confirm the wallpaper renders the Glass Drift animation instead of colormix.
Delivers a second usable wallpaper mode as a standalone MVP.

**Acceptance Scenarios**:

1. **Given** a valid `config.toml` with `[effect] name = "glass_drift"`, **When** wlchroma
   starts, **Then** the Glass Drift animation is rendered on all outputs.
2. **Given** a valid `config.toml` with `[effect] name = "colormix"` (or no `[effect]`
   section at all), **When** wlchroma starts, **Then** the original colormix animation
   renders unchanged.
3. **Given** a `config.toml` with `[effect] name = "unknown_effect"`, **When** wlchroma
   starts, **Then** the daemon logs a clear error naming the bad value and exits
   rather than silently rendering the wrong effect.

---

### User Story 2 - Per-Effect Speed Control (Priority: P2)

A user editing their config can set an animation speed multiplier under `[effect.settings]`
to slow down or speed up whichever effect is active. Settings from one effect do not bleed
into another.

**Why this priority**: Each effect will have its own tunable parameters. Establishing
per-effect config grouping now prevents config surface pollution as more effects are added.
Speed control is the first shared setting needed across all effects.

**Independent Test**: Set `[effect.settings] speed = 0.5` with Glass Drift selected;
confirm the animation runs at half speed. Set `speed = 2.0`; confirm it runs faster.
Removing the setting reverts to default speed of 1.0.

**Acceptance Scenarios**:

1. **Given** Glass Drift selected and `[effect.settings] speed = 0.5`, **When** wlchroma
   runs, **Then** the animation visibly moves at half the default pace.
2. **Given** Glass Drift selected and `[effect.settings] speed = 2.5` (maximum), **When**
   wlchroma runs, **Then** the animation runs at 2.5x default pace without crashing.
3. **Given** `speed` is not set in config, **When** wlchroma runs, **Then** animation
   uses a default multiplier of 1.0.
4. **Given** colormix is selected instead of Glass Drift, **When** `speed` is set,
   **Then** the multiplier applies to colormix equally (speed is a cross-effect setting).

---

### User Story 3 - Graceful Fallback When GPU Unavailable (Priority: P3)

When the GPU renderer is unavailable and wlchroma falls back to the CPU rendering path,
a user who has selected a GPU-only effect sees an informative log message and the daemon
continues running on the fallback path with colormix, rather than crashing.

**Why this priority**: Consistent with the project's graceful degradation principle.
GPU-only effects cannot render without a GPU; this story defines the fallback so wlchroma
remains always-on regardless of hardware.

**Independent Test**: Force the CPU fallback path, set Glass Drift in config, start
wlchroma. Daemon should continue running, log a warning that Glass Drift requires GPU and
fell back, and render colormix instead.

**Acceptance Scenarios**:

1. **Given** Glass Drift is selected and the GPU renderer is unavailable, **When** wlchroma
   starts, **Then** the daemon logs that Glass Drift requires GPU, falls back to colormix
   on the CPU path, and continues running.
2. **Given** colormix is selected and the GPU renderer is unavailable, **When** wlchroma
   starts, **Then** colormix renders normally on the CPU path (unchanged behavior).

---

### Edge Cases

- An effect name with a valid format but a typo (e.g., `"glassdrift"` instead of
  `"glass_drift"`) MUST be rejected with an error that names the unrecognized value.
- A `speed` value outside the 0.25–2.5 range MUST be rejected at startup with an error;
  the daemon MUST NOT silently clamp or ignore it.
- An `[effect]` section present in config but missing the `name` key MUST default to
  `colormix` and log a notice explaining the fallback.
- Per-effect settings under `[effect.settings]` MUST NOT collide with top-level config
  keys such as `fps` or `[renderer]` settings.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The daemon MUST support selecting an effect by name via `[effect] name`
  in `config.toml`, defaulting to `"colormix"` when the key is absent.
- **FR-002**: The daemon MUST reject any unrecognized effect name at startup with a clear
  error message that names the invalid value and exits non-zero.
- **FR-003**: The effect system MUST ship with Glass Drift as the second effect after
  colormix, rendering a layered translucent color-pane animation.
- **FR-004**: A shared `speed` multiplier MUST be supported via `[effect.settings]`,
  accepting values in the range 0.25–2.5, defaulting to 1.0 when absent.
- **FR-005**: The daemon MUST reject a `speed` value outside the 0.25–2.5 range at
  startup with an error; silent clamping is not acceptable.
- **FR-006**: All effects other than colormix MUST be GPU-only; the CPU path continues
  to render colormix only.
- **FR-007**: When a GPU-only effect is selected but GPU rendering is unavailable, the
  daemon MUST log a warning, fall back to colormix on the CPU path, and continue running.
- **FR-008**: The existing colormix effect MUST continue to work identically after the
  refactor, including its palette, fps, and render-scale settings.
- **FR-009**: The effect architecture MUST isolate each effect's state and GPU pipeline
  such that adding a future effect does not require modifying existing effect files.
- **FR-010**: The public config surface for this feature (effect name, effect settings)
  MUST be documented in `README.md` as part of the v1 config surface.

### Key Entities

- **Effect**: A named visual shader mode (e.g., `colormix`, `glass_drift`). Has a name,
  renderer state, and a set of configurable settings. Selected once at startup via config.
- **Effect Settings**: Per-effect tunable parameters grouped under `[effect.settings]`
  in config. `speed` (0.25–2.5, default 1.0) is the first shared setting.
- **Effect Shader**: The GPU pipeline for a specific effect — shader source, uniforms,
  draw call. Isolated per effect; not shared between effects.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A user can change the active effect by editing one line in `config.toml`
  and restarting; no other files or steps are required.
- **SC-002**: Glass Drift runs at 15 fps on the same hardware that runs colormix at
  15 fps with no measurable increase in CPU or GPU temperature at idle.
- **SC-003**: An invalid effect name in config produces a startup error within 1 second
  that names the bad value — no silent fallback, no crash without a message.
- **SC-004**: All existing colormix behavior (palette, fps, render scale, multi-output,
  CPU fallback) passes regression testing unchanged after the effect system refactor.
- **SC-005**: Adding a third effect in the future requires only one new file and one
  registration entry — no changes to existing effect files.

## Assumptions

- The effect-system scaffolding that was partially built in a prior session was reverted
  and is NOT present in the current repo. Implementation starts from the clean main state.
- The 10 planned effects are: Glass Drift, Aurora Bands, Cloud Chamber, Ribbon Orbit,
  Plasma Quilt, Liquid Marble, Velvet Mesh, Soft Interference, Starfield Fog, Tube Lights.
  This spec covers only the effect system scaffold and Glass Drift. The remaining 9
  effects are out of scope for this feature branch.
- Config is loaded once at startup. Live config reload is out of scope and unchanged.
- The `speed` multiplier is a shared cross-effect setting. Per-effect exclusive settings
  (if any) are deferred to individual future effect specs.
- Glass Drift is GPU-only and does not need a CPU/SHM rendering mode.
