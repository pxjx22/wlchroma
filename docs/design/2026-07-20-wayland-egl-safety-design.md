# Wayland and EGL Safety Design

**Date:** 2026-07-20

**Status:** Approved for implementation

**Audit mapping:** `WL-H1`, `WL-H2`, `GPU-M1`, `GPU-M2`, `GPU-M3`, `WL-L1`

## Goal

Make Wayland hotplug, EGL fallback, effect switching, and shutdown preserve strict resource ownership and checked C-ABI dimensions without adding work to the per-frame render path.

## Scope

This phase includes:

- One explicit lifetime for the shared EGL context and every GL object created within it.
- Borrow invalidation before context destruction.
- Context-aware GL deletion and ordered EGL surface teardown.
- Checked layer-shell dimensions and checked SHM layout arithmetic.
- Transactional output registration and SHM replacement failure handling.
- Driver-independent regression tests plus live Niri acceptance tests.

This phase does not change effects, animation semantics, palettes, IPC commands, configuration, output policy, renderer scaling behavior, or GPU/CPU feature selection. Phase 3 findings remain out of scope.

## Chosen Architecture: GPU Context Epochs

`App` owns one GPU epoch. An active epoch consists of the shared `EglContext`, the effect shader, the optional blit shader, and all EGL surfaces and GL objects created against that context. A `SurfaceState` may borrow the active context and owns its EGL surface and optional offscreen framebuffer only while that epoch is active.

The last live output ends the current epoch. The first later output starts a fresh epoch before its surface is created, after which the existing lazy pipeline path rebuilds the shaders. Recompilation after a complete output outage is acceptable because it occurs only at the hotplug boundary and avoids an allocation-backed deferred-deletion queue.

A normal zero-output transition is not a permanent GPU failure. Pipeline compilation failure and context creation failure remain failure states, while deliberate epoch closure remains recoverable.

The alternatives were rejected:

- A deferred GL-deletion queue preserves a warm context, but requires generation-tagged program, buffer, framebuffer, and texture ownership; queue allocation failure still needs whole-context teardown.
- Local cleanup patches leave acquisition, deletion, and context lifetime distributed across `App` and `SurfaceState`, which preserves the structure that produced the audit findings.

## GPU Lifetime Invariants

The implementation must preserve all of these invariants:

1. If `App.egl_ctx` is null, no surface retains an EGL-context borrow, EGL surface, or offscreen GL object.
2. Every stored GL handle is either owned by an active epoch or has been reclaimed by destruction of that epoch's context.
3. GL deletion functions run only after the same EGL context is confirmed current.
4. EGL surfaces are unbound before destruction and are destroyed before their borrowed `EGLDisplay` is terminated.
5. Context acquisition tries every live EGL surface rather than stopping after the first failure.
6. A failed acquisition never causes ownership to be silently discarded.

## Epoch Closure

One shared orchestration path handles zero outputs, unrecoverable active-output cleanup, GPU-to-CPU fallback, and application shutdown. Production and fake-test backends execute the same ordering:

1. Invalidate every stored context borrow and atomically detach surface-owned EGL/offscreen state.
2. Try every usable EGL surface to obtain and confirm the shared current context.
3. If a context is current, delete the App-owned shaders and all detached offscreen GL objects.
4. If no context is current, do not issue GL deletion calls; context destruction reclaims its objects.
5. Clear the current EGL binding.
6. Destroy every detached EGL surface.
7. Destroy the shared EGL context and clear all CPU-side handle wrappers.

Current-context confirmation checks both the current draw surface and current context. Handle equality for the draw surface alone is insufficient because EGL drivers may reuse surface handles.

During an active epoch, operations such as filter changes retain their current offscreen ownership if `makeCurrent` fails. If a surface must be removed and no compatible surface can make the context current for cleanup, the application closes the whole epoch rather than leaking or losing the resource.

## Surface Detachment and CPU Fallback

`SurfaceState` exposes one atomic GPU-detachment operation. It moves out the optional EGL surface and offscreen object while clearing the stored `egl_ctx`, `egl_surface`, and `offscreen` fields before any dead/configured/size branch can return.

CPU fallback uses the detached state only for cleanup. SHM configuration begins after detachment completes. A dead or zero-sized surface remains safely detached and unconfigured; it cannot retain a pointer into a destroyed `App.egl_ctx`.

## Checked Dimensions

A driver-independent dimensions module validates protocol values before state mutation or C calls.

The checked extent type stores the validated `u32` dimensions and their signed C representations. Resolution follows layer-shell semantics: a zero event dimension reuses the previous validated dimension; if either resolved dimension remains zero, the result is unconfigured rather than an error. A nonzero value larger than `maxInt(i32)` is rejected.

The layer-surface configure sequence is:

1. Acknowledge the configure event.
2. Resolve zero-valued dimensions from the previous valid extent.
3. Validate both dimensions against every downstream signed C ABI.
4. On invalid input, log and return without mutating the last valid extent or calling EGL, GLES, SHM, framebuffer, or allocation code.
5. Only after validation, store the new extent and resize or recreate resources.

