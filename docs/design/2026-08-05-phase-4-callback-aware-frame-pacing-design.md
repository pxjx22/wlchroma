# Phase 4 Callback-Aware Frame Pacing Design

Date: 2026-08-05

## Scope

Phase 4 closes the remaining high-value overlap between the untracked
efficiency audits:

- Efficiency Audit 2 item 2.1: the frame timer continues to wake the daemon
  while every surface is blocked on a Wayland frame callback.
- Efficiency Audit 3 item 3.3: requested rates above the compositor's actual
  callback cadence produce timer wakeups that cannot present another frame.

The two findings share one timer state machine and must be fixed together.
Phase 4 preserves the Phase 3B shared `AnimationState`; it does not revive the
stale per-effect animation gates described by Efficiency Audit 2 item 2.2.

Out of scope:

- per-output FPS, effects, animation timelines, or timers;
- changing the configured or runtime FPS ranges;
- changing the existing FPS-dependent logical animation rate;
- using `wl_output` refresh metadata as a presentation promise;
- SHM partial damage, `syncSurfaces` gating, viewporter, opaque regions,
  shader rewrites, or renderer micro-optimizations;
- changing the GPU/SHM frame callback ownership or destruction contract;
- changing the default 15 FPS cadence.

## Goals and invariants

1. The requested FPS remains the authoritative logical animation cadence and
   the value returned by `query`.
2. Reducing physical wakeups must not reduce logical animation progression.
   If N requested ticks elapse between presentable frames, the shared
   animation advances by N steps before the next render attempt.
3. Every render attempt observes one shared animation phase across all
   surfaces visited by that scheduler service.
4. When every renderable surface has an outstanding frame callback, the frame
   timer is disarmed. A Wayland callback, configure, hotplug event, IPC
   mutation, or existing poll-loop event can make scheduling progress again.
5. A callback arriving before the next requested deadline arms one absolute
   one-shot timer for that deadline. A callback arriving at or after the
   deadline services the frame immediately without an intermediate timer
   wakeup.
6. Absolute requested deadlines prevent callback latency and event-loop work
   from stretching the configured cadence.
7. Zero outputs retain the existing semantics: the timer and logical animation
   timeline pause, and output return continues from the retained phase without
   replaying the output-less interval.
8. Existing surfaces whose callbacks are withheld retain the existing logical
   time semantics: elapsed requested ticks are coalesced and applied when a
   surface becomes presentable again.
9. Requested FPS and deadlines commit only with their required timer syscall.
   Armed-state belief changes only after successful timer operations or an
   explicit read-anomaly invalidation that immediately enters recovery.
10. Normal scheduling performs no allocation, thread creation, per-surface
    clock read, or EGL/GL work for callback-blocked surfaces.
11. No slow output may cap a faster output. Mixed-refresh behavior follows
    actual per-surface callback readiness.

## Chosen architecture

### 1. One global callback-led scheduler

`App` continues to own one timerfd, one requested frame interval, and one
shared `AnimationState`. A small scheduler component owns only timing state and
pure deadline arithmetic; Wayland objects and timer syscalls remain App-owned.

`App.frame_interval_ns` remains the only requested-FPS source of truth. It
continues to drive `query`, reload, and `set-fps`. The scheduler does not keep a
second interval copy. Its pure state is conceptually:

```zig
const FrameSchedule = struct {
    next_logical_deadline_ns: ?u64,
};
```

The exact implementation type and method names may follow existing Zig style,
but the boundary is fixed:

- the pure component decides whether logical ticks are due and calculates the
  next absolute deadline;
- `App` determines whether at least one surface can currently render;
- `App` owns `timerfd_settime`, timerfd reads, animation advancement, fades,
  and render dispatch;
- `SurfaceState` retains its existing callback pointer and early render gate.

There is deliberately no per-output timer state. With one global requested
cadence and one shared effect timeline, the fastest presentable output already
determines the process wake cadence. Per-output deadlines would mainly avoid a
few callback-pointer checks while multiplying hotplug and failure states.

### 2. Readiness is based on real callbacks, not refresh metadata

The scheduler treats a surface as immediately renderable only when it is live,
configured, has a usable extent/surface, and has no outstanding frame callback.
Unconfigured, dead, removed, or callback-blocked surfaces do not justify a
frame-timer wake.

The current `SurfaceState.renderTick` safety checks remain authoritative. The
App-level readiness predicate is scheduling guidance, not permission to bypass
those checks. A surface can still reject a render because EGL cannot become
current, no SHM buffer is free, or another late condition fails.

