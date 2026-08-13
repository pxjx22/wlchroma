# wlchroma Security and Performance Audit

**Audit date:** 2026-07-19

**Baseline:** `ba3715e` (`main`)

**Toolchain:** Zig 0.16.0

**Scope:** `src/main.zig`, `src/app.zig`, `src/sys.zig`, IPC, configuration, Wayland integration, EGL/GLES rendering, SHM fallback, and their tests.

## Purpose

This document is the master remediation ledger for the July 2026 security and performance audit. Line references describe the baseline commit above and may move as fixes land. A finding is complete only when it has a recorded disposition and verification evidence.

Allowed dispositions are:

- **Fixed:** implementation and regression tests are committed and verified.
- **Consolidated:** a broader root-cause fix closes this finding, with the relationship recorded here.
- **Accepted risk:** the behavior remains only after explicit maintainer approval and a documented rationale.

No finding may be silently removed or deferred. The remediation program is complete when every row is `Fixed`, `Consolidated`, or an explicitly approved `Accepted risk`.

## Executive Summary

The audit found four high-severity issues: two same-user IPC availability attacks, one stale EGL-context lifetime, and unchecked compositor dimensions crossing into C APIs. It also found GPU-resource leaks across hotplug/failure paths, several rendering-state correctness bugs, protocol robustness gaps, and CPU fallback optimization opportunities.

The intended Wayland userdata architecture is otherwise sound: `App` settles before listener registration, output and surface state are heap allocated, listener vtables have static lifetime, and surface teardown precedes output destruction. The configuration parser is bounded and did not expose an out-of-bounds access or malformed-input memory corruption path.

## Remediation Phases

1. **IPC hardening:** `IPC-H1`, `IPC-H2`, `IPC-M1`, `IPC-L1`, `IPC-L2`, `IPC-L3`, and `APP-L1`. Design: [`2026-07-19-ipc-hardening-design.md`](../design/2026-07-19-ipc-hardening-design.md). Plan: [`2026-07-19-phase-1-ipc-hardening.md`](../superpowers/plans/2026-07-19-phase-1-ipc-hardening.md).
2. **Wayland/EGL safety:** `WL-H1`, `WL-H2`, `GPU-M1`, `GPU-M2`, `GPU-M3`, and `WL-L1`.
3. **Rendering, configuration, and modernization:** all remaining `GPU`, `RENDER`, `APP`, `PERF`, `CONF`, and `BUILD` findings.

Each phase receives its own approved design, TDD implementation plan, focused commits, and full Debug/ReleaseSafe/ReleaseFast verification.

## Finding Ledger

| ID | Severity | Phase | Finding | Status |
|---|---|---:|---|---|
| IPC-H1 | High | 1 | Client-triggered `SIGPIPE` can terminate the daemon | Fixed (`4d4fd3e`, `49a82b5`) |
| IPC-H2 | High | 1 | Per-read timeout permits slow-client main-thread starvation | Fixed (`a50a8c8`, `a44845a`, `4d4fd3e`, `49a82b5`) |
| IPC-M1 | Medium | 1 | A second daemon can steal and later remove the live socket path | Fixed (`a44845a`, `49a82b5`) |
| IPC-L1 | Low | 1 | Response writes do not handle partial success | Fixed (`a50a8c8`, `4d4fd3e`, `49a82b5`) |
| IPC-L2 | Low | 1 | The documented 4096-byte line boundary is off by one | Fixed (`a50a8c8`, `49a82b5`) |
| IPC-L3 | Low | 1 | No-argument commands accept ignored trailing arguments | Fixed (`f4fcb58`) |
| APP-L1 | Low | 1 | Signalfd data is read from an undefined buffer without validating read length | Fixed (`18d7cec`, `49a82b5`) |
| WL-H1 | High | 2 | GPU fallback can leave a stale borrowed EGL-context pointer | Fixed (`d13bcc0`, `376cea0`) |
| WL-H2 | High | 2 | Compositor dimensions reach C APIs without checked narrowing | Fixed (`51b29d6`, `90ac27e`) |
| GPU-M1 | Medium | 2 | Zero-output effect switching leaks shader programs and VBOs | Fixed (`d13bcc0`, `cfa7809`) |
| GPU-M2 | Medium | 2 | Failed `makeCurrent` paths lose offscreen FBO and texture ownership | Fixed (`d13bcc0`, `cfa7809`) |
| GPU-M3 | Medium | 2 | EGL cleanup can destroy a current surface or issue GL calls without a context | Fixed (`b8ffaaf`, `366e2c1`, `d13bcc0`) |
| WL-L1 | Low | 2 | A bound `wl_output` proxy leaks if `OutputInfo` allocation fails | Fixed (`77e3bd3`) |
| GPU-M4 | Medium | 3 | Palette uploads can be lost when no EGL context is current | Fixed (`510eddf`, `43e6f36`) |
| GPU-M5 | Medium | 3 | Switching to colormix leaves pattern uniforms at defaults | Fixed (`f164387`, `43e6f36`) |
| GPU-M6 | Medium | 3 | Colormix shader failure produces a black EGL surface instead of SHM fallback | Fixed (`a145eb7`, `85b7ce5`, `d9cdb26`) |
| RENDER-M1 | Medium | 3 | Runtime speed changes jump GPU phase and CPU colormix ignores speed | Fixed (`6fda05c`, `76af09d`, `3628bb7`, `c0b4bd8`, `0b916bc`) |
| RENDER-L1 | Low | 3 | `renderGrid` relies on callers to provide an exact output length | Fixed (`3295002`) |
| APP-L2 | Low | 3 | Reload silently ignores `timerfd_settime` failure | Fixed |
| PERF-L1 | Low | 3 | Reload performs synchronous file I/O and two parser passes on the render loop | Fixed |
| PERF-L2 | Low | 3 | CPU fallback resolves and updates its effect twice per frame | Fixed (`7bd7cb8`) |
| PERF-L3 | Low | 3 | CPU fallback reads the monotonic clock separately for every output | Fixed (`3628bb7`) |
| PERF-L4 | Low | 3 | Colormix repeats invariant integer conversions inside the inner loop | Fixed (`88fa502`) |
| PERF-L5 | Low | 3 | Column-major cells create strided reads during framebuffer expansion | Fixed (`88fa502`) |
| PERF-L6 | Low | 3 | Ever-growing frame counts lose `f32` animation precision after long uptime | Fixed (`6fda05c`, `76af09d`, `3628bb7`) |
| CONF-L1 | Low | 3 | The custom TOML parser accepts a documented subset but does not define escape semantics | Fixed |
| BUILD-L1 | Low | 3 | `build.zig.zon` still declares Zig 0.15.2 | Fixed |

## High-Severity Findings

### IPC-H1: Client-triggered SIGPIPE termination

