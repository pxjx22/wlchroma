# Phase 4 Callback-Aware Frame Pacing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace periodic no-op frame-timer wakeups with one callback-led absolute scheduler while preserving wlchroma's requested-FPS animation progression, hotplug behavior, and transactional runtime controls.

**Architecture:** A pure `FrameSchedule` owns only the next logical `CLOCK_MONOTONIC` deadline and coalesces elapsed requested ticks. `App` remains the sole owner of requested FPS, timerfd state/syscalls, animation, fades, and render dispatch; real Wayland callback readiness decides whether to render, arm one absolute one-shot timer, or sleep. A small injected test seam exercises timer, clock, render, and failure transitions without rendering through fake Wayland objects.

**Tech Stack:** Zig 0.16.0, Linux `timerfd` with `TFD_TIMER_ABSTIME`, Wayland frame callbacks, EGL/GLESv2 and SHM render paths, `std.testing`, Niri live acceptance, `/proc` process metrics.

## Global Constraints

- Implement only Efficiency Audit 2 item 2.1 and Efficiency Audit 3 item 3.3 in this phase; Audit 2 item 2.2 remains already fixed.
- Preserve `App.frame_interval_ns` as the only requested-FPS source of truth and preserve the existing config/runtime ranges exactly.
- Preserve the current FPS-dependent logical animation rate: N elapsed requested intervals advance `AnimationState` by N even if only one frame can be presented.
- Preserve one App-owned shared animation phase across all EGL and SHM outputs.
- Use actual Wayland callback readiness; do not cap against `OutputInfo.refresh_mhz`, the slowest output, or inferred refresh metadata.
- No per-output FPS, timer, effect, or animation state.
- Zero surfaces pause the logical timeline and retain phase; callback-blocked existing surfaces retain overdue logical work for coalescing on recovery.
- Rendering remains outside Wayland C callbacks; callbacks only destroy/clear their existing callback object.
- The normal path adds no allocation, worker, dependency, per-surface clock read, or EGL/GL work for blocked surfaces.
- One-shot timer reads must be exact eight-byte records before they are accepted as valid timer events.
- `set-fps` and reload remain transactional across checked clock, timer, deadline, and requested-interval state.
- No new public config key, IPC command, CLI option, protocol, or build-time fault option.
- Zig is pinned to exactly 0.16.0; do not change `.zig-version`, package metadata, or CI toolchain versions.
- Never touch the user-owned untracked files `EFFICIENCY_AUDIT.md`, `EFFICIENCY_AUDIT_2.md`, `EFFICIENCY_AUDIT_3.md`, or `mpris-wlchroma-audit-transcript.txt`.
- Use exact PIDs for live daemons; never use a name-wide process kill.
- Do not disable an output without explicit user approval and an independently verified recovery service.

---

### Task 1: Add the pure absolute deadline schedule

**Files:**
- Create: `src/render/frame_schedule.zig`
- Create: `tests/frame_schedule_test.zig`
- Modify: `src/test_exports.zig`
- Modify: `src/test_wayland_exports.zig`
- Modify: `build.zig`

**Interfaces:**
- Consumes: validated nonzero `App.frame_interval_ns` and checked `CLOCK_MONOTONIC` nanoseconds supplied by the caller.
- Produces: `FrameSchedule.inactive`, `begin`, `rebase`, and side-effect-free `plan` decisions for later App integration.

- [ ] **Step 1: Export and register the missing module as a RED test target**

Add to both test-export shims:

```zig
pub const frame_schedule = @import("render/frame_schedule.zig");
```

Register `tests/frame_schedule_test.zig` beside `animation_state_test.zig` in `build.zig`:

```zig
const frame_schedule_test_mod = b.createModule(.{
    .root_source_file = b.path("tests/frame_schedule_test.zig"),
    .target = target,
    .optimize = optimize,
});
frame_schedule_test_mod.addImport("wlchroma_src", src_exports_mod);
const frame_schedule_tests = b.addTest(.{
    .root_module = frame_schedule_test_mod,
});
const run_frame_schedule_tests = b.addRunArtifact(frame_schedule_tests);
test_step.dependOn(&run_frame_schedule_tests.step);
```

- [ ] **Step 2: Write the failing pure schedule tests**

Create the test file with concrete helpers and boundary cases:

```zig
const std = @import("std");
const frame_schedule = @import("wlchroma_src").frame_schedule;
const FrameSchedule = frame_schedule.FrameSchedule;

fn expectWait(plan: FrameSchedule.Plan, deadline_ns: u64) !void {
    switch (plan) {
        .wait => |actual| try std.testing.expectEqual(deadline_ns, actual),
        else => return error.ExpectedWait,
    }
}

fn expectDue(
    plan: FrameSchedule.Plan,
    ticks: u64,
    next_deadline_ns: u64,
    resynchronized: bool,
) !void {
    switch (plan) {
        .due => |due| {
            try std.testing.expectEqual(ticks, due.elapsed_ticks);
            try std.testing.expectEqual(
                next_deadline_ns,
                due.next.next_logical_deadline_ns.?,
            );
            try std.testing.expectEqual(resynchronized, due.resynchronized);
        },
        else => return error.ExpectedDue,
    }
}

test "schedule begins one interval after now and pauses cleanly" {
    const inactive = FrameSchedule.inactive();
    try std.testing.expect(inactive.next_logical_deadline_ns == null);
    switch (try inactive.plan(10, 5)) {
        .paused => {},
        else => return error.ExpectedPaused,
    }
    const active = try FrameSchedule.begin(10, 5);
    try std.testing.expectEqual(@as(?u64, 15), active.next_logical_deadline_ns);
}

test "schedule waits before deadline and is due at equality" {
    const schedule = try FrameSchedule.begin(100, 20);
    try expectWait(try schedule.plan(119, 20), 120);
    try expectDue(try schedule.plan(120, 20), 1, 140, false);
}

test "schedule coalesces overdue logical ticks into one due plan" {
    const schedule = try FrameSchedule.begin(0, 4);
    try expectDue(try schedule.plan(16, 4), 4, 20, false);
}

test "planning does not consume overdue work until the caller commits" {
    const schedule = try FrameSchedule.begin(0, 4);
    const first = try schedule.plan(16, 4);
    const second = try schedule.plan(16, 4);
    try expectDue(first, 4, 20, false);
    try expectDue(second, 4, 20, false);
    try std.testing.expectEqual(@as(?u64, 4), schedule.next_logical_deadline_ns);
}

test "rebase leaves the prior schedule unchanged" {
    const old = try FrameSchedule.begin(100, 20);
    const rebased = try old.rebase(150, 10);
    try std.testing.expectEqual(@as(?u64, 120), old.next_logical_deadline_ns);
    try std.testing.expectEqual(@as(?u64, 160), rebased.next_logical_deadline_ns);
}

test "zero interval is rejected" {
    try std.testing.expectError(error.InvalidInterval, FrameSchedule.begin(0, 0));
    try std.testing.expectError(
        error.InvalidInterval,
        FrameSchedule.inactive().plan(0, 0),
    );
}

test "60 and 144 callback timestamps share one logical deadline grid" {
    const requested_interval: u32 = 4_166_666;
    const schedule = try FrameSchedule.begin(0, requested_interval);
    try expectDue(
        try schedule.plan(6_944_444, requested_interval),
        1,
        8_333_332,
        false,
    );
    try expectDue(
        try schedule.plan(16_666_666, requested_interval),
        4,
        20_833_330,
        false,
    );
}

test "near-u64 arithmetic resynchronizes without overflow or zero ticks" {
    const schedule = FrameSchedule{
        .next_logical_deadline_ns = std.math.maxInt(u64) - 5,
    };
    try expectDue(
        try schedule.plan(std.math.maxInt(u64), 10),
        1,
        std.math.maxInt(u64),
        true,
    );
}
```