The validated signed dimensions are used by `wl_egl_window_create`, `wl_egl_window_resize`, `glViewport`, and `glTexImage2D`. No call site repeats an unchecked `@intCast` from compositor-controlled dimensions.

## Checked SHM Layout

SHM layout is computed from a checked extent with overflow-detecting arithmetic for:

- XRGB8888 stride (`width * 4`).
- Per-buffer bytes (`stride * height`).
- Double-buffer mapping bytes.
- Per-buffer offsets.
- CPU cell-grid element count.

The stride, offsets, width, height, and total pool size must be representable by their Wayland C API parameters. The validated layout stores `stride`, `buffer_bytes`, `total_bytes`, and both offsets. `ShmPool` stores `total_bytes` and uses it directly for `munmap`; teardown never recomputes a size.

SHM replacement is transactional. The new checked layout, cell grid, file mapping, pool, and buffers are prepared before the old grid and pool are released. Failure leaves the last valid resources owned and prevents a partially configured surface.

EGL-capable dimensions are not rejected merely because they exceed the stricter SHM pool-size limit. General extent validation and SHM layout validation remain separate.

## Output Registration Ownership

The output registry branch establishes an owner before binding a `wl_output` proxy:

1. Resolve the destination output list.
2. Allocate `OutputInfo`.
3. Bind the proxy.
4. Initialize `OutputInfo`, which then owns the proxy.
5. Append the pointer to the output list.
6. Install listener userdata only after successful append.

Allocation failure occurs before bind, so no proxy exists to release. Bind failure releases the uninitialized allocation. Append failure deinitializes `OutputInfo`, releasing the proxy exactly once, then destroys the allocation. Listener-registration failure first removes the just-appended pointer, then performs the same deinitialization and destruction. Listener userdata therefore remains heap-stable and never outlives its owner.

## Error Handling

- Invalid compositor dimensions fail closed without panicking or narrowing.
- Checked arithmetic returns a bounded layout error before allocation, mmap, or C calls.
- Failed context acquisition tries remaining surfaces.
- Cleanup without a confirmed current context skips GL calls and closes the epoch.
- Failed offscreen recreation retains the prior owner until safe cleanup or epoch closure.
- Context creation after output return may fall back to SHM without leaving partial GPU state.
- EGL surface teardown clears a matching current binding before destruction.
- Repeated teardown and detachment operations are idempotent at the ownership level.

## Performance

The design adds no allocator calls, system calls, or synchronization to the ordinary per-frame render path. Checked dimensions run only on configure/resize. Epoch creation and destruction run only on complete output loss, recovery, fallback, or shutdown. Output registration and SHM replacement remain hotplug/configure-time operations.

## Automated Verification

A focused `test-wayland-egl` build step covers driver-independent helpers in separate test artifacts.

Dimension and layout tests cover:

- Layer-shell zero-dimension resolution.
- The largest accepted signed C dimension and the first rejected value.
- Checked stride, buffer-size, mapping-size, offset, and grid-size boundaries.
- Stored teardown size and buffer-slice boundaries.
- Preservation of the last valid extent after rejected input.

GPU lifecycle tests use a fake backend and event log to cover:

- First-surface failure followed by later-surface success.
- All-surface acquisition failure without contextless GL deletion.
- Borrow invalidation before context destruction.
- Unbind before EGL surface destruction.
- Zero-sized and dead surface detachment.
- Offscreen ownership retention after injected acquisition failure.
- Repeated zero-output effect switches without accumulated epoch resources.
- Fresh epoch creation when the first output returns.
- Shutdown continuing past the first failed surface acquisition.

Output registration tests use failing allocation and fake proxy operations to prove that allocation failure performs no bind, bind/append/listener failures roll back each acquired resource exactly once, and successful registration transfers ownership.

Every task runs its focused red/green tests. Phase verification runs formatting plus the full Debug, ReleaseSafe, and ReleaseFast build and test graphs.

## Live Niri Acceptance

Real EGL/Wayland behavior still requires a live compositor check. Acceptance covers:

- Normal GPU rendering and runtime effect switching.
- Single-output resize/reconfigure.
- Multi-output add/remove and continued rendering on the surviving output.
- Complete output loss, effect switching while output-less, automatic output recovery, fresh GPU epoch creation, and restored rendering.
- CPU fallback and clean shutdown without stale-pointer, context, or resource warnings.

Before disabling every output, the operator must resolve exact Niri output names, inspect the exact wlchroma process, arm and validate an independent automatic recovery action using the current `NIRI_SOCKET`, and test one-output recovery first. No name-wide `pkill wlchroma` command is permitted.

## Completion Criteria

Phase 2 is complete only when:

- `WL-H1`, `WL-H2`, `GPU-M1`, `GPU-M2`, `GPU-M3`, and `WL-L1` have committed fixes and regression coverage.
- The GPU lifetime invariants hold in fake-backend tests and live Niri acceptance.
- Debug, ReleaseSafe, and ReleaseFast builds and test graphs pass.
- Formatting and diff checks pass.
- The audit ledger records commit IDs, automated evidence, live evidence, and final dispositions without rewriting the original finding descriptions.