`src/ipc/server.zig:109` writes responses through raw `writev`, while `src/sys.zig:48` supplies neither `MSG_NOSIGNAL` nor a process-wide SIGPIPE policy. A client can send a complete command and close its receive side before the response. Linux may deliver SIGPIPE before Zig error handling sees `EPIPE`.

**Impact:** same-user daemon termination. The normal XDG runtime directory limits the practical attacker to the current user, but the trigger is trivial.

**Required remediation:** use nonblocking `send`/`sendmsg` with `MSG_NOSIGNAL`, preserve `EPIPE`, and track partial response progress.

### IPC-H2: Slow-client starvation of the Wayland/render thread

`src/app.zig:593` accepts and reads a client synchronously. `src/ipc/server.zig:71` applies a 200 ms per-read timeout, while `readLine` at line 86 performs repeated reads. A byte arriving just before each timeout resets the effective wait. The 4097-byte call-site buffer permits roughly 13.6 minutes of continuous main-thread occupation per connection.

**Impact:** rendering, Wayland event dispatch, hotplug, signal handling, and all other IPC are delayed or frozen.

**Required remediation:** nonblocking client state in the poll loop plus an absolute monotonic request deadline. Failure to establish the safety mechanism must close the client rather than fall back to an unbounded read.

### WL-H1: Stale EGL-context pointer after fallback

`src/wayland/surface_state.zig:336` returns early for a zero-sized surface before clearing the borrowed `egl_ctx` pointer at line 356. `src/app.zig:646` can then deinitialize the shared context and set the owning optional to null. A later configure event may dereference the stale pointer.

**Impact:** use-after-deinit semantics, invalid EGL calls, a black surface, or driver/process failure.

**Required remediation:** invalidate every borrowed context pointer before destroying the shared context, regardless of surface size or configured state.

### WL-H2: Unchecked compositor dimensions and arithmetic

Layer-shell configure width and height are protocol `uint` values. `src/render/egl_surface.zig:26` and line 49 narrow them to C integers with `@intCast`. `src/wayland/shm_pool.zig:16` multiplies stride, height, and buffer count before checking the result.

**Impact:** safe-build traps and ReleaseFast illegal behavior from a buggy or malicious compositor. No code-execution exploit was demonstrated.

**Required remediation:** validate protocol dimensions against every downstream ABI, use checked multiplication, and store the checked SHM total size for teardown.

## Medium-Severity Findings

### IPC-M1: Live socket path can be stolen

`src/ipc/server.zig:38` unlinks the path before bind, and teardown unlinks it again. A second daemon can make the first unreachable; either process can later delete the other's path.

**Required remediation:** hold an advisory lock for the daemon lifetime. Only the lock owner may remove stale socket state, bind, or unlink during shutdown.

### GPU-M1 and GPU-M2: Deferred GL resources lose ownership

`src/app.zig:381` clears an effect shader without deleting it when no surface can be made current. `src/wayland/surface_state.zig:240` and line 323 similarly discard offscreen handles after `makeCurrent` failure. The EGL context remains alive across hotplug, so repeated cycles accumulate driver resources.

**Required remediation:** retain deferred-deletion records and retire them when any compatible surface next makes the shared context current, or explicitly recreate the context at zero outputs.

### GPU-M3: Inconsistent current-context cleanup

`forceCpuFallback` can destroy an EGL surface while it remains current. Application shutdown stops after the first failed `makeCurrent` attempt and may then issue GL deletion calls without a current context.

**Required remediation:** centralize current-context acquisition and surface destruction, try every usable surface, and gate GL calls on confirmed context ownership.

### GPU-M4 and GPU-M5: Runtime GPU state can be stale

Palette-changing handlers call shader binding without first obtaining a current context. When no output exists, uploads are lost. Separately, effect switching does not mark existing surfaces' static uniforms dirty, so switching to colormix can leave pattern uniforms at zero until resize.

**Required remediation:** introduce explicit GPU dirty state, upload only with a current context, and invalidate static uniforms after every shader rebuild.

### GPU-M6: Colormix shader failure is not a functional fallback

Shader initialization failure latches the GPU pipeline as failed, but only GPU-only effects are converted to SHM. Colormix retains an EGL surface with no shader and renders black.

**Required remediation:** pipeline failure must move every effect with a CPU implementation to SHM, including colormix.

### RENDER-M1: Speed semantics diverge

GPU time is computed from total frames multiplied by the current speed, so changing speed jumps accumulated phase. CPU colormix does not use its speed field.

**Required remediation:** maintain accumulated animation phase and advance future deltas at the active speed. CPU and GPU must consume the same semantics.

## Low-Severity and Performance Findings

- **IPC-L1:** one `writev` ignores a short successful write.
- **IPC-L2:** `LINE_MAX` says the newline is included, while the caller provides `LINE_MAX + 1` bytes.
- **IPC-L3:** `reload`, `query`, and `stop` ignore extra arguments.
- **APP-L1:** signalfd read errors/short reads still leave undefined bytes interpreted as a signal number.
- **WL-L1:** a successfully bound output proxy is not released if the following heap allocation fails.
- **APP-L2:** reload updates reported FPS even if the timer reconfiguration failed.
- **RENDER-L1:** `ColormixRenderer.renderGrid` writes `grid_w * grid_h` elements without validating the checked product against `out.len`; live callers currently provide the expected slice.
- **PERF-L1:** reload does bounded but synchronous file I/O and parsing on the render loop.
- **PERF-L2:** GPU-only SHM stand-ins rebuild palette state twice per frame.
- **PERF-L3:** each CPU-rendered output makes its own clock syscall.
- **PERF-L4:** grid dimensions and integer conversions are recomputed inside the hot cell loop.
- **PERF-L5:** column-major cells are consumed with strided access during row-oriented expansion.
- **PERF-L6:** direct `u64` frame-to-`f32` conversion loses unit precision after 16,777,216 frames, roughly 13 days at 15 FPS.
- **CONF-L1:** the bounded parser is memory-safe in scope but needs explicit subset/escape documentation or replacement with a maintained parser.
- **BUILD-L1:** project metadata must name the actual Zig 0.16.0 minimum.

## Validated Safe Areas

- `App.init` registers no listener. `main` places the returned value in its final stack slot before `App.setup` registers callbacks.
- `OutputInfo` and `SurfaceState` are heap allocated before their addresses become listener userdata. `ArrayList` growth moves pointer slots, not the pointed-to objects.
- Registry, output, layer-surface, frame-callback, and buffer listener vtables have static lifetime.
- Surfaces are destroyed before their owning outputs, and callback userdata is not freed inside Wayland dispatch.
- Normal SHM initialization failure closes the fd, unmaps memory, and destroys already-created proxies.
- Configuration input is limited to 64 KiB; palette and string collections are fixed-size or bounded.
- Configuration integer and float parsing fails closed; scale validation rejects non-finite values.
- `parseHexColor` validates length before indexing.
- IPC union payload access follows active-tag checks.
- No ordinary GPU or CPU per-frame heap allocation was found.

