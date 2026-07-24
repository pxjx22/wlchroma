# AGENTS.md — wlchroma

Animated, palette-driven Wayland wallpaper daemon in Zig. One build produces two binaries: `wlchroma` (daemon, entry `src/main.zig` → `src/app.zig`) and `wlchroma-ctl` (IPC client, entry `src/ctl/main.zig`).

Committed guidance: `README.md` (user-visible behavior), `CONTRIBUTING.md` (process), `AI_CONTRIBUTING.md` (agent rules). Read those first; this file only adds what they miss or what is easy to get wrong.

## Build and test

- `zig build` — both binaries to `zig-out/bin/`
- `zig test src/config/config.zig` — config parser tests.
- `zig build test` — full local suite (unit + IPC + wayland_egl + effect + color_fade). CI runs this via `.github/workflows/test.yml`; run locally before claiming work is done.
- `zig build test-ipc`, `zig build test-wayland-egl` — focused subsets.
- `zig build run` — build + run the daemon (needs a live Wayland session).
- Fault injection for shader-init failure paths: `zig build -Dphase3a-force-shader-init-failure=true`.

## Toolchain gotchas

- Zig is pinned to **0.16.0** (`.zig-version`, CI). `build.zig.zon` claims a lower minimum — ignore that; use the pin. Do not upgrade without a deliberate decision.
- The code uses Zig 0.16 std APIs: `pub fn main(init: std.process.Init)`, `init.gpa`, `init.io`, `init.minimal.args`. Patterns from ≤0.15 (manual GeneralPurposeAllocator setup, `std.process.args()`) will not compile — copy existing style.
- `wayland-scanner` generates C bindings from `protocols/*.xml` at build time (into the zig cache). `protocols/` holds vendored upstream XML only — don't hand-edit it, never commit generated C.
- System deps: dev packages for `wayland-client`, `wayland-egl`, `EGL`, `GLESv2`, plus `wayland-scanner`.

## Test architecture (non-obvious)

Tests under `tests/` are out-of-tree and cannot import `src/` files by relative path. They import shim modules rooted at `src/`:

- `src/test_exports.zig` → imported as `wlchroma_src` (render/wayland/config internals)
- `src/test_ipc_exports.zig` → imported as `dispatch` / `ipc` (IPC internals + `sys`)
- `src/test_wayland_exports.zig` → imported as `wayland_test` (links real Wayland/EGL C libraries)

Adding a test file means adding a module + step in `build.zig`, and exporting any new module-under-test from the right shim. `src/sys.zig` is a raw-syscall shim shared by the daemon and test modules.

## Specs and source of truth

- `specs/` (001–010) and `CLAUDE.md` are gitignored, maintainer-local working copies. In clones without them, README + CONTRIBUTING + AI_CONTRIBUTING are the whole contract.
- When `specs/` is present (as here): read the relevant `specs/<nnn>-<feature>/` before changing config schema, CLI/`wlchroma-ctl` commands, IPC protocol, user-visible runtime behavior, or renderer/fallback behavior — and update the spec in the same change.
- README parity: update `README.md` in the same commit for config keys, ctl commands, IPC behavior, requirements, or limitations.

## Verification honesty

Wayland rendering, IPC socket behavior, and GPU fallback **cannot be verified by CI** — they need a live Wayland session (niri/sway). For changes touching those paths, state the manual steps that would verify them and don't claim completeness without running them. On a live session, `scripts/cycle-effects.sh` (rewrites config + `wlchroma-ctl reload`) is a quick smoke test; the socket protocol is scriptable via `socat - UNIX-CONNECT:"$XDG_RUNTIME_DIR/wlchroma.sock"`.

## Conventions

- Commits: `<type>(<scope>): <description>` — types `feat`/`fix`/`test`/`docs`/`refactor`, scopes `ipc`/`ctl`/`config`/`renderer`/`build`/`repo`.
- Effects follow a naming pair: thin `<name>.zig` wrapper + `<name>_shader.zig` (GLSL). `colormix` is the CPU/SHM fallback effect; all others need the GPU path.
- Minimal, atomic diffs. No refactors mixed with behavior changes. No speculative docs for unimplemented behavior.
