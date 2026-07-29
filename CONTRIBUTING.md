# Contributing to wlchroma

`wlchroma` is a small, opinionated Zig/Wayland project. The best contributions here are narrow, tested, and documented.

## Before You Start

- Read `README.md` first.
- Confirm your change fits the project scope: Linux + Wayland only, with `zwlr_layer_shell_v1` (`wlr-layer-shell`) available from the compositor.
- For larger feature work, open an issue first. Feature contracts are tracked in maintainer-side spec documents that are not part of the public tree, and an issue is how your idea gets aligned with them before you invest in code.

## Repository Layout

- `src/`: application and CLI source
- `tests/`: focused tests
- `protocols/`: Wayland protocol XML and generated inputs

## Prerequisites

- Zig `0.16.0`
- `wayland-scanner`
- Development libraries for `wayland-client`, `wayland-egl`, `EGL`, and `GLESv2`

If you need setup details, use the environment notes in `README.md` as the source of truth.

## Build And Test

Run the same checks that CI runs:

```bash
zig build
zig test src/config/config.zig
```

If your change touches other code paths, run the narrowest additional check that proves the behavior you changed.

For runtime changes, include manual verification notes in your PR. Mention the compositor and session you tested against when that matters.

## Feature Work And Specs

Small bug fixes and doc fixes can usually go straight to code.

If your change adds a feature, changes config surface, changes CLI or IPC behavior, or changes a user-visible workflow, start by describing the intended behavior in an issue or your PR description: what changes, the exact config/CLI/IPC surface affected, and how to verify it. The maintainer tracks numbered feature specs outside the public tree and will align your proposal with them during review.

Keep feature work incremental. Avoid mixing refactors with behavior changes unless the refactor is required for the change.

## Documentation Expectations

Update `README.md` in the same change when you modify:

- requirements or setup steps
- config schema or examples
- CLI flags or `wlchroma-ctl` commands
- runtime control behavior
- limitations or fallback behavior

Keep examples copy-pasteable and match them to shipped behavior.

## Code And Review Expectations

- Keep diffs small and focused.
- Preserve current behavior unless the change intentionally updates it.
- Do not silently change config compatibility or IPC semantics.
- Prefer explicit verification over broad claims like "tested locally".

## Commits And Pull Requests

Use this commit format:

```text
<type>(<scope>): <description>
```

Types: `feat`, `fix`, `test`, `docs`, `refactor`, `perf`, `bench`.
Use `bench` for benchmark harness/evidence commits and `perf` for retained
production performance changes.

Common scopes: `ipc`, `ctl`, `config`, `renderer`, `build`, `repo`

Examples:

```text
feat(ipc): add runtime palette switching command
fix(config): reject duplicate named palettes
docs(repo): add contribution guides
```

In your PR description, include:

- what changed
- why it changed
- the exact commands you used to verify it
- any README or spec updates included in the change

## AI-Assisted Contributions

AI-assisted changes are fine, but the submitter is still responsible for correctness, scope control, and documentation.

If you used an AI agent:

- review the diff before submitting it
- run the relevant checks yourself
- do not claim tests passed unless you actually ran them
- update docs and specs when the change affects public behavior

`AI_CONTRIBUTING.md` adds repo-specific guidance for agent-driven changes, but `CONTRIBUTING.md` remains the canonical public guide.