The coalescing assertion must prove a 4 ms requested interval with `now` 16 ms after the first deadline returns four elapsed ticks and one future schedule, not four render actions.

- [ ] **Step 3: Run RED**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase4-t1-red \
  zig build test --summary all
```

Expected: compilation fails because `src/render/frame_schedule.zig` and its declarations do not exist; no unrelated test failure is acceptable.

- [ ] **Step 4: Implement the minimal pure state machine**

Create this public shape:

```zig
pub const Error = error{InvalidInterval};

pub const FrameSchedule = struct {
    next_logical_deadline_ns: ?u64 = null,

    pub const Due = struct {
        elapsed_ticks: u64,
        next: FrameSchedule,
        resynchronized: bool,
    };

    pub const Plan = union(enum) {
        paused,
        wait: u64,
        due: Due,
    };

    pub fn inactive() FrameSchedule;
    pub fn begin(now_ns: u64, interval_ns: u32) Error!FrameSchedule;
    pub fn rebase(self: FrameSchedule, now_ns: u64, interval_ns: u32) Error!FrameSchedule;
    pub fn plan(self: FrameSchedule, now_ns: u64, interval_ns: u32) Error!Plan;
};
```

`begin`/`rebase` reject zero and use checked addition with saturation to `maxInt(u64)` only for the artificial overflow boundary. `rebase` does not inspect the old deadline, so spell its receiver `_` (or explicitly discard it) rather than leaving an unused `self`. `plan` subtracts only after `now >= deadline`, computes `elapsed_ticks = ((now - deadline) / interval) + 1`, and returns a new value without mutating `self`. If advancing the deadline overflows, preserve the calculated nonzero elapsed tick count and return `next = try FrameSchedule.begin(now, interval)` with `resynchronized = true`. Do not import Wayland, Linux, App, allocators, or clocks.

- [ ] **Step 5: Run GREEN in all arithmetic modes**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase4-t1 \
  zig build test --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase4-t1-safe \
  zig build test -Doptimize=ReleaseSafe --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase4-t1-fast \
  zig build test -Doptimize=ReleaseFast --summary all
zig fmt --check build.zig bench src tests
git diff --check
```

Expected: all three graphs pass; the new tests prove no overflow panic in Safe or UB-dependent result in Fast.

- [ ] **Step 6: Commit the isolated pure component**

```sh
git add build.zig src/render/frame_schedule.zig src/test_exports.zig \
  src/test_wayland_exports.zig tests/frame_schedule_test.zig
git commit -m "feat(renderer): add absolute frame schedule"
```

---

### Task 2: Define the render-readiness boundary on SurfaceState

**Files:**
- Modify: `src/wayland/surface_state.zig`
- Modify: `tests/wayland_egl/surface_detach_test.zig`

**Interfaces:**
- Consumes: existing stable `SurfaceState` fields and callback lifetime.
- Produces: `SurfaceState.readyForRender() bool`, used by App without adding an App pointer to listener userdata.

- [ ] **Step 1: Add RED readiness tests with fully initialized queried fields**

Use the already-exported `wayland_test.output` concrete type in the fixture. Do not add a duplicate export.

Build a minimal `OutputInfo`, fake non-null protocol pointers, and `SurfaceState` whose queried fields are initialized:

```zig
test "surface readiness requires live configured callback-free Wayland state" {
    var output: wayland.output.OutputInfo = undefined;
    output.removed = false;

    var state: SurfaceState = undefined;
    state.output = &output;
    state.dead = false;
    state.torn_down = false;
    state.configured = true;
    state.extent = try wayland.dimensions.Extent.init(1920, 1080);
    state.frame_callback = null;
    state.layer_surface = .{
        .wl_surface = @as(*wayland.c.wl_surface, @ptrFromInt(0x1000)),
        .layer_surface = null,
    };

    try std.testing.expect(state.readyForRender());

    state.dead = true;
    try std.testing.expect(!state.readyForRender());
    state.dead = false;

    state.torn_down = true;
    try std.testing.expect(!state.readyForRender());
    state.torn_down = false;

    output.removed = true;
    try std.testing.expect(!state.readyForRender());
    output.removed = false;

    state.configured = false;
    try std.testing.expect(!state.readyForRender());
    state.configured = true;

    state.extent = null;
    try std.testing.expect(!state.readyForRender());
    state.extent = try wayland.dimensions.Extent.init(1920, 1080);

    state.frame_callback = @as(*wayland.c.wl_callback, @ptrFromInt(0x2000));
    try std.testing.expect(!state.readyForRender());
    state.frame_callback = null;

    state.layer_surface.wl_surface = null;
    try std.testing.expect(!state.readyForRender());
}
```

The ready case is `!dead`, `!torn_down`, `!output.removed`, configured, non-null extent, null callback, and non-null `layer_surface.wl_surface`. Flip each input independently and expect false. Do not dereference fake C pointers.

- [ ] **Step 2: Run RED**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase4-t2-red \
  zig build test-wayland-egl --summary all
```

Expected: compile failure only because `readyForRender` is absent.

- [ ] **Step 3: Implement and reuse the readiness method**

Add:

```zig
pub fn readyForRender(self: *const SurfaceState) bool {
    return !self.dead and
        !self.torn_down and
        !self.output.removed and
        self.configured and
        self.extent != null and
        self.frame_callback == null and
        self.layer_surface.wl_surface != null;
}
```

Replace only the equivalent leading gates in `renderTick` with:

```zig
if (!self.readyForRender()) return;
const extent = self.extent.?;
const wl_surface = self.layer_surface.wl_surface.?;
```

The unwraps are dominated by `readyForRender`; keep the method and the unwraps adjacent. EGL-current, shader, SHM-buffer, callback-allocation, and swap failure gates remain unchanged.

- [ ] **Step 4: Run GREEN and commit**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase4-t2 \
  zig build test-wayland-egl --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase4-t2-full \
  zig build test --summary all
zig fmt --check src tests
git diff --check
git add src/wayland/surface_state.zig tests/wayland_egl/surface_detach_test.zig
git commit -m "refactor(renderer): expose frame readiness"
```

---

### Task 3: Make timerfd scheduling mode explicit without changing behavior

**Files:**
- Modify: `src/sys.zig`
- Modify: `src/app.zig`
- Modify: `tests/wayland_egl/app_reload_test.zig`

