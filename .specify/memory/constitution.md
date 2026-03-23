<!--
Sync Impact Report
===================
Version change: (none) → 1.0.0
Modified principles: N/A (initial ratification)
Added sections:
  - Core Principles (5): Wayland-Native, Low-Power by Default,
    Graceful Degradation, Minimal Config Surface, Single Binary
  - Technical Constraints
  - Development Workflow
  - Governance
Removed sections: N/A
Templates requiring updates:
  - .specify/templates/plan-template.md ✅ no changes needed
    (Constitution Check section is generic; aligns with principles)
  - .specify/templates/spec-template.md ✅ no changes needed
    (spec structure is project-agnostic)
  - .specify/templates/tasks-template.md ✅ no changes needed
    (task phases are project-agnostic)
Follow-up TODOs: none
-->

# wlchroma Constitution

## Core Principles

### I. Wayland-Native

wlchroma targets Linux Wayland compositors exclusively.
All rendering and surface management MUST use Wayland protocols
(`wl_compositor`, `zwlr_layer_shell_v1`) and MUST NOT introduce
X11, XWayland, or cross-platform abstraction layers.

- The binary MUST link only `wayland-client`, `wayland-egl`,
  `EGL`, and `GLESv2` as system libraries.
- New protocol support (e.g., `ext-layer-shell`) MAY be added
  but MUST NOT replace `zwlr_layer_shell_v1` until the
  replacement is widely adopted.

### II. Low-Power by Default

wlchroma is a background wallpaper daemon, not a benchmark.
Default configuration MUST prioritize modest CPU/GPU usage over
visual fidelity or frame rate.

- The default frame rate MUST remain at or below 15 fps.
- New effects or rendering features MUST NOT raise the default
  resource footprint without explicit justification.
- Render scaling defaults MUST favor reduced GPU work
  (native resolution is opt-in, not the default behavior of
  reduced-scale paths).

### III. Graceful Degradation

When a runtime capability is unavailable, wlchroma MUST fall
back to a working alternative rather than crashing.

- If EGL/GPU initialization fails, the daemon MUST continue
  on the CPU/SHM rendering path.
- Missing or invalid configuration MUST fall back to built-in
  defaults with a clear log message explaining what was ignored.
- GPU-only config knobs (e.g., `renderer.scale`,
  `renderer.upscale_filter`) MUST be silently ignored on the
  SHM fallback path.

### IV. Minimal Configuration Surface

The public configuration API MUST remain small, versioned, and
validated. Features ship with sensible defaults; config exists
only for values users genuinely need to change.

- Config files MUST include a `version` key. Unknown or
  unsupported versions MUST be rejected, not silently accepted.
- New config keys MUST NOT be added without updating the
  documented v1 surface in `README.md`.
- Config is loaded once at startup. Live reload is not
  required and MUST NOT be added without a constitution
  amendment.

### V. Single Binary, Zero Runtime Dependencies

wlchroma ships as one statically-linked Zig executable that
depends only on system-provided shared libraries at runtime.

- The build MUST produce a single `wlchroma` binary with no
  companion files, scripts, or data directories required at
  runtime.
- All protocol XML files MUST be processed at build time via
  `wayland-scanner`; generated code MUST NOT be checked in.
- Third-party Zig packages SHOULD be avoided. If introduced,
  each dependency MUST be justified in the PR description.

## Technical Constraints

- **Language**: Zig (pinned version in CI; currently 0.15.2).
- **Target platform**: Linux with Wayland session.
- **Rendering**: GLES 2.0 shaders via EGL, with CPU/SHM
  fallback.
- **Configuration format**: TOML, version-gated.
- **Multi-monitor**: All outputs share one global config.
  Per-output config is out of scope for v1.
- **Hot-plug**: Outputs connected after startup are not
  covered until restart. This is a known v1 limitation, not a
  bug.

## Development Workflow

- **Hardening before features**: stabilize and harden each
  change before moving to the next feature. The commit history
  pattern of `feat` followed by multiple `fix: harden` commits
  is intentional and MUST be maintained.
- **Config validation is strict**: reject invalid or ambiguous
  config values at startup rather than guessing intent. The
  `renderer.scale` gap (0.95..1.0 rejected) is an example of
  this philosophy.
- **Commit messages**: follow Conventional Commits
  (`feat:`, `fix:`, `refactor:`, `build:`, `docs:`).
- **Branch strategy**: `main` is the release branch; feature
  work happens on topic branches.

## Governance

This constitution is the authoritative source for project
principles and constraints. All feature proposals, PRs, and
design decisions MUST be consistent with the principles above.

- **Amendments**: Any change to a Core Principle requires a
  constitution version bump (MAJOR for removals/redefinitions,
  MINOR for additions, PATCH for clarifications). The amendment
  MUST be documented in the Sync Impact Report comment at the
  top of this file.
- **Compliance review**: Feature specs produced by `/speckit`
  commands MUST pass a Constitution Check (see plan template)
  before implementation begins.
- **Complexity justification**: Deviations from simplicity
  (new dependencies, new protocols, expanded config surface)
  MUST be justified in writing and tracked in the plan's
  Complexity Tracking table.

**Version**: 1.0.0 | **Ratified**: 2026-03-23 | **Last Amended**: 2026-03-23
