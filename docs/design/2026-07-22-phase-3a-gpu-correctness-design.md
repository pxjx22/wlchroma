# Phase 3A GPU Correctness Design

**Date:** 2026-07-22

**Audit scope:** `GPU-M4`, `GPU-M5`, and `GPU-M6` from
[`2026-07-19-security-performance-audit.md`](../security/2026-07-19-security-performance-audit.md)

**Branch:** `phase-3a-gpu-correctness`

## Purpose

Phase 3A makes program-global GPU state explicit and makes permanent GPU
pipeline failure a functional CPU fallback for every effect that has one.
It builds on Phase 2's checked Wayland dimensions and centralized EGL epoch
ownership; it does not replace those mechanisms.

Phase 3 remains divided into three independently reviewed branches:

1. **3A — GPU correctness:** `GPU-M4`, `GPU-M5`, and `GPU-M6`.
2. **3B — Animation and CPU performance:** `RENDER-M1`, `RENDER-L1`, and
   `PERF-L2` through `PERF-L6`.
3. **3C — Reload, configuration, and build modernization:** `APP-L2`,
   `PERF-L1`, `CONF-L1`, and `BUILD-L1`.

All fourteen remaining audit rows will be fixed. No finding is accepted or
deferred by this design.

## Current Problems

### GPU-M4: uploads are attempted without a current context

Palette commands, fade ticks, and same-effect reload update the authoritative
`Effect` and then call shader binding directly. IPC and timer handlers do not
establish an EGL current-context precondition, so those GL calls are invalid
when no surface can currently be made current.

Phase 2 indirectly fixed the narrow zero-output case by closing the final GPU
epoch and rebuilding its shader when an output returns. It did not fix the
broader missing-current-context contract while a shader remains live.

### GPU-M5: shader rebuilds do not initialize all static uniforms

Colormix pattern modifiers are uploaded through a per-surface
`needs_static_uniforms` flag. That flag is set by surface creation and resize,
but not by a program rebuild. Switching from another effect to colormix can
therefore draw with default zero pattern modifiers until a later configure.

The modifiers, phase offset, and palette are program-global state. Tracking
them per surface both models the ownership incorrectly and repeats work on
multi-output setups.

### GPU-M6: colormix shader failure remains a black EGL surface

Permanent shader initialization failure currently converts only GPU-only
effects to SHM colormix. Colormix itself retains an EGL surface with no shader,
and the render path clears that surface to black.

## Goals

- Never issue a Phase 3A GL state upload without a confirmed current context.
- Preserve pending uploads until one EGL surface successfully becomes current.
- Initialize every new shader program completely before its first draw.
- Upload changed program-global state once per change, not once per output.
- Convert permanent colormix pipeline failure into rendered SHM colormix.
- Preserve Phase 2's recoverable zero-output epoch behavior.
- Add no heap allocation, clock syscall, wake-up, or extra context switch to
  the steady-state render path.

## Non-Goals

- Animation phase and speed semantics are Phase 3B.
- CPU grid layout and CPU fallback hot-loop optimization are Phase 3B.
- Asynchronous reload, TOML grammar, and build metadata are Phase 3C.
- No config key, IPC command, response format, or public CLI behavior changes.
- No attempt is made to recover the GPU again after a genuinely permanent
  pipeline failure in the same daemon process.

## Architecture

### 1. App-owned program state

`src/render/gpu_upload_state.zig` defines `GpuUploadState`. `App` owns one
packed, non-allocating value alongside `effect_shader`.
`GpuUploadState` contains three dirty bits:

- `program_binding`: the program's VBO and vertex attribute binding has not
  been established for this shader generation;
- `palette`: the program's palette uniforms do not match `Effect`;
- `static_uniforms`: effect-specific static uniforms do not match `Effect`.

The state contains no GL handles and owns no resource. Closing a GPU epoch
clears the shader and upload state together. Creating a shader generation marks
all three bits dirty.

Palette mutation marks only `palette`. An effect switch constructs a new shader
generation and marks all bits. Resize does not mark program-global state dirty.