**Interfaces:**
- Consumes: Zig 0.16 `linux.TFD.TIMER` flags and the current timer wrappers.
- Produces: explicit relative versus absolute timer calls for Task 4; production behavior remains repeating-relative in this commit.

- [ ] **Step 1: Change the fake timer contract first and run RED**

Extend the existing `FakeTimer` recording shape:

```zig
last_flags: ?linux.TFD.TIMER = null,

pub fn set(
    self: *@This(),
    fd: posix.fd_t,
    flags: linux.TFD.TIMER,
    value: *const linux.itimerspec,
) !void {
    self.calls += 1;
    self.last_fd = fd;
    self.last_flags = flags;
    self.last_interval = value.*;
    if (self.fail) return error.TimerFdSetTimeFailed;
}
```

Update the existing armed-interval success test to require `ABSTIME == false`. Run:

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase4-t3-red \
  zig build test-wayland-egl --summary all
```

Expected: compile failure at old two-argument timer adapters.

- [ ] **Step 2: Extend the syscall wrapper and every current caller**

Change the shim to:

```zig
pub fn timerfdSettime(
    fd: fd_t,
    flags: linux.TFD.TIMER,
    new_value: *const linux.itimerspec,
) !void {
    if (linux.errno(linux.timerfd_settime(fd, flags, new_value, null)) != .SUCCESS) {
        return error.TimerFdSetTimeFailed;
    }
}
```

Change `FrameTimer.set`, `ReloadFrameTimer.set`, direct arm/disarm calls, and test fakes to accept flags. Pass `.{}` at every existing call so this commit has no pacing change.

- [ ] **Step 3: Run GREEN and commit the mechanical seam**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase4-t3 \
  zig build test-wayland-egl --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase4-t3-full \
  zig build test --summary all
zig fmt --check src tests
git diff --check
git add src/sys.zig src/app.zig tests/wayland_egl/app_reload_test.zig
git commit -m "refactor(app): pass timerfd mode explicitly"
```

---

### Task 4: Migrate App to callback-led one-shot scheduling

**Files:**
- Create: `tests/wayland_egl/frame_pacing_test.zig`
- Modify: `build.zig`
- Modify: `src/app.zig`
- Modify: `tests/wayland_egl/app_reload_test.zig`

**Interfaces:**
- Consumes: Task 1 `FrameSchedule`, Task 2 `SurfaceState.readyForRender`, Task 3 explicit timer flags, existing `AnimationState.advance`, and existing fade sampling.
- Produces: one global callback-led scheduler, absolute one-shot timer state, coalesced animation advancement, and transactionally rebased FPS mutations.

- [ ] **Step 1: Register an App-level pacing test artifact**

Register `tests/wayland_egl/frame_pacing_test.zig` beside `app_reload_test.zig`, import `wayland_test`, and attach it to both `test-wayland-egl` and `test`:

```zig
const frame_pacing_test_mod = b.createModule(.{
    .root_source_file = b.path("tests/wayland_egl/frame_pacing_test.zig"),
    .target = target,
    .optimize = optimize,
});
frame_pacing_test_mod.addImport("wayland_test", wayland_exports_mod);
const frame_pacing_tests = b.addTest(.{ .root_module = frame_pacing_test_mod });
const run_frame_pacing_tests = b.addRunArtifact(frame_pacing_tests);
phase2_test_step.dependOn(&run_frame_pacing_tests.step);
test_step.dependOn(&run_frame_pacing_tests.step);
```

- [ ] **Step 2: Write the RED success-path matrix**

Use these concrete recording operations:

```zig
const FakeTimer = struct {
    calls: usize = 0,
    fail: bool = false,
    last_flags: ?linux.TFD.TIMER = null,
    last_spec: ?linux.itimerspec = null,

    pub fn set(
        self: *@This(),
        _: posix.fd_t,
        flags: linux.TFD.TIMER,
        spec: *const linux.itimerspec,
    ) !void {
        self.calls += 1;
        self.last_flags = flags;
        self.last_spec = spec.*;
        if (self.fail) return error.TimerFdSetTimeFailed;
    }
};

const FakeFrameOps = struct {
    ready: bool,
    block_after_render: bool = true,
    renders: usize = 0,
    phase_seen: ?f64 = null,

    pub fn hasReady(self: *@This(), _: *const App) bool {
        return self.ready;
    }

    pub fn render(self: *@This(), app: *App, _: u64) void {
        self.renders += 1;
        self.phase_seen = app.animation.phase;
        if (self.block_after_render) self.ready = false;
    }
};

const PacingFixture = struct {
    app: App,
    storage: [2]SurfaceState,
    outputs: [2]wayland.output.OutputInfo,

    const colors: [3]wayland.defaults.Rgb = .{
        wayland.defaults.Rgb{ .r = 0x10, .g = 0x20, .b = 0x30 },
        wayland.defaults.Rgb{ .r = 0x40, .g = 0x50, .b = 0x60 },
        wayland.defaults.Rgb{ .r = 0x70, .g = 0x80, .b = 0x90 },
    };

    fn testConfig(interval_ns: u32) wayland.config.AppConfig {
        return .{
            .fps = 1,
            .frame_interval_ns = interval_ns,
            .effect_type = .colormix,
            .palette = colors,
            .speed = 1.0,
            .renderer_scale = 1.0,
            .upscale_filter = .nearest,
        };
    }

    fn init(self: *@This(), surface_count: usize, interval_ns: u32) !void {
        const cfg = testConfig(interval_ns);
        self.app = undefined;
        self.app.allocator = std.testing.allocator;
        self.app.surfaces = .empty;
        self.app.configured_effect_type = cfg.effect_type;
        self.app.effect = wayland.effect.Effect.init(&cfg);
        for (0..surface_count) |index| {
            self.outputs[index] = .{
                .wl_output = null,
                .registry_name = @intCast(index + 1),
                .name = "",
                .width = 1920,
                .height = 1080,
                .refresh_mhz = 0,
                .done = true,
                .removed = false,
                .allocator = std.testing.allocator,
            };
            self.storage[index] = undefined;
            self.storage[index].output = &self.outputs[index];
            self.storage[index].dead = false;
            self.storage[index].torn_down = false;
            self.storage[index].configured = true;
            self.storage[index].extent = try wayland.dimensions.Extent.init(1920, 1080);
            self.storage[index].frame_callback = null;
            self.storage[index].layer_surface = .{
                .wl_surface = @as(*wayland.c.wl_surface, @ptrFromInt(0x1000 + index * 0x100)),
                .layer_surface = null,
            };
            try self.app.surfaces.append(std.testing.allocator, &self.storage[index]);
        }
        self.app.animation = wayland.animation_state.AnimationState.init(cfg.speed);
        self.app.frame_interval_ns = interval_ns;
        self.app.frame_schedule = FrameSchedule.inactive();
        self.app.timer_recovery_pending = false;
        self.app.last_timer_error_log_ns = null;
        self.app.effect_shader = null;
        self.app.gpu_upload_state = .{};
        self.app.current_palette = cfg.palette;
        self.app.fade = null;
        self.app.tfd = 42;
        App.TestAdapter.seedFrameTimerDisarmed(&self.app);
    }

    fn deinit(self: *@This()) void {
        self.app.surfaces.deinit(std.testing.allocator);
    }
};

test "all callback-blocked surfaces disarm without consuming overdue work" {
    var fixture: PacingFixture = undefined;
    try fixture.init(1, 4);
    defer fixture.deinit();
    fixture.app.frame_schedule = try FrameSchedule.begin(0, 4);
    App.TestAdapter.seedFrameTimerAbsolute(&fixture.app, 4);
    var timer = FakeTimer{};
    var ops = FakeFrameOps{ .ready = false };

    try App.TestAdapter.serviceFrameScheduleAt(
        &fixture.app,
        16,
        FakeTimer,
        &timer,
        FakeFrameOps,
        &ops,
    );

    try std.testing.expectEqual(@as(usize, 0), ops.renders);
    try std.testing.expectEqual(@as(f64, 0), fixture.app.animation.phase);
    try std.testing.expectEqual(
        @as(?u64, 4),
        fixture.app.frame_schedule.next_logical_deadline_ns,
    );
    try std.testing.expectEqual(App.TestAdapter.TimerMode.disarmed, App.TestAdapter.timerMode(&fixture.app));
}

test "callback before deadline reuses the absolute deadline" {
    var fixture: PacingFixture = undefined;
    try fixture.init(1, 20);
    defer fixture.deinit();
    fixture.app.frame_schedule = try FrameSchedule.begin(100, 20);
    var timer = FakeTimer{};
    var ops = FakeFrameOps{ .ready = true };

    try App.TestAdapter.serviceFrameScheduleAt(
        &fixture.app,
        110,
        FakeTimer,
        &timer,
        FakeFrameOps,
        &ops,
    );

    try std.testing.expectEqual(@as(usize, 0), ops.renders);
    try std.testing.expectEqual(@as(usize, 1), timer.calls);
    try std.testing.expect(timer.last_flags.?.ABSTIME);
    try std.testing.expectEqual(@as(i64, 120), timer.last_spec.?.it_value.nsec);
    try std.testing.expectEqual(@as(i64, 0), timer.last_spec.?.it_interval.nsec);
}

test "overdue callback coalesces logical ticks into one render" {
    var fixture: PacingFixture = undefined;
    try fixture.init(1, 4);
    defer fixture.deinit();
    fixture.app.frame_schedule = try FrameSchedule.begin(0, 4);
    var timer = FakeTimer{};
    var ops = FakeFrameOps{ .ready = true, .block_after_render = true };

    try App.TestAdapter.serviceFrameScheduleAt(
        &fixture.app,
        16,
        FakeTimer,
        &timer,
        FakeFrameOps,
        &ops,
    );

    try std.testing.expectEqual(@as(usize, 1), ops.renders);
    try std.testing.expectApproxEqAbs(@as(f64, 0.04), fixture.app.animation.phase, 1e-12);
    try std.testing.expectEqual(
        @as(?u64, 20),
        fixture.app.frame_schedule.next_logical_deadline_ns,
    );
    try std.testing.expectEqual(App.TestAdapter.TimerMode.disarmed, App.TestAdapter.timerMode(&fixture.app));
}
```

