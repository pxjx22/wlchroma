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

1. **IPC hardening:** `IPC-H1`, `IPC-H2`, `IPC-M1`, `IPC-L1`, `IPC-L2`, `IPC-L3`, and `APP-L1`. Design: [`2026-07-19-ipc-hardening-design.md`](../design/2026-07-19-ipc-hardening-design.md).
2. **Wayland/EGL safety:** `WL-H1`, `WL-H2`, `GPU-M1`, `GPU-M2`, `GPU-M3`, and `WL-L1`.
3. **Rendering, configuration, and modernization:** all remaining `GPU`, `RENDER`, `APP`, `PERF`, `CONF`, and `BUILD` findings.

Each phase receives its own approved design, TDD implementation plan, focused commits, and full Debug/ReleaseSafe/ReleaseFast verification.

## Finding Ledger

| ID | Severity | Phase | Finding | Status |
|---|---|---:|---|---|
| IPC-H1 | High | 1 | Client-triggered `SIGPIPE` can terminate the daemon | Open |
| IPC-H2 | High | 1 | Per-read timeout permits slow-client main-thread starvation | Open |
| IPC-M1 | Medium | 1 | A second daemon can steal and later remove the live socket path | Open |
| IPC-L1 | Low | 1 | Response writes do not handle partial success | Open |
| IPC-L2 | Low | 1 | The documented 4096-byte line boundary is off by one | Open |
| IPC-L3 | Low | 1 | No-argument commands accept ignored trailing arguments | Open |
| APP-L1 | Low | 1 | Signalfd data is read from an undefined buffer without validating read length | Open |
| WL-H1 | High | 2 | GPU fallback can leave a stale borrowed EGL-context pointer | Open |
| WL-H2 | High | 2 | Compositor dimensions reach C APIs without checked narrowing | Open |
| GPU-M1 | Medium | 2 | Zero-output effect switching leaks shader programs and VBOs | Open |
| GPU-M2 | Medium | 2 | Failed `makeCurrent` paths lose offscreen FBO and texture ownership | Open |
| GPU-M3 | Medium | 2 | EGL cleanup can destroy a current surface or issue GL calls without a context | Open |
| WL-L1 | Low | 2 | A bound `wl_output` proxy leaks if `OutputInfo` allocation fails | Open |
| GPU-M4 | Medium | 3 | Palette uploads can be lost when no EGL context is current | Open |
| GPU-M5 | Medium | 3 | Switching to colormix leaves pattern uniforms at defaults | Open |
| GPU-M6 | Medium | 3 | Colormix shader failure produces a black EGL surface instead of SHM fallback | Open |
| RENDER-M1 | Medium | 3 | Runtime speed changes jump GPU phase and CPU colormix ignores speed | Open |
| RENDER-L1 | Low | 3 | `renderGrid` relies on callers to provide an exact output length | Open |
| APP-L2 | Low | 3 | Reload silently ignores `timerfd_settime` failure | Open |
| PERF-L1 | Low | 3 | Reload performs synchronous file I/O and two parser passes on the render loop | Open |
| PERF-L2 | Low | 3 | CPU fallback resolves and updates its effect twice per frame | Open |
| PERF-L3 | Low | 3 | CPU fallback reads the monotonic clock separately for every output | Open |
| PERF-L4 | Low | 3 | Colormix repeats invariant integer conversions inside the inner loop | Open |
| PERF-L5 | Low | 3 | Column-major cells create strided reads during framebuffer expansion | Open |
| PERF-L6 | Low | 3 | Ever-growing frame counts lose `f32` animation precision after long uptime | Open |
| CONF-L1 | Low | 3 | The custom TOML parser accepts a documented subset but does not define escape semantics | Open |
| BUILD-L1 | Low | 3 | `build.zig.zon` still declares Zig 0.15.2 | Open |

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