## Baseline Verification

- `zig build --summary all`: 9/9 steps passed.
- `zig build test --summary all`: 54/54 tests passed.
- ReleaseSafe build and tests passed.
- ReleaseFast build and tests passed.
- `zig fmt --check build.zig src tests` passed.
- The worktree was clean at audit completion.

Live output-off/hotplug fault injection was not performed during the read-only audit. Any later zero-output testing must arm a recovery watchdog before disabling an output.

## Completion Record

Update the finding ledger and append phase verification evidence as fixes land. Do not rewrite the original finding descriptions; they are the stable audit baseline.

### Phase 1: IPC hardening — 2026-07-20

- **Disposition:** `IPC-H1`, `IPC-H2`, `IPC-M1`, `IPC-L1`, `IPC-L2`, `IPC-L3`, and `APP-L1` are fixed. Their original descriptions remain unchanged in the ledger.
- **Implementation commits:** `f4fcb58` (strict no-argument arity), `a50a8c8` (bounded framing/response/deadline primitives), `a44845a` (singleton lock and nonblocking listener), `4d4fd3e` (nonblocking SIGPIPE-safe client I/O), `18d7cec` (exact signalfd record reader), and `49a82b5` (main poll-loop integration and legacy-path removal).
- **Formatting:** `zig fmt --check build.zig src tests` exited zero.
- **Debug:** executable build `9/9`; full test graph `19/19`, `89/89` tests passed.
- **ReleaseSafe:** executable build `9/9`; full test graph `19/19`, `89/89` tests passed.
- **ReleaseFast:** executable build `9/9`; full test graph `19/19`, `89/89` tests passed.
- **Static evidence:** `git diff --check` passed; the legacy IPC scan found no `readLine`, `writeLine`, `writev`, `LINE_MAX`, `SO_RCVTIMEO`, direct dispatch writer, or fd-taking command handler.
- **Review evidence:** Tasks 1–5 passed read-only implementation reviews; Task 4 also passed a separate adversarial I/O audit. Two independent Task 6 review attempts terminated at the provider usage limit, so the controller completed a documented line-by-line fallback review of the 1,211-line package with no Critical, Important, or Minor findings.
- **Live scope:** no daemon was running after the laptop reboot, so the optional existing-daemon `wlchroma-ctl query` smoke test was skipped. No daemon was started, stopped, or replaced, and no display was disabled.

### Phase 2: Wayland/EGL safety — 2026-07-20 to 2026-07-22

- **Disposition:** `WL-H1`, `WL-H2`, `GPU-M1`, `GPU-M2`, `GPU-M3`, and `WL-L1` are fixed. Their original descriptions remain unchanged in the ledger.
- **Implementation commits:** `51b29d6` (checked protocol extents and SHM layout), `90ac27e` (validated compositor-dimension consumers and transactional SHM replacement), `77e3bd3` (transactional output registration), `b8ffaaf` (driver-independent GPU epoch orchestration), `102776a` (lifecycle coverage strengthening), `366e2c1` (confirmed EGL current ownership), `d13bcc0` (centralized GPU detachment and epoch teardown), `376cea0` (safe null-context last-surface retirement), `cfa7809` (recoverable hotplug epochs and transactional filter replacement), and `0060d08` (active/permanent epoch hot-path short-circuiting).
- **Focused verification:** `zig build test-wayland-egl --summary all` passed `13/13` steps and `41/41` tests. The suite covers checked dimensions/SHM arithmetic, transactional output publication, App-level CPU-only last-surface retirement, GPU epoch state/ordering, and replacement ownership transfer.
- **Formatting and static evidence:** `zig fmt --check build.zig src tests` and `git diff --check` exited zero. The ownership-loss scan found no `orphan`, `offscreen FBO leaked`, `GL cleanup may be incomplete`, or `dropOffscreenForFilterChange` path. The compositor-narrowing scan found only the two intentional `Extent.init` casts after explicit nonzero and `maxInt(i32)` validation.
- **Debug:** executable build `9/9`; host full graph `27/27`, `130/130` tests passed; all `48/48` direct configuration-parser tests passed.
- **ReleaseSafe:** executable build `9/9`; host full graph `27/27`, `130/130` tests passed.
- **ReleaseFast:** executable build `9/9`; host full graph `27/27`, `130/130` tests passed without overflow- or UB-sensitive failures.
- **Sandbox note:** each full graph under restricted socket syscalls reproduced only the known 11 environmental IPC failures (`2` signalfd, `5` connection, `4` server); the identical host-syscall runs passed all tests. No IPC code changed in Phase 2.
- **Review evidence:** every implementation task passed an independent read-only review. Review found one Important null-context retirement defect and one required Minor hot-path scan; both received focused RED/GREEN regressions in `376cea0` and `0060d08` and passed re-review. The EGL teardown review confirmed that a failed best-effort unbind does not immediately destroy a current EGL surface because EGL defers actual destruction until the surface is no longer current.
- **Live environment:** Niri `26.04` on `eDP-1` at `1920x1200`, scale `1.0`. This session exposed no secondary output, so survivor rendering during a non-primary unplug could not be exercised; the complete-output-loss path was exercised twice instead.
- **Live rendering:** an isolated ReleaseSafe daemon (PID `17817`) rendered colormix and the GPU-only `glass_drift` effect; screenshots recorded both modes. A nearest-to-linear filter reload and renderer-scale change from `0.20` to `0.50` completed without errors. Temporarily changing Niri output scale from `1.0` to `1.1` produced a checked EGL reconfigure at `1745x1091`; restoring scale `1.0` returned to `1920x1200` while the same daemon stayed responsive.
- **Zero-output recovery:** a user-systemd recovery command using the explicit current `NIRI_SOCKET` and absolute `/usr/sbin/niri` path was dry-run while the display remained enabled. During output loss, wlchroma reaped the surface and disarmed the frame timer; an output-less reload selected `glass_drift` without converting it to CPU colormix. The first 20-second watchdog fired just before Niri completed its delayed off transition, so the later off won that test-harness race and the display was restored manually. A corrected 30-second independent watchdog then restored `eDP-1` automatically. The same PID survived, IPC still reported `glass_drift`, and the journal recorded a fresh EGL 1.5/ES2 context, surface, and armed timer after output return.
- **Shutdown and restoration:** the exact test daemon stopped through IPC; its transient unit became inactive with no stale-pointer, resource-loss, EGL, or allocator warning in the journal. The user's original main-checkout daemon was restored under user-systemd as PID `34684` with the normal colormix, 24 FPS, scale `0.20` configuration. The display remained enabled at scale `1.0`; the lock screen required normal local unlock after display power cycling.