Add the remaining cases using the same fixture with these exact inputs and outcomes:

| Test | Setup | Required outcome |
|---|---|---|
| `initial ready surface installs the first absolute one-shot` | one ready surface, inactive schedule, now 100, interval 20 | schedule begins at deadline 120 and exactly one absolute one-shot is installed |
| `zero surfaces pause schedule and disarm once` | zero surfaces, deadline 4, timer absolute 4 | one zeroed disarm call, inactive schedule, unchanged phase; second service makes no syscall |
| `render success blocks and disarms while render failure schedules retry` | due at 16; first ops blocks, second leaves ready | blocking case ends disarmed; ready case arms absolute deadline 20; each renders once |
| `mixed ready and blocked surfaces follow the ready surface` | two fully initialized surfaces, one callback set, one clear, deadline 20, now 10 | production readiness arms absolute 20 and does not use refresh metadata |
| `non-renderable surfaces cannot keep the timer awake` | independently make the only surface unconfigured, dead, torn down, output-removed, or extent-less | production readiness is false, schedule is retained, and the timer is disarmed without rendering |
| `240 requested cadence advances four logical ticks at a 60Hz callback` | interval 4,166,666, first deadline 4,166,666, now 16,666,666 | one render, four logical ticks, next deadline 20,833,330 |
| `60-only callback sequence stays on one absolute timeline` | interval 4,166,666; ready events at 16,666,666, 33,333,333, 50,000,000 | one render per callback; cumulative ticks 4, 8, 12; deadlines 20,833,330, 37,499,994, 54,166,658 |
| `144-only callback sequence is not refresh-capped` | interval 6,944,444; ready events at 6,944,444, 13,888,888, 20,833,332 | one tick and one render per callback; deadlines advance exactly to 13,888,888, 20,833,332, 27,777,776 |
| `mixed 60 and 144 callback sequence shares the requested timeline` | interval 4,166,666; make the fast output ready at 6,944,444 and 13,888,888, then the slow output ready at 16,666,666 | cumulative ticks 1, 3, 4 and deadlines 8,333,332, 16,666,664, 20,833,330; no slow-output cap or per-output schedule |
| `withheld callback settles a completed fade on the next due render` | fade starts at 0 with duration 100, retained overdue deadline, ready at now 200 | fade sampled once to exact target, `fade = null`, render observes target palette |
| `zero to one surface starts from retained phase without outputless catchup` | service zero surfaces at now 100, append one surface, service ready at now 1,000 | phase unchanged; new deadline is 1,000 + interval |
| `active set-fps rebases deadline and commits only after timer success` | ready, old interval 20/deadline 120, clock now 150, request 10 | absolute 160 installed before interval/schedule commit; injected timer failure preserves all old values |
| `callback-blocked set-fps rebases without arming a timer` | one blocked surface, clock now 150, request 10; then clear its callback and service at 159 and 160 | interval 10 and deadline 160 commit with zero mutation-time timer calls; readiness arms 160 at 159 and advances exactly one tick at 160 |
| `outputless set-fps stores request without clock or timer work` | zero surfaces, fake clock and timer both configured to fail | interval commits, schedule remains inactive, both call counts remain zero |
| `blocked no-change reconciliation allocates nothing` | after fixture setup, keep `var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });` alive and set `app.allocator = failing.allocator()`; blocked surface and disarmed timer | repeated services induce no allocation failure and leave timer/render call counts unchanged |

The sequence tests must drive readiness event-by-event rather than merely call pure schedule arithmetic. The 240/60 and mixed-output tests must leave `OutputInfo.refresh_mhz` at zero and never read it. For the allocation test, assert `!failing.has_induced_failure` after every service call so the test proves the no-change hot path does not touch the App allocator.

- [ ] **Step 3: Run RED**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase4-t4-red \
  zig build test-wayland-egl --summary all