If a render attempt leaves a surface ready and without a callback, the
scheduler arms the next requested deadline so transient EGL/SHM failures are
retried without spinning. If every attempted surface arms a callback, the
timer is disarmed and the next callback becomes the next scheduling wake.

`OutputInfo.refresh_mhz` is not used to cap the timer. Callback timing reflects
the compositor's real presentation policy, including VRR, occlusion,
power-management throttling, and inaccurate or unknown mode metadata. This
also avoids the incorrect slowest-output policy from Efficiency Audit 3.

### 3. Absolute logical timeline and coalescing

Whenever at least one surface exists, the scheduler maintains an absolute
`CLOCK_MONOTONIC` deadline for the next logical animation tick. When scheduling
is serviced at time `now`:

- if `now` is before the logical deadline, animation does not advance and an
  absolute one-shot timer is armed only if a surface is ready;
- if `now` is at or after the deadline, the scheduler calculates how many
  requested intervals elapsed, advances `AnimationState` once by that count,
  advances the absolute deadline by the same number of intervals, samples an
  active fade once at `now`, and attempts one render pass;
- if the deadline is overdue but no surface is ready, the overdue deadline is
  retained and the timer remains disarmed; the next readiness event coalesces
  the complete elapsed interval without spinning;
- missed logical ticks are never replayed as a burst of render calls;
- `AnimationState.advance` retains its bounded fold for large counts.

This preserves Phase 3B's existing relationship: one requested FPS interval is
one logical animation step. For example, a 240 FPS request on a compositor
that makes a surface available at 60 Hz presents at about 60 Hz, but each
presented frame advances across approximately four logical steps. Physical
wakeups fall while visible motion retains the current requested-FPS behavior.

Deadline arithmetic uses checked subtraction, division, multiplication, and
addition. Artificial near-`u64` overflow resynchronizes the next deadline from
the current monotonic time without looping or invoking undefined behavior.

### 4. Event-loop service points

Within a normal poll iteration, Wayland events are dispatched, surfaces are
reconciled, timer readiness is consumed, and signal/IPC/reload facts are
handled before one scheduling reconciliation runs while the App is still
running. If `wl_display_prepare_read` reports pending events, that branch also
reconciles scheduling once before continuing; otherwise a cleared callback
could leave the loop with no armed timer or future Wayland event. Runtime
FPS/reload mutations use a separate transactional reschedule operation, after
which the ordinary end-of-batch reconciliation must be idempotent.

The service operation performs these steps in order:

1. Reconcile output and surface lifecycle as today.
2. If there are zero surfaces, clear the logical deadline and disarm the timer.
3. Read `CLOCK_MONOTONIC` once for the global scheduling decision.
4. Determine whether any surface is currently renderable.
5. If no logical tick is due, arm the absolute deadline only when a surface is
   ready; otherwise remain disarmed and wait for a Wayland event.
6. If a logical tick is due and a surface is ready, coalesce elapsed requested
   ticks, advance animation once, sample/apply any active fade once, and visit
   all surfaces for one render pass.
7. Re-evaluate readiness after rendering. Disarm when all surfaces are blocked;
   otherwise arm the next absolute deadline.

A Wayland frame callback still destroys its callback object and clears the
surface field only. It does not call App code through a new userdata pointer,
mutate the animation, or render re-entrantly. The ordinary post-dispatch
scheduler service observes the cleared field. This preserves listener address
stability and keeps rendering outside C callbacks.

### 5. Timerfd mode

The frame timer becomes an absolute one-shot timer using
`TFD_TIMER_ABSTIME`. `src/sys.zig` exposes a narrowly typed timerfd settime
operation that accepts the required flag; unrelated callers remain explicit.

One-shot operation is intentional:

- callback delivery can make the next repeating expiration unnecessary;
- pausing while blocked requires explicit re-arming anyway;
- absolute deadlines prevent relative callback-plus-interval drift;
- elapsed logical tick calculation replaces repeating-timer expiration counts
  as the animation-time source.

Timerfd reads remain exactly eight bytes and validated before scheduling work.
The decoded kernel expiration count proves a real timer event was consumed but
does not directly advance animation; logical elapsed intervals are derived
from the absolute deadline and the single monotonic sample.

After any successful one-shot timerfd read, App marks the kernel timer
disarmed before decoding the record because the expiration has been consumed.
An invalid decoded length cannot advance animation or deadlines, but ordinary
reconciliation must synchronously decide whether to render or install a fresh
timer.