### Phase 3A: GPU correctness — 2026-07-22

- **Disposition:** `GPU-M4`, `GPU-M5`, and `GPU-M6` are fixed. Their original descriptions remain unchanged in the ledger.
- **Implementation commits:** `510eddf` (one-byte App-owned GPU upload dirty state), `f164387` (split shader program, geometry, palette, and static operations), `43e6f36` (deferred current-context-safe uploads), `a145eb7` (idempotent permanent-fallback model), `85b7ce5` (centralized App fallback transition), and `d9cdb26` (default-off pre-GL shader-init fault injection). Final review's three stale API comments were corrected in `c6cd74c`.
- **Focused/config verification:** `zig build test-wayland-egl --summary all` passed `25/25` steps and `62/62` tests; all `48/48` direct configuration-parser tests passed.
- **Debug:** executable build `10/10`; host full graph `39/39`, `155/155` tests passed. The restricted full graph first reproduced only the known 11 environmental local-socket denials (`144/155`); the identical host-socket run passed all tests.
- **ReleaseSafe:** executable build `10/10`; host full graph `39/39`, `155/155` tests passed.
- **ReleaseFast:** executable build `10/10`; host full graph `39/39`, `155/155` tests passed without overflow-, optional-, union-, or undefined-behavior-sensitive failure.
- **Static evidence:** `zig fmt --check build.zig src tests` and `git diff --check` exited zero. No production `needs_static_uniforms`, `setStaticUniforms`, `forceCpuFallbackForGpuOnly`, or `requiresCpuFallback` path remains; the exact source-and-test scan reports only two negative regression assertions for removed declarations. The only `gpu_pipeline_failed = true` assignment is inside `latchPermanentGpuFailure`. The build-time shader failure option defaults false and is checked before `EffectShader` dispatches to any leaf initializer.
- **Review evidence:** Tasks 1-6 each passed independent read-only review with no findings. Whole-branch review from `4822791` through `d9cdb26` found no Critical or Important issue and three Minor stale comments; `c6cd74c` corrected all three. Re-review of `c6cd74c` approved the branch with no remaining Critical, Important, or Minor finding.
- **Live environment and safety:** Niri `26.04 (8ed0da4)` exposed only `eDP-1` at `1920x1200 @ 60.026 Hz`, scale `1`, through `/run/user/1000/niri.wayland-1.1745.sock`. An independent user-systemd recovery command using that explicit socket and absolute `/usr/bin/niri` binary was dry-run successfully before output-off. Because inspection consumed the first timer's delay, a fresh 45-second backup was armed and confirmed active; it restored the display after Niri's delayed off transition.
- **Normal live acceptance:** isolated ReleaseSafe PID `277387` started the GPU-only `glass_drift` effect on EGL through `/tmp/wlchroma-phase3a-live.DiiEpl/wlchroma.sock`, then reloaded to `colormix` on the same PID without a resize/configure event while IPC remained responsive. With `eDP-1` confirmed disabled and the frame timer disarmed, `set-colors` applied `#00FF44/#3300FF/#FF7700`; watchdog restoration created a fresh EGL context/surface and re-armed the timer on the same PID, whose post-return queries remained responsive. The complete normal journal scan found no upload, retry, stale-ownership, allocation, warning, EGL, or makeCurrent failure line.
- **Forced-failure live acceptance:** isolated fault PID `283830` selected `colormix`, logged `error.Phase3aForcedShaderInitFailure` exactly once, then configured SHM exactly once at `1920x1200 grid=192x75`. Its fd table contained `wlchroma-shm` and no `/dev/dri` descriptor, directly evidencing the closed EGL epoch and SHM ownership rather than a retained black EGL clear path. Three IPC queries across multiple ticks succeeded; no retry, resource, ownership, allocation, makeCurrent, or additional EGL failure appeared.
- **Live limitations:** desktop screenshot capture was rejected by the approval layer because it could expose unrelated on-screen content, so visible two-frame difference, immediate colormix pattern, post-watchdog palette pixels, and forced-SHM non-black pixels are not claimed. Only one physical output was available, so live multi-output rendering and upload counting were unavailable; deterministic tests cover first-current-surface consumption and second-clean-surface behavior.
- **Shutdown, restoration, and cleanup:** both isolated daemons stopped through their exact temporary IPC socket. The user's exact original executable `/home/px/wlchroma/zig-out/bin/wlchroma`, no-argument config resolution, `/home/px` cwd, `/run/user/1000/wlchroma.sock`, and `wlchroma-session-restore.service` were restored as PID `286879`; query returned colormix, 24 FPS, scale `0.20`, custom palette. The original config SHA-256 remained `052350188d4e83ef694ac39edb6762394b4f77fc650a00d69219c1e2f9ff8aa1`, `eDP-1` returned to its original mode and scale, all test/recovery units were collected, and the temporary runtime/config were removed.

### Phase 3B: Animation and CPU performance — 2026-07-22 to 2026-07-27

- **Disposition:** `RENDER-M1`, `RENDER-L1`, `PERF-L2`, `PERF-L3`, `PERF-L4`, `PERF-L5`, and `PERF-L6` are fixed. Their original descriptions remain unchanged in the ledger.
- **Implementation commits:** `f0a8a90` added the allocation-free ReleaseFast CPU benchmark; `6fda05c` and `76af09d` added bounded, maximum-`u64`-safe shared animation state; `3628bb7`, `c0b4bd8`, and `0b916bc` made App timerfd expirations authoritative while preserving fallback continuity; `7bd7cb8` made CPU stand-in resolution change-driven; `3295002` added checked typed grid/SHM layouts; and `88fa502` made the grid row-major, cached the blended palette, and hoisted invariant work. The optional row-linear framebuffer candidate failed its benchmark gate, was fully removed, and has no commit.
- **Structural evidence:** one accepted exact timerfd record produces one global `AnimationState.advance` call and zero animation clock reads. Every surface borrows the same App-owned `f64` phase. Normal no-fade ReleaseSafe/ReleaseFast ticks make zero render-path clock samples; Debug telemetry deliberately makes two, and an active fade makes one. Each SHM render or configure operation resolves its CPU effect once. An established GPU-only stand-in rebuilds its palette zero times when stable and once when changed; first construction rebuilds once. Checked layouts validate products and exact slice lengths before writing, and row-major production/consumption plus cached palette conversion removes the audited inner-loop work without adding per-frame allocation.
- **Static evidence:** removed timing and column-major forms have no production match; the two `CpuStandin.resolve` sites are exactly the SHM render/configure helpers; renderer/Wayland tick paths contain no animation clock read. `zig fmt --check build.zig bench src tests`, `git diff --check`, and the meaningful whole-range `git diff --check 5bdc843` exited zero. Whole-branch review had found one terminal blank line that the earlier bare clean-worktree check could not inspect; the closeout change removes it and corrects that evidence boundary.
- **Automated verification:** Debug install passed `10/10` steps; focused Wayland/EGL passed `27/27` steps and `70/70` tests; the Debug full graph passed `53/53` steps and `202/202` tests; direct config parsing passed `46/46` tests. ReleaseSafe and ReleaseFast each passed a `10/10` install and a `53/53`, `202/202` full graph. Aggregate evidence is `216/216` reported build steps and `722/722` test executions.
- **Benchmark method:** the benchmark modules run ReleaseFast with three warm-up batches, nine measured batches, 16 frames per batch, and all allocations outside timing. The baseline command, run twice, was `ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3b-bench-base zig build bench-cpu`; the retained Task 6 command was `ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3b-bench-head zig build bench-cpu`. Positive nominal change below means the retained Task 6 invocation was faster than the arithmetic midpoint of the two baseline invocation medians. The midpoint is transparent comparison evidence, not a statistical confidence claim.