```

Expected: compile failures for the new App scheduling adapters and fields only.

- [ ] **Step 4: Add trusted timer state and scheduling helpers**

Import the pure schedule beside the other renderer state:

```zig
const FrameSchedule = @import("render/frame_schedule.zig").FrameSchedule;
```

Replace the boolean-only kernel belief with:

```zig
const FrameTimerState = union(enum) {
    disarmed,
    absolute: u64,
    relative_recovery,

    fn isArmed(self: FrameTimerState) bool {
        return switch (self) {
            .disarmed => false,
            .absolute, .relative_recovery => true,
        };
    }
};
```

Initialize the fixture only after `fixture` is in its final stack address, because its App and SurfaceState pointers refer to sibling storage. Fields used only by fake operations may remain undefined; every field read by App scheduling, fade application, production readiness, or the test assertions must be initialized above. The fake render operation must never call `SurfaceState.renderTick` through the fake Wayland pointers.

Add App fields initialized in `App.init`:

```zig
frame_schedule: FrameSchedule = FrameSchedule.inactive(),
frame_timer_state: FrameTimerState = .disarmed,
timer_recovery_pending: bool = false,
last_timer_error_log_ns: ?u64 = null,
```

Keep `frame_interval_ns` unchanged and remove `timer_armed` after fixtures and production code use the new state. Add timer spec helpers:

```zig
fn absoluteOneShotSpec(deadline_ns: u64) linux.itimerspec;
fn relativeOneShotSpec(interval_ns: u32) linux.itimerspec;
fn disarmSpec() linux.itimerspec;
```

Absolute specs split nanoseconds into seconds/nanoseconds, set `it_interval` to zero, and use `.{ .ABSTIME = true }`. Relative recovery specs also have a zero interval and empty flags.

- [ ] **Step 5: Add the injected scheduling boundary**

Implement a generic internal seam with production and fake ops:

```zig
fn serviceFrameScheduleAtWith(
    self: *App,
    now_ns: u64,
    comptime Timer: type,
    timer: *Timer,
    comptime FrameOps: type,
    frame_ops: *FrameOps,
) !void;
```

Expose only these test adapters under the existing `builtin.is_test` gate:

```zig
pub const TimerMode = enum { disarmed, absolute, relative_recovery };

pub fn seedFrameTimerDisarmed(app: *App) void;
pub fn seedFrameTimerAbsolute(app: *App, deadline_ns: u64) void;
pub fn timerMode(app: *const App) TimerMode;
pub fn timerDeadline(app: *const App) ?u64;
pub fn hasReadySurface(app: *const App) bool;

pub fn serviceFrameScheduleAt(
    app: *App,
    now_ns: u64,
    comptime Timer: type,
    timer: *Timer,
    comptime FrameOps: type,
    frame_ops: *FrameOps,
) !void {
    return app.serviceFrameScheduleAtWith(
        now_ns,
        Timer,
        timer,
        FrameOps,
        frame_ops,
    );
}
```

The seed methods are test-only state setup; production code never fabricates timer state.

`FrameOps.hasReady(frame_ops, app)` is the only injected readiness query and `FrameOps.render(frame_ops, app, now_ns)` is the only injected render action. Production ops scan `SurfaceState.readyForRender` and loop through `renderTick` once. `serviceFrameScheduleAtWith` itself samples/applies an active fade once with the supplied `now_ns` immediately before calling `FrameOps.render`, so fade ownership stays in App and no frame op reads another clock.

The implementation order is:

```text
zero surfaces -> successfully disarm -> FrameSchedule.inactive()
no ready surface -> successfully disarm -> retain possibly-overdue schedule
no deadline + ready -> begin(now, interval) -> arm absolute deadline
wait + ready -> keep/arm the same absolute deadline
due + ready -> commit due.next -> animation.advance(elapsed_ticks)
             -> sample fade once -> render once -> recheck readiness
             -> blocked: disarm; still ready: arm due.next deadline
```

Skip a timer syscall when `FrameTimerState.absolute` already equals the required deadline or when both desired/current states are disarmed. A normal render failure that leaves readiness true gets the next logical deadline; it never loops immediately.

- [ ] **Step 6: Make FPS/reload publication transactional against schedule candidates**

Introduce the production clock adapter:

```zig
const FrameClock = struct {
    fn now(_: *@This()) !u64 {
        return sys.monotonicNsChecked();
    }
};
```

Extend the existing generic seams:

```zig
fn applyFrameIntervalWith(
    self: *App,
    interval_ns: u32,
    comptime Clock: type,
    clock: *Clock,
    comptime Timer: type,
    timer: *Timer,
) !void;

fn applyReloadSnapshotWith(
    self: *App,
    candidate: *config_mod.LoadResult,
    comptime Clock: type,
    clock: *Clock,
    comptime Timer: type,
    timer: *Timer,
) !void;
```

For nonzero surfaces, get checked `now`, stage `FrameSchedule.rebase(now, interval)`, and stage the desired timer state from readiness. Install the timer before publishing `frame_interval_ns`, `frame_schedule`, or timer state. Zero surfaces update only the requested interval and retain an inactive schedule. Reload still applies pacing before scale/effect/palette ownership transfer; any clock/timer error deinitializes the candidate and preserves every old App field.

- [ ] **Step 7: Move the poll loop to one scheduling service per event batch**

Remove timer mutation from `syncSurfaces`. Immediately after the second startup `syncSurfaces()` and before the first poll preparation, call the checked-clock production scheduling service once. This startup service is what creates the first logical deadline and installs the first absolute one-shot when an initial surface is ready; without it a quiet compositor could leave the daemon asleep indefinitely. Preserve `flush -> prepare_read -> poll -> read/cancel -> dispatch_pending`. In a normal iteration:

1. dispatch/reconcile Wayland lifecycle;
2. consume timer readiness without directly advancing animation;
3. handle signal, IPC, and reload facts with shutdown precedence;
4. if still running, sample checked monotonic time once and call the production `serviceFrameScheduleAtWith`;
5. run the same service before the `prepare_read != 0` branch continues.

On any successful one-shot timer read, set `frame_timer_state = .disarmed` before decoding because the kernel expiration was consumed. A valid decoded count proves a timer event but does not directly advance animation. Every logical advance comes from `FrameSchedule.plan(now, frame_interval_ns)`. The initial-ready test covers scheduler state and timer installation; code review must additionally verify the production call is physically placed after startup surface reconciliation and before any path can block in `poll()`.

- [ ] **Step 8: Run GREEN and regression checks**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase4-t4 \
  zig build test-wayland-egl --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase4-t4-reload \
  zig build test-reload --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase4-t4-full \
  zig build test --summary all
zig fmt --check build.zig bench src tests
git diff --check
```

Expected: all success-path pacing, reload, existing animation, hotplug, GPU fallback, IPC, and full tests pass. Review the diff specifically for duplicate clocks, duplicate interval storage, callback rendering, refresh metadata use, stale repeating `it_interval` assignments, and allocation on blocked/no-change reconciliation. Do not commit yet: the following continuation is part of the same atomic implementation and prevents an intermediate revision from stranding rendering on a clock/timer failure.

#### Task 4 continuation: Harden one-shot read, clock, and timer failure liveness