Any read error after poll reported timer readiness makes the prior armed-state
belief untrusted. App clears that belief and runs the same reconciliation in
the current loop iteration. This safely covers an injected short read,
`EAGAIN` after readiness, or an interrupted read: a still-pending expiration
may be replaced, but absolute-deadline arithmetic preserves its elapsed logical
ticks. A ready surface is never left depending on another timer event that may
not exist.

Normal reconciliation and FPS mutation use distinct clock-failure policies:

- A transactional `set-fps` or reload mutation returns an error without a
  fallback syscall and preserves the requested interval, deadline, armed-state
  belief, and previously installed kernel timer.
- During ordinary reconciliation, a failed monotonic sample leaves a trusted
  installed timer unchanged. If no timer is trusted and a surface is ready,
  App attempts one relative one-shot at the existing requested interval so the
  daemon retries instead of stranding the surface. It does not change the
  absolute logical deadline or animation from undefined time data.
- If that exceptional recovery arm also fails, App marks timer recovery
  pending and clamps the otherwise-computed poll timeout to a bounded retry
  interval of at most 100 ms until an arm succeeds or another event makes
  progress. When a checked clock value is available, the retry timeout is the
  smaller of 100 ms and the rounded-up time to the retained deadline. The
  recovery flag and timeout add no recurring work on the normal path, and
  repeated diagnostics are rate-limited to at most once per second.

The exceptional relative fallback may drift for one interval. Once a checked
monotonic sample succeeds, absolute-deadline reconciliation resumes.

## Runtime mutations and lifecycle

### `set-fps` and reload

A successful FPS mutation preserves existing timer-reset semantics:

- discard the partial old interval;
- set the next logical deadline to `now + new_interval` when surfaces exist;
- leave animation phase unchanged;
- if a surface is ready, install the new absolute timer;
- if every surface is callback-blocked, keep the timer disarmed while retaining
  the new logical deadline;
- with zero surfaces, store the requested interval and leave the timeline
  paused until an output returns.

The mutation is transactional. Any required clock or timer installation
failure returns an IPC/reload error and preserves the sole requested interval,
deadline, armed-state belief, and previously installed kernel timer. No
relative fallback is installed from the mutation path. `query` continues to
expose the requested FPS, never an inferred compositor rate.

### Hotplug, configure, and teardown

- Zero to one-or-more surfaces starts a new logical deadline from the current
  monotonic time and retained animation phase.
- One-or-more to zero surfaces clears the deadline and disarms the timer.
- Adding or configuring another surface while the timeline is active does not
  reset animation or the deadline.
- Removing one output does not affect the shared timeline while another
  surface remains.
- Configure and frame-callback events wake the existing Wayland poll path; the
  post-dispatch scheduler determines whether to render now or arm a deadline.
- Surface teardown continues to destroy outstanding callbacks before freeing
  listener userdata. The scheduler stores no surface pointers.

### Fades

Fades remain wall-clock based and are sampled only when a due logical frame is
actually serviced. Timer ticks that cannot render no longer mutate the
palette. If callbacks are withheld past the fade duration, the next render
samples the final target exactly. Mid-fade IPC retargeting continues to sample
the current wall-clock fade state through the existing command path.

## Failure behavior

- A malformed or short successful timerfd read is logged and cannot change
  animation, fade, deadline, or surface state. The one-shot armed flag is
  cleared because the successful read consumed the kernel expiration, and
  ordinary reconciliation must render or install a fresh timer before the
  iteration completes when a surface is ready.
- A timerfd read error after readiness clears trusted armed-state knowledge and
  triggers ordinary reconciliation in the same iteration. It changes no
  animation, fade, deadline, or surface state by itself.
- A failed timer arm/disarm updates no in-memory armed state. The next poll or
  Wayland event retries reconciliation; when no trusted timer or callback can
  provide that wake, the bounded exceptional poll retry preserves liveness.
- A failed render leaves callback ownership exactly as `SurfaceState` reports
  it. A still-ready surface gets a normal-cadence retry, never an immediate
  busy loop.
- A clock failure never feeds undefined bytes or fabricated elapsed counts into
  `AnimationState`.
- Large delays coalesce into one bounded animation advance and one render pass.
- Compositor disconnect, signal shutdown, IPC stop precedence, and reload
  worker teardown remain unchanged.

## Testing strategy