| Case | Phase | Baseline 1 ns | Baseline 2 ns | Midpoint ns | Task 6 ns | Change | Checksum |
|---|---|---:|---:|---:|---:|---:|---|
| 1920x1200-1 | grid | 26,204,929 | 24,826,119 | 25,515,524.0 | 24,887,230 | +2.4624% | `60dc464a322602f8` |
| 1920x1200-1 | expand | 26,680,130 | 26,402,441 | 26,541,285.5 | 29,675,218 | -11.8078% | `159d1fe211803e25` |
| 1920x1200-1 | combined-stable | 54,279,024 | 55,010,823 | 54,644,923.5 | 52,688,474 | +3.5803% | `159d1fe211803e25` |
| 1920x1200-1 | combined-changing | 53,958,243 | 56,229,626 | 55,093,934.5 | 66,596,570 | -20.8782% | `161cbca554f44d65` |
| 1920x1200-2 | grid | 53,470,261 | 52,413,699 | 52,941,980.0 | 49,741,913 | +6.0445% | `f0df5948e95856c5` |
| 1920x1200-2 | expand | 55,824,825 | 58,659,828 | 57,242,326.5 | 60,709,034 | -6.0562% | `3c5ada8a05de5925` |
| 1920x1200-2 | combined-stable | 113,109,825 | 115,251,234 | 114,180,529.5 | 114,413,592 | -0.2041% | `3c5ada8a05de5925` |
| 1920x1200-2 | combined-changing | 113,168,214 | 110,782,429 | 111,975,321.5 | 115,265,266 | -2.9381% | `7f9df58238c106a5` |
| 2560x1440-1 | grid | 42,448,512 | 45,333,453 | 43,890,982.5 | 37,813,953 | +13.8457% | `b148206e5b384440` |
| 2560x1440-1 | expand | 45,881,359 | 47,868,348 | 46,874,853.5 | 48,794,834 | -4.0960% | `c2cefabf9f905c25` |
| 2560x1440-1 | combined-stable | 89,556,427 | 94,206,121 | 91,881,274.0 | 90,803,872 | +1.1726% | `c2cefabf9f905c25` |
| 2560x1440-1 | combined-changing | 89,738,573 | 93,111,775 | 91,425,174.0 | 88,364,724 | +3.3475% | `a39f82258c9b2de5` |
| 2560x1440-2 | grid | 84,380,617 | 86,886,527 | 85,633,572.0 | 76,859,388 | +10.2462% | `9dffe745f60b33f1` |
| 2560x1440-2 | expand | 93,646,970 | 100,108,979 | 96,877,974.5 | 102,529,565 | -5.8337% | `8aa8fc2d82fe9525` |
| 2560x1440-2 | combined-stable | 183,321,011 | 192,559,287 | 187,940,149.0 | 184,298,749 | +1.9375% | `8aa8fc2d82fe9525` |
| 2560x1440-2 | combined-changing | 184,861,433 | 192,649,591 | 188,755,512.0 | 179,740,755 | +4.7759% | `fa66637d705ef7a5` |
| 3840x2160-1 | grid | 97,831,661 | 97,687,227 | 97,759,444.0 | 89,060,506 | +8.8983% | `40e37f5192cecd83` |
| 3840x2160-1 | expand | 93,696,837 | 107,517,830 | 100,607,333.5 | 110,887,050 | -10.2177% | `adb87702b24cb725` |
| 3840x2160-1 | combined-stable | 201,595,024 | 209,220,382 | 205,407,703.0 | 197,782,404 | +3.7123% | `adb87702b24cb725` |
| 3840x2160-1 | combined-changing | 201,885,914 | 205,241,165 | 203,563,539.5 | 198,796,464 | +2.3418% | `b94c0977f04020a5` |
| 3840x2160-2 | grid | 190,832,038 | 197,222,041 | 194,027,039.5 | 178,714,543 | +7.8919% | `3af178037c9269b1` |
| 3840x2160-2 | expand | 215,371,039 | 223,606,253 | 219,488,646.0 | 215,466,524 | +1.8325% | `772f44f448774b25` |
| 3840x2160-2 | combined-stable | 410,343,977 | 418,364,776 | 414,354,376.5 | 438,357,702 | -5.7929% | `772f44f448774b25` |
| 3840x2160-2 | combined-changing | 406,285,909 | 418,081,638 | 412,183,773.5 | 386,398,884 | +6.2557% | `868ffb15a13be425` |

- **Retained benchmark interpretation:** all six grid workloads improved nominally by `+2.4624%` to `+13.8457%`; expansion ranged from `-11.8078%` to `+1.8325%`; combined-stable ranged from `-5.7929%` to `+3.7123%`; and combined-changing ranged from `-20.8782%` to `+6.2557%`. All 24 retained checksums matched the baseline exactly, which is deterministic output-equivalence evidence. The two baseline runs had a `3.8398%` mean pairwise relative spread and `13.7376%` maximum spread under the `powersave` governor, so these timings do not prove a general wall-clock speedup.
- **Optional Task 7 gate:** three fresh retained-head runs and three row-linear candidate runs used separate caches; every one of the six invocations produced all 24 labels, all 144 checksums matched, and no timed allocation was introduced. Positive change below means the candidate median-of-three invocation medians was faster.