**Files:**
- Modify: `src/app.zig`
- Modify: `tests/wayland_egl/frame_pacing_test.zig`
- Modify: `tests/wayland_egl/app_reload_test.zig`

**Interfaces:**
- Consumes: Task 4 scheduler and timer state.
- Produces: same-iteration read-anomaly recovery, relative one-shot clock fallback, bounded 100 ms poll retry, rate-limited diagnostics, and direct mutation rollback coverage.

- [ ] **Step 9: Write RED injected-failure tests**

Add concrete clock and reader fakes alongside Task 4's timer/frame fakes:

```zig
const FakeClock = struct {
    calls: usize = 0,
    value: u64 = 0,
    failure: ?anyerror = null,

    pub fn now(self: *@This()) !u64 {
        self.calls += 1;
        if (self.failure) |err| return err;
        return self.value;
    }
};

const FakeReader = struct {
    calls: usize = 0,
    bytes: [8]u8 = std.mem.zeroes([8]u8),
    result_len: usize = 8,
    failure: ?anyerror = null,

    pub fn read(self: *@This(), _: posix.fd_t, out: []u8) !usize {
        self.calls += 1;
        if (self.failure) |err| return err;
        const len = @min(self.result_len, out.len);
        @memcpy(out[0..len], self.bytes[0..len]);
        return len;
    }
};

test "EAGAIN after timer readiness cannot strand a ready surface" {
    var fixture: PacingFixture = undefined;
    try fixture.init(1, 20);
    defer fixture.deinit();
    fixture.app.frame_schedule = try FrameSchedule.begin(100, 20);
    App.TestAdapter.seedFrameTimerAbsolute(&fixture.app, 120);
    var reader = FakeReader{ .failure = error.WouldBlock };
    App.TestAdapter.consumeFrameTimer(&fixture.app, FakeReader, &reader);

    try std.testing.expectEqual(App.TestAdapter.TimerMode.disarmed, App.TestAdapter.timerMode(&fixture.app));
    try std.testing.expectEqual(@as(f64, 0), fixture.app.animation.phase);

    var timer = FakeTimer{};
    var ops = FakeFrameOps{ .ready = true };
    try App.TestAdapter.serviceFrameScheduleAt(
        &fixture.app,
        110,
        FakeTimer,
        &timer,
        FakeFrameOps,
        &ops,
    );
    try std.testing.expectEqual(@as(usize, 1), timer.calls);
    try std.testing.expect(timer.last_flags.?.ABSTIME);
    try std.testing.expectEqual(@as(i64, 120), timer.last_spec.?.it_value.nsec);
}

test "ordinary clock failure installs relative recovery when ready and disarmed" {
    var fixture: PacingFixture = undefined;
    try fixture.init(1, 20);
    defer fixture.deinit();
    fixture.app.frame_schedule = try FrameSchedule.begin(100, 20);
    var clock = FakeClock{ .failure = error.ClockGetTimeFailed };
    var timer = FakeTimer{};
    var ops = FakeFrameOps{ .ready = true };

    App.TestAdapter.serviceFrameSchedule(
        &fixture.app,
        FakeClock,
        &clock,
        FakeTimer,
        &timer,
        FakeFrameOps,
        &ops,
    );

    try std.testing.expectEqual(@as(usize, 1), timer.calls);
    try std.testing.expect(!timer.last_flags.?.ABSTIME);
    try std.testing.expectEqual(@as(i64, 20), timer.last_spec.?.it_value.nsec);
    try std.testing.expectEqual(@as(i64, 0), timer.last_spec.?.it_interval.nsec);
    try std.testing.expectEqual(App.TestAdapter.TimerMode.relative_recovery, App.TestAdapter.timerMode(&fixture.app));
    try std.testing.expectEqual(@as(f64, 0), fixture.app.animation.phase);
}
```

Add the remaining cases with these exact inputs and assertions:

| Test | Setup | Required outcome |
|---|---|---|
| `short successful timer read clears trust and preserves animation until reconciliation` | reader returns four bytes after absolute timer 120 | timer belief becomes disarmed; decode error recorded; animation/fade/schedule unchanged; same-iteration service arms or renders |
| `EINTR after timer readiness cannot strand a ready surface` | reader returns `error.Interrupted`, ready before deadline | same result as EAGAIN: absolute original deadline is reinstalled |
| `zero expiration record never directly advances or renders` | exact native-endian zero record | timer belief clears; decoder rejects; only later ordinary service may act from checked time |
| `ordinary clock failure preserves a trusted installed timer` | absolute timer 120 already trusted, clock fails | zero timer syscalls, absolute 120 remains trusted, recovery pending false |
| `failed relative recovery clamps poll timeout to 100ms` | disarmed/ready, clock and relative timer both fail | recovery pending true and `pollTimeoutAt` is 100 when no shorter IPC deadline exists |
| `recovery pending bounds poll with no clients or reload` | no IPC client, no reload job, recovery pending true | `ipcPollTimeout()` returns at most 100 rather than its ordinary `-1`; injected monotonic failure still returns 100 |
| `failed absolute arm while ready enters bounded recovery` | checked time before deadline, disarmed/ready, absolute timer call fails | schedule/deadline retained, timer belief disarmed, recovery pending true, poll timeout at most 100 ms |
| `failed disarm preserves the prior trusted timer belief` | blocked surface, absolute timer 120, disarm call fails | timer belief remains absolute 120, overdue schedule is not consumed, later timer/event can retry |
| `successful absolute arm clears recovery pending` | recovery pending true, checked now before deadline, absolute arm succeeds | recovery pending false and timer state absolute at retained deadline |
| `set-fps clock failure preserves interval schedule and kernel belief` | one ready surface, old interval 20/deadline 120, fake clock fails, request 10 | returned clock error, zero timer calls, every old pacing field unchanged |
| `reload clock failure frees candidate and preserves every App field` | existing full reload fixture, fake clock fails before pacing install | candidate deinitialized exactly once and the same full-field equality matrix as the existing timer-failure test passes |

For a malformed read with an overdue ready surface, distinguish “the invalid record did not advance” from the later ordinary reconciliation that may legitimately coalesce time and render.

- [ ] **Step 10: Run RED**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase4-t5-red \
  zig build test-wayland-egl --summary all