### Deterministic tests

Add pure scheduler tests for:

- first deadline initialization and zero-output pause/resume;
- before/on/after-deadline decisions;
- elapsed-tick coalescing without render bursts;
- requested interval changes while ready, callback-blocked, and output-less;
- 60-only, 144-only, and 60+144 callback sequences without using refresh
  metadata;
- callback arrival before a deadline versus after an overdue deadline;
- a withheld callback followed by recovery with preserved logical phase;
- deadline arithmetic near `u64` limits;
- clock and timer failure transactionality;
- invalid/short timer records and `EAGAIN` after poll readiness cannot strand a
  ready surface;
- ordinary clock failure with a ready surface either preserves a trusted timer
  or installs the bounded recovery path;
- no-change scheduling without allocations.

Extend Wayland/EGL App tests for:

- all configured surfaces callback-blocked implies a disarmed timer;
- one cleared callback re-enables scheduling without rendering in the C
  callback;
- unconfigured/dead surfaces do not keep the timer awake;
- a render failure that leaves no callback receives a later retry;
- `set-fps` and reload each preserve prior state when their checked clock sample
  or timer installation fails;
- one-shot read and clock failures retain a future scheduling wake for a ready
  surface;
- shared animation advances by logical elapsed ticks, not physical wake count;
- fade completion after a callback-throttled interval;
- hotplug and zero-output transitions preserve Phase 3B semantics.

Run focused tests during implementation, then the repository baseline:

```text
zig build test-wayland-egl
zig build test
zig test src/config/config.zig
```

The final `zig build test` requires host syscall access for the established Unix
socket tests. Debug, ReleaseSafe, and ReleaseFast arithmetic coverage is
required before the phase is closed.

### Live Niri acceptance on cairn

Live verification uses an isolated candidate daemon and preserves the current
installed daemon for restoration. Exact PIDs are used; no name-wide process
termination is allowed.

1. At the default 15 FPS on `eDP-1`, verify visual cadence, IPC responsiveness,
   fade behavior, and no callback-plus-interval slowdown.
2. At runtime 240 FPS on the approximately 60 Hz internal display, compare
   baseline and candidate poll/timer wake counts over equal intervals. The
   candidate must eliminate timer wakeups between outstanding callbacks while
   retaining current animation motion and presentation smoothness.
3. Run an equal-duration side-by-side process CPU/context-switch/wakeup
   measurement. Claim only observed savings; do not infer GPU power reduction
   from fewer CPU timer reads.
4. With a second physical output, test mixed refresh at 15 FPS and 240 FPS.
   The faster display must not be capped to the slower display, and both must
   retain a shared animation timeline. If a second output is unavailable, this
   remains an explicit external release gate rather than a CI claim.
5. For output-off testing, pre-arm and independently verify a recovery service
   that restores the exact output before disabling it. While the only output
   is unavailable, verify zero recurring frame-timer wakeups, responsive IPC,
   and correct recovery. Do not run this step without explicit user approval.
6. Exercise output off/on, hotplug if available, `set-fps`, reload, effect
   switching, palette fades, GPU rendering, and forced SHM fallback. Confirm no
   timer, callback, EGL, allocation, or stale-surface warnings.

## Performance retention gates

The phase is retained only if all correctness tests pass and live evidence
shows:

- no default-15-FPS visual or cadence regression;
- no repeating timer wake while every surface is callback-blocked;
- materially fewer timer reads and process wakeups for 240 FPS requested on a
  roughly 60 Hz output;
- no regression in mixed-refresh fast-output cadence;
- no new steady-state allocation or clock read per surface;
- no increase in rendered frames beyond what callbacks make presentable.

The expected benefit is CPU/package wakeup and battery efficiency. The design
does not reduce shader cost for frames that are actually rendered and must not
be described as a measured GPU improvement without separate evidence.

## Documentation and audit closure

Implementation updates the relevant maintainer-local output-hotplug/timer
contract under `specs/006-output-hotplug/` in the same change. README changes
are required only if implementation changes a public FPS, IPC, config, visual,
or fallback contract; this design intentionally preserves those contracts.

The final evidence record will classify Efficiency Audit 2 item 2.1 and
Efficiency Audit 3 item 3.3 as fixed, record Audit 2 item 2.2 as already fixed,
and keep the remaining measurement-gated renderer proposals deferred. Audit
closure requires deterministic tests, the available live matrix, restoration
of the original local runtime, and remote CI after push.