| Case | Phase | Retained median ns | Candidate median ns | Change | Checksum |
|---|---|---:|---:|---:|---|
| 1920x1200-1 | grid | 40,893,000 | 31,278,942 | +23.5103% | `60dc464a322602f8` |
| 1920x1200-1 | expand | 48,113,209 | 41,513,981 | +13.7160% | `159d1fe211803e25` |
| 1920x1200-1 | combined-stable | 76,939,088 | 68,654,290 | +10.7680% | `159d1fe211803e25` |
| 1920x1200-1 | combined-changing | 82,757,339 | 73,692,378 | +10.9537% | `161cbca554f44d65` |
| 1920x1200-2 | grid | 70,637,232 | 65,327,436 | +7.5170% | `f0df5948e95856c5` |
| 1920x1200-2 | expand | 83,640,640 | 89,507,790 | -7.0147% | `3c5ada8a05de5925` |
| 1920x1200-2 | combined-stable | 149,218,936 | 140,915,870 | +5.5644% | `3c5ada8a05de5925` |
| 1920x1200-2 | combined-changing | 128,045,241 | 140,377,875 | -9.6315% | `7f9df58238c106a5` |
| 2560x1440-1 | grid | 40,192,087 | 47,941,568 | -19.2811% | `b148206e5b384440` |
| 2560x1440-1 | expand | 51,977,370 | 57,710,962 | -11.0309% | `c2cefabf9f905c25` |
| 2560x1440-1 | combined-stable | 109,517,202 | 120,193,564 | -9.7486% | `c2cefabf9f905c25` |
| 2560x1440-1 | combined-changing | 103,891,817 | 112,009,631 | -7.8137% | `a39f82258c9b2de5` |
| 2560x1440-2 | grid | 107,623,401 | 115,759,060 | -7.5594% | `9dffe745f60b33f1` |
| 2560x1440-2 | expand | 114,628,056 | 144,834,772 | -26.3519% | `8aa8fc2d82fe9525` |
| 2560x1440-2 | combined-stable | 227,459,522 | 264,518,805 | -16.2927% | `8aa8fc2d82fe9525` |
| 2560x1440-2 | combined-changing | 195,290,173 | 236,585,512 | -21.1456% | `fa66637d705ef7a5` |
| 3840x2160-1 | grid | 93,831,799 | 128,742,177 | -37.2053% | `40e37f5192cecd83` |
| 3840x2160-1 | expand | 169,665,466 | 142,663,900 | +15.9146% | `adb87702b24cb725` |
| 3840x2160-1 | combined-stable | 239,175,321 | 246,388,453 | -3.0158% | `adb87702b24cb725` |
| 3840x2160-1 | combined-changing | 226,586,818 | 253,985,232 | -12.0918% | `b94c0977f04020a5` |
| 3840x2160-2 | grid | 211,218,875 | 241,317,513 | -14.2500% | `3af178037c9269b1` |
| 3840x2160-2 | expand | 273,525,083 | 296,535,674 | -8.4126% | `772f44f448774b25` |
| 3840x2160-2 | combined-stable | 551,759,241 | 585,522,737 | -6.1192% | `772f44f448774b25` |
| 3840x2160-2 | combined-changing | 523,253,207 | 644,155,169 | -23.1058% | `868ffb15a13be425` |

- **Task 7 decision:** only `1920x1200-1` improved at least 3% in both combined modes; nine of 12 combined observations regressed by more than 2%. The candidate failed both retention conditions and was removed. Large movement in unaffected grid measurements, including `-37.2053%`, further demonstrates environmental noise but does not justify weakening the gate.
- **Final retained-head consistency run:** `ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3b-bench-task8 zig build bench-cpu` produced every label once, every nonzero median below, and 24/24 checksums matching the retained head. These timings are a consistency sample, not another performance denominator.

| Case | Phase | Final median ns | Checksum |
|---|---|---:|---|
| 1920x1200-1 | grid | 26,239,507 | `60dc464a322602f8` |
| 1920x1200-1 | expand | 28,660,535 | `159d1fe211803e25` |
| 1920x1200-1 | combined-stable | 55,391,301 | `159d1fe211803e25` |
| 1920x1200-1 | combined-changing | 52,137,213 | `161cbca554f44d65` |
| 1920x1200-2 | grid | 49,113,390 | `f0df5948e95856c5` |
| 1920x1200-2 | expand | 60,551,833 | `3c5ada8a05de5925` |
| 1920x1200-2 | combined-stable | 109,945,425 | `3c5ada8a05de5925` |
| 1920x1200-2 | combined-changing | 106,650,900 | `7f9df58238c106a5` |
| 2560x1440-1 | grid | 41,652,866 | `b148206e5b384440` |
| 2560x1440-1 | expand | 54,446,569 | `c2cefabf9f905c25` |
| 2560x1440-1 | combined-stable | 89,988,442 | `c2cefabf9f905c25` |
| 2560x1440-1 | combined-changing | 91,534,716 | `a39f82258c9b2de5` |
| 2560x1440-2 | grid | 78,589,181 | `9dffe745f60b33f1` |
| 2560x1440-2 | expand | 97,345,048 | `8aa8fc2d82fe9525` |
| 2560x1440-2 | combined-stable | 178,466,378 | `8aa8fc2d82fe9525` |
| 2560x1440-2 | combined-changing | 178,202,590 | `fa66637d705ef7a5` |
| 3840x2160-1 | grid | 89,352,967 | `40e37f5192cecd83` |
| 3840x2160-1 | expand | 111,658,280 | `adb87702b24cb725` |
| 3840x2160-1 | combined-stable | 197,103,664 | `adb87702b24cb725` |
| 3840x2160-1 | combined-changing | 197,270,866 | `b94c0977f04020a5` |
| 3840x2160-2 | grid | 184,153,732 | `3af178037c9269b1` |
| 3840x2160-2 | expand | 227,611,853 | `772f44f448774b25` |
| 3840x2160-2 | combined-stable | 420,668,620 | `772f44f448774b25` |
| 3840x2160-2 | combined-changing | 420,594,466 | `868ffb15a13be425` |