```

Expected: failures identify absent reader injection, recovery timer, and clock-rollback behavior.

- [ ] **Step 11: Implement timer-read state invalidation**

Extract the poll-ready read path behind:

```zig
fn consumeFrameTimerWith(
    self: *App,
    comptime Reader: type,
    reader: *Reader,
) void;
```

Expose a test adapter that forwards exactly those arguments:

```zig
pub fn consumeFrameTimer(
    app: *App,
    comptime Reader: type,
    reader: *Reader,
) void {
    app.consumeFrameTimerWith(Reader, reader);
}
```

After poll reports readiness, every successful read clears trusted timer state before decode. Every read error also invalidates the prior belief because a future timer wake is no longer trusted. Neither path mutates animation, fade, deadline, or surfaces. The end-of-batch scheduler then renders or installs a future wake in the same iteration.

- [ ] **Step 12: Implement normal reconciliation fallback without weakening mutation atomicity**

Production scheduling uses:

```zig
fn serviceFrameSchedule(self: *App) void {
    const now_ns = sys.monotonicNsChecked() catch |err| {
        self.recoverFrameTimerWithoutClock(err);
        return;
    };
    var timer = FrameTimer{};
    var frame_ops = ProductionFrameOps{};
    self.serviceFrameScheduleAtWith(
        now_ns,
        FrameTimer,
        &timer,
        ProductionFrameOps,
        &frame_ops,
    ) catch |err| {
        self.noteFrameTimerMutationFailure(err);
    };
}
```

The injectable test wrapper has this exact signature:

```zig
pub fn serviceFrameSchedule(
    app: *App,
    comptime Clock: type,
    clock: *Clock,
    comptime Timer: type,
    timer: *Timer,
    comptime FrameOps: type,
    frame_ops: *FrameOps,
) void;
```

It calls `Clock.now`; on success it delegates to Task 4's `serviceFrameScheduleAtWith`, converting an ordinary timer mutation error into `timer_recovery_pending` plus rate-limited diagnostics, and on clock error it delegates to the recovery path using the supplied Timer/FrameOps. `noteFrameTimerMutationFailure` never changes the retained logical deadline or invents a trusted timer state.

`recoverFrameTimerWithoutClock` leaves an existing `.absolute` or `.relative_recovery` timer unchanged. If no timer is trusted and a surface is ready, it installs one relative one-shot at the existing `frame_interval_ns`; success sets `.relative_recovery`. Failure sets `timer_recovery_pending = true`. This fallback is never called by `applyFrameIntervalWith` or reload; mutation clock failures return without any syscall.

- [ ] **Step 13: Add bounded retry to the existing poll timeout calculation**

When `timer_recovery_pending` is true, combine the existing IPC/reload timeout with:

```zig
const recovery_cap_ms: i32 = 100;

fn frameRecoveryTimeoutMs(self: *const App, now_ns: u64) i32 {
    const deadline = self.frame_schedule.next_logical_deadline_ns orelse
        return recovery_cap_ms;
    if (deadline <= now_ns) return 0;
    const remaining_ns = deadline - now_ns;
    const rounded_ms = (remaining_ns +| (std.time.ns_per_ms - 1)) /
        std.time.ns_per_ms;
    return @intCast(@min(@as(u64, recovery_cap_ms), rounded_ms));
}

timeout_ms = minPollTimeout(
    timeout_ms,
    self.frameRecoveryTimeoutMs(now_ns),
);
```

The recovery flag must also participate in `ipcPollTimeout()` before its early return:

```zig
var has_deadline = self.ipc_client != null or self.timer_recovery_pending;
// Preserve the existing reload phase scan, extending has_deadline as today.
if (!has_deadline) return if (loading_reload) 500 else -1;

const now_ns = self.reload_ops.monotonic_ns(self.reload_ops.context) catch |err| {
    // Preserve existing bounded-client cleanup and diagnostics.
    return if (self.timer_recovery_pending)
        recovery_cap_ms
    else if (self.reload_job != null)
        500
    else
        -1;
};
return self.pollTimeoutAt(now_ns);
```

Thus recovery remains bounded even when there is no IPC client, no reload job, or no readable monotonic clock. When a checked current time and future logical deadline are available, use the smaller of 100 ms and the rounded-up remaining deadline duration. A successful absolute or relative arm clears `timer_recovery_pending`. Rate-limit repeated timer diagnostics with `last_timer_error_log_ns` to at most one per second; when no valid time exists, log only the first transition into the pending episode.

- [ ] **Step 14: Run focused and all-mode GREEN**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase4-t5 \
  zig build test-wayland-egl --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase4-t5-reload \
  zig build test-reload --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase4-t5-full \
  zig build test --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase4-t5-safe \
  zig build test -Doptimize=ReleaseSafe --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase4-t5-fast \
  zig build test -Doptimize=ReleaseFast --summary all
zig fmt --check build.zig bench src tests
git diff --check
```

Expected: injected faults prove a future wake or render opportunity remains; mutation errors prove complete rollback; all optimization modes pass.

- [ ] **Step 15: Commit the atomic callback-led pacing migration**

```sh
git add build.zig src/app.zig tests/wayland_egl/app_reload_test.zig \
  tests/wayland_egl/frame_pacing_test.zig
git commit -m "perf(app): make frame pacing callback-aware"
```

---

### Task 5: Update the maintainer contracts and run the full automated gate

**Files:**
- Modify ignored in the primary checkout: `/home/px/wlchroma/specs/006-output-hotplug/contracts/runtime-behavior.md`
- Modify ignored in the primary checkout: `/home/px/wlchroma/specs/006-output-hotplug/data-model.md`
- Modify ignored in the primary checkout: `/home/px/wlchroma/specs/006-output-hotplug/spec.md`
- Modify ignored in the primary checkout: `/home/px/wlchroma/specs/006-output-hotplug/quickstart.md`
- Modify if implementation diverged: `docs/design/2026-08-05-phase-4-callback-aware-frame-pacing-design.md`
- Create ignored evidence: `.superpowers/sdd/phase4-automated-verification.md`

**Interfaces:**
- Consumes: completed production code and deterministic tests.
- Produces: contract parity, safe manual runbook, reproducible automated evidence, and a clean review candidate.

- [ ] **Step 1: Update the ignored timer/hotplug contracts**

Edit the maintainer-local ignored spec only in the primary checkout at `/home/px/wlchroma`; do not create a duplicate ignored copy inside a temporary implementation worktree. Make the contract say explicitly:

```text
- zero surfaces: timer and logical timeline paused;
- all renderable surfaces callback-blocked: timer disarmed, logical deadline retained;
- callback before deadline: one absolute timer for the original deadline;
- callback after deadline: one coalesced logical advance and one render pass;
- requested FPS remains query/config truth; output refresh metadata is not a cap;
- set-fps while paused is used on the next readiness transition.
```

Replace the unsafe `pgrep -n` and unguarded `niri msg output <name> off` quickstart instructions with exact PID capture and the independently verified systemd-user recovery procedure. Add the callback-blocked no-periodic-wake outcome to the formal spec/success criteria. Do not force-add ignored specs.

- [ ] **Step 2: Confirm README parity deliberately**

Run:

```sh
rg -n "fps|set-fps|frame|refresh|hotplug|output" README.md
```

Expected: no README change is required because public config, IPC, FPS progression, visual behavior, and fallback contracts are preserved. If implementation changed any of those facts, stop and update README before continuing.

- [ ] **Step 3: Run the complete local verification matrix with isolated caches**

```sh
zig version
test "$(zig version)" = "0.16.0"
zig fmt --check build.zig bench src tests
git diff --check
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase4-debug zig build
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase4-debug \
  zig test src/config/config.zig
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase4-debug \
  zig build test-wayland-egl --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase4-debug \
  zig build test --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase4-safe \
  zig build test -Doptimize=ReleaseSafe --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase4-fast \
  zig build test -Doptimize=ReleaseFast --summary all
```