### 2. Split shader responsibilities

The current shader `bind` methods conflate program activation, VBO setup,
palette upload, and static-uniform upload. They will be split behind
`EffectShader` into explicit operations:

- `useProgram()` selects the effect program;
- `bindGeometry()` establishes VBO and vertex attribute state;
- `uploadPalette(effect)` uploads only palette data;
- `uploadStatic(effect)` uploads colormix pattern modifiers or the GPU
  effect's phase offset;
- existing per-frame uniform and draw methods remain separate.

When any bit is dirty, `flushIfCurrent` first verifies its confirmed-current
argument and calls `useProgram()`. It then performs only the operations named
by the set bits. Bits clear only after their operations have run with the
context confirmed current.

The blit path must continue restoring the effect program and geometry after its
draw. It does not make palette or static state dirty.

### 3. Flush at the first usable surface

`SurfaceState.renderTick` already calls `makeCurrent` before drawing an EGL
surface. The mutable shader and `GpuUploadState` are passed to `renderTick` for
the duration of that call; `SurfaceState` does not store either pointer.

After `makeCurrent` succeeds and before per-frame uniforms or drawing:

1. inspect the dirty mask;
2. flush the required program-global state;
3. clear the flushed bits;
4. continue the existing draw and swap path.

If a surface is dead, unconfigured, callback-blocked, or cannot become current,
it cannot flush state. The bits remain set and the next eligible surface gets
the opportunity. Once the first surface flushes, every later surface sees a
clean state and performs no upload.

This location reuses the context switch already required for drawing. It does
not add an App-level acquisition pass or a second `makeCurrent` call.

### 4. Mutation flow

Palette commands, fade ticks, and same-effect reload follow one rule:

1. update the authoritative CPU `Effect` value;
2. update App's current-palette bookkeeping;
3. mark the palette bit dirty if a shader generation exists;
4. return or continue without calling GL.

If no shader exists, `Effect` remains authoritative. A later shader generation
starts fully dirty and uploads the latest state.

### 5. Static state and program generations

Per-surface `needs_static_uniforms` is removed. Program creation, not surface
configuration, is the event that invalidates program-global state.

The first draw of every new program generation must observe all three bits set.
Effect switching, zero-output epoch recreation, and output return therefore use
the same initialization path. No surface resize is required to make colormix
pattern modifiers valid.

### 6. Permanent CPU fallback

Permanent pipeline failure uses one idempotent App transition:

1. latch `gpu_pipeline_failed`;
2. detach borrowed GPU pointers and close the GPU epoch using Phase 2's order;
3. if the selected effect is GPU-only, replace it with colormix built from the
   current palette, speed, and frame-advance configuration;
4. if the selected effect is already colormix, retain it;
5. invalidate per-surface CPU stand-ins built from the previous effect;
6. configure every live surface for SHM fallback;
7. leave the frame timer and IPC service operational.

Shader compile/link failure and a startup/switch pass where usable EGL surfaces
exist but none can be made current are permanent failures. The transition must
not leave an EGL surface attached to a null effect shader.

An epoch closed only because there are zero outputs is not a permanent failure.
It does not latch `gpu_pipeline_failed`, change the selected effect, or prevent
GPU recreation when an output returns.

## Error and Ownership Rules

- `GpuUploadState` never owns GL objects and cannot outlive or delete them.
- Pending bits survive failed context acquisition.
- GL calls occur only after the target `EglSurface.makeCurrent` succeeds.
- Epoch closure resets the shader and upload mask in the same ownership step.
- Permanent fallback is safe to call more than once and cannot double-destroy
  EGL, GL, SHM, or Wayland resources.
- GPU-only conversion uses App's authoritative current palette, not possibly
  stale shader uniforms.
- Failure to allocate or configure SHM follows the existing checked cleanup
  path and must not restore a partially destroyed GPU epoch.
- No `.?` unwrap may depend on asynchronous output timing without a preceding
  ownership/state check.

## Performance Contract