- **Review evidence:** independent whole-branch review covered the approved design/plan, source and lifetime paths, `5bdc843` through `88fa502`, task reports, arithmetic through `u64::max`, error/resource paths, matrices, benchmarks, live evidence, and the audit mappings. After the documentation-evidence fix above, it approved the branch with no remaining Critical, Important, or Minor finding and authorized exactly these seven Fixed dispositions.
- **Live environment:** Niri on `cairn`, with the only connected output `eDP-1` at `1920x1200@60.026`, scale 1. The isolated normal ReleaseSafe daemon created EGL 1.5/ES2 and a `glass_drift` surface, then accepted a same-effect speed 0.25 to 2.5 reload on the same PID with responsive IPC and no EGL, layout, ownership, allocation, timer-read, or retry warning. The isolated forced-failure build injected exactly one shader-init failure, permanently selected native colormix, configured 192x75 SHM, accepted the same speed sequence without retry, and stayed warning-free through 1024x768, 1920x1080, and restored 1920x1200 configurations.
- **Output-loss evidence:** while output-less, the daemon reaped its surface, disarmed the timer, remained IPC-responsive, and accepted palette/speed mutations. Approval latency let the pre-armed 10-second recovery service fire before the separately approved output-off command, so automatic watchdog return is not claimed. Manual execution of the identical recovery command restored the output and exercised output recreation, SHM configure, and timer re-arm without a product failure; the test was not repeated.
- **Restoration:** the exact original main-checkout executable, no-argument config lookup, `/home/px` cwd, socket, and Niri launch behavior were restored as PID `205048`. Query returned `effect=colormix`, `fps=24`, `scale=0.20`, `palette=custom`; the config SHA-256 remained `052350188d4e83ef694ac39edb6762394b4f77fc650a00d69219c1e2f9ff8aa1`; `eDP-1` returned to its original mode/scale; `mpris-chroma.service` was active; and isolated config/build artifacts were removed. The user subsequently confirmed the restored wallpaper looked correct.
- **Live limitations:** IPC exposes neither speed nor phase, so live phase continuity and acceleration remain deterministic-test claims rather than instrumented measurements. The forced-failure route selects native colormix and therefore cannot prove GPU-only stand-in rebuild counts. No screenshot or pixel inspection was performed, so live edge-fill claims remain automated-test-only. Only one output was available, so simultaneous multi-output phase sharing was not tested on hardware. Separate audit ideas concerning cross-compositor behavior, partial damage, viewporter use, refresh clamping, opacity, and shader constant hoists remain future work and do not weaken these seven closures.

### Phase 3C: Transactional, asynchronous configuration reload — 2026-07-29 to 2026-08-03

- **Disposition:** `APP-L2`, `PERF-L1`, `CONF-L1`, and `BUILD-L1` are fixed. Their original descriptions remain unchanged in the ledger.
- **Implementation and fix commits:** `4ad86a5` aligned the repository Zig policy and pin; `13e7a64` rejected unsupported recognized-string escapes; `3ec12f2` made config document parsing one-pass; `02ec50d` made timer application transactional; `52fe7ca` normalized one-FPS timer intervals; `4b56c65` added pollable reload jobs; `795a947` kept runtime IPC responsive during reload; `5a5fba8` validated reload-client service; `ddc8e7f` documented strict asynchronous reload; and final remediation `85d6ea1` corrected the UTF-8-byte diagnostic, added parser/service-join regressions, and hardened failing-allocator fixture cleanup. The ignored maintainer contracts were also updated to distinguish missing default and explicit config paths.
- **Policy and static evidence:** Zig 0.16.0 was checked against `.zig-version`, `build.zig.zon`, every Zig-using workflow, and maintainer/user documentation. The Phase 3C delay and timer-failure controls default off and are referenced only in reload/worker code, with no normal render or no-reload allocation, wake, or clock work. `zig fmt --check build.zig bench src tests` and committed-range `git diff --check` passed. The fixed-string one-pass probe found exactly one config document line iterator at `src/config/config.zig:338`; `loadConfigFullRequireFile` has no match in `src/app.zig`.
- **Automated verification:** Before the final documentation/test remediation, direct config parsing passed `57/57`; focused reload passed `39/40` and focused Wayland/EGL passed `96/97`, each with the intentional default-off fault-test skip. At `ddc8e7f`, every unrestricted full matrix completed with exit zero: Debug, ReleaseSafe, and ReleaseFast each passed `57/57` steps and `241/242` tests, with that one intentional skip. Final remediation `85d6ea1` passed config parsing `58/58`; default focused reload `40/41` with one expected skip; timer-failure-enabled focused reload `41/41`; and the host-syscall full graph `242/243` with one expected skip. The restricted sandbox reproduces only the established eleven Unix-socket bind/send/SIGPIPE environmental failures; the host-syscall full result is the applicable full-suite evidence.
- **Live normal, delay, disconnect, busy, and stop evidence:** An isolated ReleaseSafe normal daemon applied a reload to `glass_drift`, 30 FPS, scale 0.50, with the supplied speed, palette data, and filter consumed; invalid escape, malformed `fps = 0`, and missing explicit-file reloads returned errors without changing the before/after query. With the 1500 ms delay seam, an unrelated query returned the prior snapshot in 2 ms, a concurrent reload returned `error: reload already in progress`, and the first reload completed in 1516 ms. Disconnecting the first client did not cancel its job, which applied `lumen_tunnel` at 20 FPS and scale 0.30. `stop` was accepted in 3 ms during a delayed load; the reload client received an error and the daemon exited after 1541 ms, evidencing join-safe teardown. No allocator, ownership, eventfd, timer, EGL, or stale-completion warning was observed. The 2 ms query is evidence that reload I/O/parsing did not occupy the poll/render thread, not a broad render-throughput claim.
- **Timer-failure and zero-output evidence:** The isolated timer-failure build returned `timerfd_settime failed`; its query remained byte-for-byte `effect=colormix`, `fps=24`, `scale=0.20`, `palette=custom`, and a later ordinary `set-fps 20` succeeded. After explicit approval, a separately armed and verified 15-second `eDP-1` recovery unit protected the zero-output stage. With the sole output disabled, query remained responsive; a reload stored `glass_drift`, 1 FPS, scale 0.50; after explicit re-enable the same snapshot remained active and timerfd reported `it_interval: (1, 0)`, proving the stored normalized interval was armed. The recovery timer and service were confirmed inactive after restoration.
- **Review evidence:** Two independent whole-branch reviews covered the approved design/plan, all four audit mappings, publication ordering/address stability, ownership/error/shutdown paths, aggregate deadlines/notification fallback/stop precedence/zero-output behavior, parser compatibility and one-pass evidence, default-off build overhead, documentation parity, live limits, and restoration. The requirements review initially found one Important contract mismatch and one Minor diagnostic issue; the code-quality review found three Minors (diagnostic, service-owned join coverage, and failing-fixture cleanup). The ignored maintainer contracts separately resolved the explicit/default-path mismatch; `85d6ea1` resolved the three tracked diagnostic/test-quality findings with targeted RED/GREEN proof. The independent scoped re-review of `ddc8e7f..85d6ea1` found all findings addressed, no new Critical/Important breakage, a clean diff, and passing focused parser/reload checks.
- **Restoration:** The exact original executable `/home/px/wlchroma/zig-out/bin/wlchroma`, argv, `/home/px` cwd, original config hash `ad4e6b1f9360e1a81879f5ba0d53a2b8608bcf8d0cae067ec14c7d7fde17118c`, `/run/user/1000/wlchroma.sock`, `colormix`/24 FPS/0.20/custom query, and active `mpris-chroma.service` were restored. `eDP-1` returned to 1920x1200 at 60.026 Hz, scale 1, normal transform, logical position 0,0, with VRR disabled; both recovery units were inactive.
- **Limitations and pending external gate:** IPC does not expose speed, filter, or palette bytes, and no screenshot or instrumented visual trace was recorded, so live speed/filter/palette visual assertions are source and deterministic-test claims. Only one physical output was available. Remote GitHub CI remains a required pre-merge gate and has not yet been evaluated; it is not represented as passed here.