The full graph requires host syscall access for the established Unix-socket tests. Record actual totals and output; do not copy historical counts or represent a sandbox socket failure as a product failure.

- [ ] **Step 4: Record static and automated evidence**

Write `.superpowers/sdd/phase4-automated-verification.md` with commit range, Zig version, every exact command/exit status/test total, formatter/diff results, fault matrix, and remaining live gates. Keep it ignored and do not include it in a commit.

- [ ] **Step 5: Request two-stage code review and fix findings before live testing**

Use fresh subagents for:

1. requirements/spec compliance across the committed design and this plan;
2. code quality, Zig overflow/optional/union safety, timerfd semantics, Wayland callback lifetime, failure liveness, and performance regressions.

Any finding is returned to the responsible task implementer, re-reviewed, and followed by `zig build test-wayland-egl --summary all` plus `zig build test --summary all`. Do not proceed to output-off or runtime replacement with an open Critical or Important finding.

- [ ] **Step 6: Commit tracked contract corrections only if applicable**

Ignored specs remain local. If the tracked design needed a correction:

```sh
git add docs/design/2026-08-05-phase-4-callback-aware-frame-pacing-design.md
git commit -m "docs(renderer): align frame pacing design"
```

Otherwise make no empty documentation commit.

---

### Task 6: Measure live behavior, close the audit follow-up, and restore cairn

**Files:**
- Modify after evidence exists: `docs/security/2026-07-19-security-performance-audit.md`
- Create ignored evidence: `.superpowers/sdd/phase4-live-verification.md`
- Do not modify: the four root untracked audit/transcript files.

**Interfaces:**
- Consumes: reviewed candidate, retained pre-Phase-4 baseline commit `8ffc2fa`, current Niri session, current exact daemon/service/output state.
- Produces: measured baseline/candidate evidence, safe restoration, final audit disposition, remote CI gate, and a clean main branch candidate.

- [ ] **Step 1: Capture current live state before changing any process**

Read and record:

```sh
printf '%s\n' "$WAYLAND_DISPLAY" "$NIRI_SOCKET" "$XDG_RUNTIME_DIR"
niri --version
niri msg outputs
systemctl --user status mpris-chroma.service --no-pager
wlchroma-ctl query
```

Resolve the exact wlchroma PID, `/proc/<pid>/exe`, argv, cwd, executable hash, socket, config hash/path, output mode/scale/transform/VRR, and service state. Do not reuse historical PID/socket/output facts.

- [ ] **Step 2: Build reproducible baseline and candidate binaries**

At execution time, use `superpowers:using-git-worktrees` for an isolated implementation branch. Build ReleaseSafe baseline from detached commit `8ffc2fa` and candidate from the reviewed head into separate `/tmp` prefixes with separate caches. Record SHA-256 hashes and Zig version. Remove temporary worktrees only after evidence and restoration are complete.

Use a private runtime directory for each isolated IPC socket while preserving access to the exact current compositor socket through a validated absolute `WAYLAND_DISPLAY` path. Before replacing the installed daemon, stop `mpris-chroma.service`, stop only the exact captured wlchroma PID through its control socket, and verify that PID exited. Restore the service only after the intended test daemon is responsive.

- [ ] **Step 3: Define the equal-window process measurement before running it**

Use sequential, never concurrent, 30-second baseline/candidate windows. For each exact PID capture deltas for:

```text
/proc/<pid>/stat       utime, stime
/proc/<pid>/status     voluntary_ctxt_switches, nonvoluntary_ctxt_switches
/proc/<pid>/io         syscr, rchar
/proc/<pid>/fdinfo/*   timerfd it_value and it_interval snapshots
```

Run the same config/effect/output and separate 15 FPS and 240 FPS lanes. Treat `syscr`, CPU ticks, and context switches as process wake/read proxies, not timerfd-specific tracing, GPU power, package power, or battery-life measurements. If `perf`/`strace` is unavailable, do not install packages without separate user authorization.

- [ ] **Step 4: Run non-disruptive visual/runtime lanes first**

For baseline then candidate:

1. 15 FPS GPU lane: query, visual cadence, fade, reload, effect switch, IPC responsiveness.
2. 240 FPS GPU lane: query still reports 240; motion retains baseline pace; candidate avoids periodic timerfd intervals while callbacks gate presentation.
3. Forced SHM candidate built with `-Dphase3a-force-shader-init-failure=true`: repeat cadence, fade, and IPC checks.
4. If a second physical output is available, run 15/240 mixed-refresh acceptance and verify the fast output is not capped by the slow output. If unavailable, record this as an unclaimed external gate.

Stop only the exact isolated PID/socket between lanes. Preserve the original executable for restoration.

- [ ] **Step 5: Ask for approval before the watchdog-protected output-off lane**

Before any output-off command:

1. show the exact current output name and recovery command;
2. create a transient systemd-user recovery service/timer for 30–45 seconds;
3. dry-run the service while the output is still on;
4. arm a fresh timer and prove both units active;
5. request explicit user approval for the exact `niri msg output <name> off` command.

Only after approval, verify zero recurring frame-timer wakeups, responsive IPC, callback recovery, and correct phase/fade recovery. Re-enable explicitly, then confirm both recovery units inactive. Never use a shell sleep as the only safeguard.

- [ ] **Step 6: Restore the exact original local runtime**

Restore the captured executable, argv, cwd, config, IPC query, `mpris-chroma.service`, and output state. Verify the running executable hash and exact PID rather than assuming the launcher used the intended binary. Remove only the temporary files/worktrees created by this phase after exact path checks.

- [ ] **Step 7: Record evidence and update the tracked audit ledger**

Write `.superpowers/sdd/phase4-live-verification.md` with commands, timings, `/proc` deltas, visual observations, watchdog proof, limitations, and restoration proof. Then append a Phase 4 section to `docs/security/2026-07-19-security-performance-audit.md` recording:

- Efficiency Audit 2 item 2.1 fixed;
- Efficiency Audit 3 item 3.3 fixed by callback-led absolute pacing without refresh metadata;
- Audit 2 item 2.2 already fixed and not reimplemented;
- commit range and independent review results;
- automated Debug/ReleaseSafe/ReleaseFast evidence;
- live 15/240 GPU and SHM evidence;
- side-by-side `/proc` measurements and their limits;
- mixed-output/output-off claims actually run versus still external;
- exact runtime restoration and remote CI status.

- [ ] **Step 8: Verify the evidence diff and commit closure**

```sh
git diff --check
git status --short
git diff -- docs/security/2026-07-19-security-performance-audit.md
git add docs/security/2026-07-19-security-performance-audit.md
git commit -m "docs(security): record phase 4 pacing evidence"
```

Confirm the staged diff contains no temporary evidence and none of the four root untracked files.

- [ ] **Step 9: Run final verification, integrate, push, and inspect remote CI**

Invoke `superpowers:verification-before-completion`, rerun the final formatter/diff/full test gates on the exact closing commit, then invoke `superpowers:finishing-a-development-branch`. After the user-selected integration path, push the intended branch/main and inspect every GitHub workflow result. Do not call Phase 4 complete until required CI is green and all locally available live gates are truthfully recorded.