The clean steady-state GPU path performs one predictable dirty-mask check per
eligible surface and no upload operation. It performs:

- zero heap allocations;
- zero additional clock syscalls;
- zero additional poll wake-ups;
- zero additional EGL context switches;
- zero repeated palette or static uploads across outputs.

A palette change uploads palette data once on the next usable surface. A shader
generation binds geometry and uploads palette and static data once. Splitting
the shader API prevents the existing duplicated palette/static work.

Phase 3A is expected to be performance-neutral or slightly better. Measurable
CPU fallback and reload improvements remain explicit Phase 3B and 3C goals.

## Automated Verification

### Pure state and ordering tests

`tests/wayland_egl/gpu_upload_state_test.zig` uses an operations-driven seam to
record context and upload events. Tests require:

- clean state performs no operation;
- palette mutation sets only `palette`;
- program creation sets all three bits;
- no-current flush performs no GL-like operation and preserves every bit;
- a current flush orders `useProgram` before required uploads;
- a partial mask performs only its named operations;
- a successful flush clears exactly the completed bits;
- two surface attempts after one mutation upload on the first current surface
  and perform no upload on the second.

### App and Wayland/EGL adapter tests

`tests/wayland_egl/gpu_fallback_test.zig` and the existing lifecycle adapters
require:

- palette mutation while no context is current remains pending;
- output return or the next current surface consumes the latest palette once;
- switching a live GPU effect to colormix marks the new program fully dirty;
- the first colormix draw uploads pattern modifiers without a resize;
- permanent colormix shader failure closes the GPU epoch and configures SHM;
- permanent GPU-only shader failure converts to current-palette colormix and
  configures SHM;
- zero-output closure does not latch permanent failure and output return can
  create a fresh fully dirty shader generation;
- repeated permanent-fallback requests do not double-release resources.

### Commands

At minimum, Phase 3A closeout runs:

```sh
zig fmt --check build.zig src tests
git diff --check
zig build test-wayland-egl --summary all
zig build test --summary all
zig test src/config/config.zig
zig build -Doptimize=ReleaseSafe --summary all
zig build test -Doptimize=ReleaseSafe --summary all
zig build -Doptimize=ReleaseFast --summary all
zig build test -Doptimize=ReleaseFast --summary all
```

The full test graphs must run with normal local Unix-domain socket syscalls;
restricted-sandbox IPC failures are environmental evidence, not passing tests.

## Live Niri Acceptance

Live tests use an isolated ReleaseSafe daemon and preserve the user's normal
daemon for restoration afterward.

1. Start with a GPU-only effect and verify normal animated rendering.
2. Switch to colormix without resizing and verify its normal non-default
   animated pattern appears immediately.
3. Arm an independent output-recovery watchdog, remove the last output, change
   the palette while output-less, restore the output, and verify the newest
   palette renders.
4. Build with `-Dphase3a-force-shader-init-failure=true`. This default-off,
   build-time-only hook fails effect-shader initialization before publishing a
   shader and changes no normal binary behavior. Run colormix and verify visible
   animated SHM output rather than a black EGL surface.
5. Query IPC and inspect the journal for retry loops, repeated uploads, EGL
   errors, ownership warnings, allocator failures, or resource-growth messages.
6. Stop the isolated daemon through its exact IPC endpoint and restore the
   original daemon and output state.

If a second output is available, the palette and effect-switch tests run across
both outputs and verify one program-state upload per mutation. If only one
output exists, the missing hardware acceptance is recorded without claiming it
passed; the multi-output upload count remains covered by deterministic tests.

## Review and Completion

Every implementation task receives an independent requirements and code-quality
review. Critical and Important findings are fixed and re-reviewed before the
next task. Minor findings are recorded for the final whole-branch reviewer and
either fixed or explicitly dispositioned before merge.

Phase 3A is complete only when `GPU-M4`, `GPU-M5`, and `GPU-M6` have committed
regressions, the full optimization-mode matrix passes, live acceptance passes,
the audit ledger records exact commits and evidence, and the final independent
review approves the branch.