### Phase 4: Callback-aware frame pacing — 2026-08-05 to 2026-08-06

- **Disposition and audit mapping:** Efficiency Audit 2 item 2.1 is Fixed: callback-blocked surfaces no longer keep a periodic frame timer firing. Efficiency Audit 3 item 3.3 is Fixed by callback-led absolute pacing without compositor refresh metadata or a refresh-rate clamp; the requested FPS remains the query-visible source of truth. Efficiency Audit 2 item 2.2 was already fixed before this phase and was deliberately not reimplemented.
- **Implementation and review:** Range `c33a1ec..88c7a09` added the absolute frame schedule and readiness aggregation, made timerfd mode explicit, switched application pacing to callback-aware absolute deadlines, paused the outputless schedule, made deadline publication transactional with timer setup, and removed recovery polling for unready surfaces. Tasks 1–4 completed their review rounds cleanly. Task 5 then incorporated three review-driven corrections in `8f2bb72`, `c6f41b3`, and `88c7a09`; the final scoped review found no open Important issue. The final whole-branch review found only a missing callback-boundary integration proof and two stale comments. `7c8480f` added that real-handler regression and corrected both comments; its scoped re-review found all three addressed with no new Critical or Important issue.
- **Final automated verification:** At `88c7a09`, Zig 0.16.0, `zig fmt --check build.zig bench src tests`, and `git diff --check` passed. Direct config parsing passed `58/58`. Debug focused Wayland/EGL passed `130/131` with one intentional skip, and the Debug, ReleaseSafe, and ReleaseFast full host-syscall graphs each passed `283/284` with that same skip. After the final callback-boundary test, exact `7c8480f` again passed formatting, config `58/58`, focused Wayland/EGL, and all three full optimization graphs. The first remote Test run exposed an internally inconsistent assertion in the new test: service at 130 ns after a 120 ns deadline advances one tick and retains deadline 140, so phase `0.01`, not `0.02`. Test-only commit `7550634` corrected that hand-derived expectation; the focused CI-seed replay, direct config tests, and full host-syscall graph passed locally before push.
- **Thirty-second live `/proc` comparison:** ReleaseSafe runs used the same sole `eDP-1` output at 1920x1200@60.026. Counts are endpoint deltas; `u/s` are process user/system CPU ticks, `v/nv` are voluntary/nonvoluntary context switches, and `rchar/syscr` are read bytes/calls.

| Build/path | FPS | u/s | v/nv | rchar/syscr | Timer observation |
|---|---:|---:|---:|---:|---|
| Baseline `8ffc2fa6`, GPU | 15 | 5/12 | 2016/50 | 3600/450 | periodic 66,666,666 ns |
| Candidate `88c7a09`, GPU | 15 | 4/12 | 1816/19 | 3600/450 | absolute one-shot; zero interval |
| Baseline `8ffc2fa6`, GPU | 240 | 14/33 | 14369/48 | 57648/7206 | periodic 4,166,666 ns |
| Candidate `88c7a09`, GPU | 240 | 21/21 | 7200/82 | 0/0 | disarmed at endpoints |
| Candidate `88c7a09`, forced SHM | 15 | 193/2 | 923/220 | 3600/450 | absolute one-shot; zero interval |
| Candidate `88c7a09`, forced SHM | 240 | 797/7 | 3600/825 | 0/0 | disarmed at endpoints |

- **Live interpretation and limits:** At 240 FPS the GPU candidate reduced the observed voluntary-switch/read proxy from 14,369 switches, 7,206 reads, and 57,648 read bytes to 7,200, zero, and zero; total CPU ticks were 47 versus 42. These are single-run `/proc` wake/read proxies, not a timerfd trace, GPU/package-power reading, energy result, or battery-life claim; `perf` and `strace` were unavailable and were not installed. Forced SHM proved the callback-aware behavior on the CPU fallback but had no baseline comparator. Four-second 240 FPS captures contained 241 baseline frames and 240 candidate frames over slightly different durations, so they are only qualitative no-stall evidence, not a cadence benchmark.
- **Pure zero-output and recovery gate:** With `eDP-1` disabled for about 30 seconds, the candidate remained query-responsive and the output stayed disabled at both endpoints. Timerfd showed flags `01`, ticks `0`, `it_value=(0,0)`, and `it_interval=(0,0)` at both checks. `/proc` moved from `utime/stime=231/256`, `v/nv=49767/691`, `rchar/syscr=677235/11375` to `231/256`, `49768/691`, and `677241/11376`: deltas `0/0`, `1/0`, and `6/1`. The single read falls in the window containing the required ending query and cannot be attributed without a trace, but there was no recurring wake/read pattern. The pre-armed `/usr/bin/niri msg output eDP-1 on` watchdog restored the output automatically and the candidate recreated its EGL surface and resumed rendering without an emergency action.
- **Runtime behavior and visual evidence:** GPU query, palette, fade, reload, effect-switching, and IPC checks passed; injected shader-init failure selected the SHM fallback. A 1920x1200 screenshot (`sha256:5a8f78555ea6e7f103f450fcbd5e45ddd6b041fee6b025f92dc4a130f701dee8`) was machine-inspected as containing the wallpaper, Waybar, and windows, with 13,509 colors; no human visual-quality claim is made. Fade comparisons produced RMSE values `0.0833543` and `0.272737` while IPC remained responsive.
- **Exact restoration:** The installed daemon was restored as PID `999182`, executable and argv `/home/px/wlchroma/zig-out/bin/wlchroma`, cwd `/home/px`, executable SHA-256 `309d6a9d10155becf6313126340580cbc94bf2577a457e01a6ca34505cb45142`, and socket `/run/user/1000/wlchroma.sock`. Query returned `colormix`, 24 FPS, scale 0.20, custom palette; the config SHA-256 was `ad4e6b1f9360e1a81879f5ba0d53a2b8608bcf8d0cae067ec14c7d7fde17118c`. `mpris-chroma.service` was active as PID `999206`; `eDP-1` was restored to 1920x1200@60.026, scale 1, normal transform, VRR off, workspace 2. Recovery/candidate units were absent, the private socket was gone, and temporary live-test artifacts were cleaned.
- **Limitations, evidence, and remote gates:** Only one physical output was available, so simultaneous mixed-output/mixed-refresh behavior remains an external hardware gate. The detailed report remains local ignored evidence at `.superpowers/sdd/phase4-live-verification.md`. On final commit `7550634`, GitHub Actions Lint run `31708945616` and Test run `31708945583` both completed successfully; the Test job built the project and passed the full suite.
