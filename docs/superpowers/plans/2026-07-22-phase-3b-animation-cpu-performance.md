# Phase 3B Animation and CPU Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace renderer-local frame counters with one precise App-owned ping-pong animation timeline, make CPU/SHM layout APIs explicitly safe, and remove the audited CPU fallback hot-path waste.

**Architecture:** `App` owns one bounded `AnimationState` advanced once from timerfd expirations and borrowed by every surface. CPU rendering uses checked typed grid layouts, row-major storage, cached palette colors, and a pure change-driven stand-in resolver. A dependency-free ReleaseFast benchmark brackets the implementation and gates optional framebuffer traversal complexity.

**Tech Stack:** Zig 0.16.0, Linux timerfd/Wayland SHM, EGL/GLESv2, `std.testing`, project build graph, Niri live acceptance.

## Global Constraints

- Close only `RENDER-M1`, `RENDER-L1`, and `PERF-L2` through `PERF-L6` in this phase.
- One App-owned phase is authoritative for every EGL and SHM output.
- Normal animation advancement adds no clock syscall, allocation, fd, wake-up, thread, context switch, or per-output mutation.
- Speed mutation preserves the current phase bit-for-bit and affects future deltas only.
- `PHASE_LIMIT` is exactly `16_384.0`; reflection, not sawtooth wrapping, keeps arbitrary shaders continuous.
- Zero outputs disarm the timer and preserve phase; output return continues from that phase.
- Effect-type switches reset animation, matching current behavior; palette and same-effect reloads do not.
- Timerfd data is used only after an exact 8-byte read.
- All externally influenced products and slice lengths are checked before the first write.
- Cell order is row-major in both producer and consumer after the migration commit.
- A stable SHM frame resolves its CPU effect once and performs zero palette rebuilds.
- No new public IPC command, dependency, protocol, worker thread, or shader appearance rewrite.
- Phase 3C retains ownership of asynchronous reload and atomic timer-reconfiguration failure reporting.
- Required correctness changes do not depend on benchmark timing. Optional traversal complexity must pass the recorded benchmark gate.
- Never use a name-wide process kill in live tests; capture and restore exact PID, executable, config, socket, output mode, and scale.

---

### Task 1: Add a stable ReleaseFast CPU benchmark and capture the baseline

**Files:**
- Create: `bench/cpu_path.zig`
- Modify: `build.zig`
- Modify: `src/test_exports.zig`
- Create ignored evidence: `.superpowers/sdd/phase3b-benchmark-baseline.md`

**Interfaces:**
- Consumes: current `ColormixRenderer.renderGrid`, `framebuffer.expandCells`, `Extent`, and `ShmLayout`.
- Produces: `zig build bench-cpu` with stable workload labels, checksums, batch counts, and median nanoseconds reused after every optimization.

- [ ] **Step 1: Export the benchmark dependencies**

Add these exports to `src/test_exports.zig`:

```zig
pub const colormix = @import("render/colormix.zig");
pub const framebuffer = @import("render/framebuffer.zig");
```

Do not export App, Wayland proxies, EGL objects, or test-only production adapters.

- [ ] **Step 2: Add the benchmark executable and step**

Add a dedicated ReleaseFast module near the test setup in `build.zig`:

```zig
const cpu_bench_sys_mod = b.createModule(.{
    .root_source_file = b.path("src/sys.zig"),
    .target = target,
    .optimize = .ReleaseFast,
});
const cpu_bench_src_mod = b.createModule(.{
    .root_source_file = b.path("src/test_exports.zig"),
    .target = target,
    .optimize = .ReleaseFast,
});
cpu_bench_src_mod.addImport("sys", cpu_bench_sys_mod);
cpu_bench_src_mod.addOptions("build_options", daemon_options);
const cpu_bench_mod = b.createModule(.{
    .root_source_file = b.path("bench/cpu_path.zig"),
    .target = target,
    .optimize = .ReleaseFast,
});
cpu_bench_mod.addImport("wlchroma_src", cpu_bench_src_mod);
cpu_bench_mod.addImport("sys", cpu_bench_sys_mod);
const cpu_bench_exe = b.addExecutable(.{
    .name = "wlchroma-cpu-bench",
    .root_module = cpu_bench_mod,
});
const run_cpu_bench = b.addRunArtifact(cpu_bench_exe);
const cpu_bench_step = b.step(
    "bench-cpu",
    "Benchmark ReleaseFast colormix and SHM expansion",
);
cpu_bench_step.dependOn(&run_cpu_bench.step);
```

The benchmark is not an install artifact and is not a dependency of `test`.

- [ ] **Step 3: Implement the fixed benchmark workload**

Create `bench/cpu_path.zig` with:

```zig
const std = @import("std");
const src = @import("wlchroma_src");
const sys = @import("sys");

const Rgb = src.defaults.Rgb;
const Extent = src.dimensions.Extent;
const ShmLayout = src.dimensions.ShmLayout;
const ColormixRenderer = src.colormix.ColormixRenderer;

const warmup_batches: usize = 3;
const measured_batches: usize = 9;
const frames_per_batch: usize = 16;

const Case = struct {
    label: []const u8,
    width: u32,
    height: u32,
    outputs: usize,
};

const cases = [_]Case{
    .{ .label = "1920x1200-1", .width = 1920, .height = 1200, .outputs = 1 },
    .{ .label = "1920x1200-2", .width = 1920, .height = 1200, .outputs = 2 },
    .{ .label = "2560x1440-1", .width = 2560, .height = 1440, .outputs = 1 },
    .{ .label = "2560x1440-2", .width = 2560, .height = 1440, .outputs = 2 },
    .{ .label = "3840x2160-1", .width = 3840, .height = 2160, .outputs = 1 },
    .{ .label = "3840x2160-2", .width = 3840, .height = 2160, .outputs = 2 },
};
```

Use a fixed palette, fixed renderer seed, fixed frame/time input, allocator-backed buffers allocated before timing, alternating framebuffer slices, and a checksum consumed after timing. Measure grid, expansion, combined stable-palette, and combined changing-palette workloads separately. Use `sys.monotonicNsChecked()` only around whole batches, sort nine durations, and print the median:

```zig
fn median(values: *[measured_batches]u64) u64 {
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    return values[values.len / 2];
}

fn report(label: []const u8, phase: []const u8, ns: u64, checksum: u64) void {
    std.debug.print(
        "bench {s} {s} median_ns={} checksum={x}\n",
        .{ label, phase, ns, checksum },
    );
}
```

- [ ] **Step 4: Verify benchmark determinism before treating it as evidence**

Run twice:

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3b-bench-base \
  zig build bench-cpu
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3b-bench-base \
  zig build bench-cpu
```

Expected:

- every workload label appears once per run;
- matching labels have identical checksums across runs;
- timings are nonzero;
- no allocation occurs inside a measured batch.

- [ ] **Step 5: Record baseline provenance**

Write `.superpowers/sdd/phase3b-benchmark-baseline.md` with:

- commit SHA and exact command;
- Zig version;
- CPU model and active governor read-only evidence;
- all workload medians and checksums;
- confirmation that the harness is ReleaseFast;
- a note that timing values are evidence, not unit-test thresholds.

- [ ] **Step 6: Run tests and commit**

```sh
zig fmt --check build.zig bench src tests
git diff --check
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3b-t1 \
  zig build test --summary all
git add build.zig bench/cpu_path.zig src/test_exports.zig
git commit -m "bench(renderer): add CPU path baseline"
```

The complete test run requires normal host Unix-socket access. Expected baseline: all tests pass and benchmark checksums are stable.

---

### Task 2: Add the bounded ping-pong AnimationState

**Files:**
- Create: `src/render/animation_state.zig`
- Create: `tests/animation_state_test.zig`
- Modify: `src/test_exports.zig`
- Modify: `build.zig`

**Interfaces:**
- Consumes: `defaults.TIME_SCALE` and validated config speed range `0.25...2.5`.
- Produces: `AnimationState.init`, `reset`, `setSpeed`, `advance`, and `time`.

- [ ] **Step 1: Add the failing pure-state tests and build wiring**

Export:

```zig
pub const animation_state = @import("render/animation_state.zig");
```

Create `tests/animation_state_test.zig` with tests for:

```zig
test "speed changes preserve phase and affect only future steps" {
    var animation = AnimationState.init(1.0);
    animation.advance(1);
    const before = animation.phase;
    animation.setSpeed(2.5);
    try std.testing.expectEqual(before, animation.phase);
    animation.advance(1);
    try std.testing.expectApproxEqAbs(
        before + 0.025,
        animation.phase,
        1e-12,
    );
}

test "upper reflection preserves overshoot and reverses continuously" {
    var animation = AnimationState{
        .phase = PHASE_LIMIT - 0.001,
        .speed = 0.25,
        .direction = .forward,
    };
    animation.advance(1);
    try std.testing.expectEqual(Direction.backward, animation.direction);
    try std.testing.expectApproxEqAbs(
        PHASE_LIMIT - 0.0015,
        animation.phase,
        1e-12,
    );
}

test "minimum-speed f32 time changes near the upper endpoint" {
    var animation = AnimationState{
        .phase = PHASE_LIMIT - 0.01,
        .speed = 0.25,
        .direction = .forward,
    };
    const first = animation.time();
    animation.advance(1);
    const second = animation.time();
    try std.testing.expect(first != second);
}
```

Also cover initialization, reset, lower reflection, multiple expirations, zero expirations, a count crossing multiple endpoints, and repeated bounds.

Wire the artifact into `test`. It does not need Wayland/EGL linkage.

- [ ] **Step 2: Run RED**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3b-t2-red \
  zig build test --summary all
```

Expected: compilation fails only because `animation_state.zig` and its declarations do not exist.

- [ ] **Step 3: Implement the normal and reflection paths**

Create:

```zig
const defaults = @import("../config/defaults.zig");

pub const PHASE_LIMIT: f64 = 16_384.0;
const CYCLE_LENGTH: f64 = PHASE_LIMIT * 2.0;

pub const Direction = enum { forward, backward };

pub const AnimationState = struct {
    phase: f64 = 0.0,
    speed: f32,
    direction: Direction = .forward,

    pub fn init(speed: f32) AnimationState {
        return .{ .speed = speed };
    }

    pub fn reset(self: *AnimationState, speed: f32) void {
        self.* = init(speed);
    }

    pub fn setSpeed(self: *AnimationState, speed: f32) void {
        self.speed = speed;
    }

    pub fn time(self: *const AnimationState) f32 {
        return @floatCast(self.phase);
    }

    pub fn advance(self: *AnimationState, expirations: u64) void {
        if (expirations == 0) return;
        const step = @as(f64, defaults.TIME_SCALE) *
            @as(f64, self.speed) *
            @as(f64, @floatFromInt(expirations));
        const distance = switch (self.direction) {
            .forward => PHASE_LIMIT - self.phase,
            .backward => self.phase,
        };
        if (step <= distance) {
            self.phase += switch (self.direction) {
                .forward => step,
                .backward => -step,
            };
            return;
        }
        self.fold(step);
    }
};
```

`fold` maps the current direction to a scalar position in `0...CYCLE_LENGTH`, adds the step, applies `@mod` once, and maps back to phase/direction. Normalize exact endpoints deterministically: zero is forward and `PHASE_LIMIT` is backward. Assert finite bounded state in Debug.

- [ ] **Step 4: Run GREEN and all optimization modes**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3b-t2 \
  zig build test --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3b-t2-safe \
  zig build test -Doptimize=ReleaseSafe --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3b-t2-fast \
  zig build test -Doptimize=ReleaseFast --summary all
zig fmt --check build.zig bench src tests
git diff --check
```

- [ ] **Step 5: Commit**

```sh
git add build.zig src/render/animation_state.zig src/test_exports.zig \
  tests/animation_state_test.zig
git commit -m "feat(renderer): add bounded animation state"
```

---

### Task 3: Make App animation authoritative and timerfd-driven

**Files:**
- Create: `src/render/timer_expirations.zig`
- Create: `tests/timer_expirations_test.zig`
- Modify: `src/app.zig`
- Modify: `src/render/effect.zig`
- Modify: `src/render/effect_shader.zig`
- Modify: `src/render/gpu_effect_state.zig`
- Modify: `src/render/colormix.zig`
- Modify: `src/render/glass_drift.zig`
- Modify: `src/render/glass_drift_shader.zig`
- Modify: `src/render/frond_haze.zig`
- Modify: `src/render/lumen_tunnel.zig`
- Modify: `src/render/velvet_mesh.zig`
- Modify: `src/render/starfield_fog.zig`
- Modify: `src/render/gyro_echo.zig`
- Modify: `src/render/hex_floret.zig`
- Modify: `src/render/dither_orb.zig`
- Modify: `src/render/signal_matrix.zig`
- Modify: `src/render/fract_lattice.zig`
- Modify: `src/wayland/surface_state.zig`
- Modify: `src/config/config.zig`
- Modify: `src/config/defaults.zig`
- Modify: `src/test_exports.zig`
- Modify: `src/test_wayland_exports.zig`
- Modify: `tests/effect_mutation_test.zig`
- Modify: `tests/wayland_egl/gpu_fallback_test.zig`
- Modify: `tests/wayland_egl/surface_detach_test.zig`
- Modify: `bench/cpu_path.zig`
- Modify: `build.zig`

**Interfaces:**
- Consumes: Task 2 `AnimationState`.
- Produces: `App.animation`, exact timerfd decoding, explicit `animation_time` shader/CPU inputs, and no renderer-owned timing fields.

- [ ] **Step 1: Add RED ownership and API tests**

Add tests that require:

```zig
test "App owns the only animation state" {
    try std.testing.expect(@hasField(App, "animation"));
    try std.testing.expect(!@hasDecl(Effect, "maybeAdvance"));
    try std.testing.expect(!@hasDecl(Effect, "frameCount"));
    try std.testing.expect(!@hasDecl(Effect, "setSpeed"));
    try std.testing.expect(!@hasField(GpuEffectState, "frames"));
    try std.testing.expect(!@hasField(GpuEffectState, "last_advance_ms"));
    try std.testing.expect(!@hasField(ColormixRenderer, "frames"));
}
```

Replace renderer-owned speed tests with App/AnimationState contract tests:

- same-effect speed update preserves phase;
- effect switch reset produces phase zero with the new speed;
- fallback conversion changes the effect tag without changing App phase.

Add a signature test proving `EffectShader.setUniforms` accepts a
plain `f32` animation time rather than deriving it from `Effect`.

- [ ] **Step 2: Add RED timer-expiration tests**

Create `tests/timer_expirations_test.zig`:

```zig
test "timer expiration decoder requires exactly eight bytes" {
    try std.testing.expectError(error.ShortRead, decode(&.{ 1, 2, 3, 4 }));
    try std.testing.expectError(error.LongRead, decode(&([_]u8{0} ** 9)));
}

test "timer expiration decoder uses native endian u64" {
    const value: u64 = 7;
    const bytes = std.mem.asBytes(&value);
    try std.testing.expectEqual(value, try decode(bytes));
}
```

Run the focused graph and confirm failures are due to the old ownership/API.

- [ ] **Step 3: Implement exact timer decoding**

```zig
const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{ ShortRead, LongRead, ZeroExpirations };

pub fn decode(bytes: []const u8) Error!u64 {
    if (bytes.len < @sizeOf(u64)) return error.ShortRead;
    if (bytes.len > @sizeOf(u64)) return error.LongRead;
    const value = std.mem.readInt(u64, bytes[0..8], builtin.cpu.arch.endian());
    if (value == 0) return error.ZeroExpirations;
    return value;
}
```

The main loop reads into `[8]u8`, checks the returned length through
`decode`, logs one bounded error on failure, and skips rendering for
that timer event. It never advances from undefined bytes.

- [ ] **Step 4: Move timing ownership into App**

Add:

```zig
const AnimationState = @import("render/animation_state.zig").AnimationState;

// App field
animation: AnimationState,

// App.init
.animation = AnimationState.init(config.speed),
```

In the timer branch, after a successful decode and before fade/render:

```zig
self.animation.advance(expirations);
```

Pass `&self.animation` into every newly created `SurfaceState`.
Do not add an animation pointer to listener userdata separately; it is a normal
borrowed field inside the already heap-stable surface.

- [ ] **Step 5: Remove timing fields from renderers**

`GpuEffectState` becomes:

```zig
pub const GpuEffectState = struct {
    phase_offset: f32,
    palette: [3]Rgb,

    pub fn init(palette: [3]Rgb) GpuEffectState {
        const seed: u64 = @import("sys").monotonicNs();
        var prng = std.Random.DefaultPrng.init(seed);
        return .{
            .phase_offset = prng.random().float(f32) * std.math.pi * 2.0,
            .palette = palette,
        };
    }
};
```

`ColormixRenderer` removes `frames`, timestamp gate,
`frame_advance_ms`, and `speed`. Its init accepts only three
colors. Its intermediate Task 3 render signature is:

```zig
pub fn renderGrid(
    self: *const ColormixRenderer,
    time: f32,
    grid_w: usize,
    grid_h: usize,
    out: []Rgb,
) void;
```

Remove `Effect.maybeAdvance`, `frameCount`, `speed`,
`setSpeed`, and `frameAdvanceMs`. Update constructors and
`fallbackToColormix` to contain renderer state only.

Every GPU renderer wrapper constructor accepts only its `[3]Rgb` palette and
delegates to `GpuEffectState.init(palette)`. Remove their forwarded cadence and
speed parameters; those values now belong exclusively to `App.animation`.

- [ ] **Step 6: Make time explicit in GPU and CPU draws**

Change:

```zig
pub fn setUniforms(
    self: *const EffectShader,
    animation_time: f32,
    resolution_w: f32,
    resolution_h: f32,
) void
```

Every arm forwards exactly `animation_time`. `SurfaceState`
stores:

```zig
animation: *const AnimationState,
```

GPU draw and SHM render both use `self.animation.time()`. The
configuration-time initial SHM render uses the same pointer. Remove animation
advancement from `frameCallbackDone` and remove `getMonotonicMs`.

- [ ] **Step 7: Define mutation semantics in App**

- `handleReload` with the same effect calls
  `self.animation.setSpeed(cfg.speed)` before palette publication.
- `switchEffect` calls `self.animation.reset(cfg.speed)` once
  after publishing the requested effect and palette but before fallback/config.
- IPC palette/color/fade handlers do not touch animation.
- Permanent fallback does not reset animation.
- Zero-output epoch closure does not reset animation.

Remove `AppConfig.frame_advance_ms` and its parser calculation/tests.
Remove the now-unused `defaults.FRAME_ADVANCE_MS` constant and its cadence
comment. Keep `frame_interval_ns` unchanged. This removes the stale private
cadence instead of adding another synchronization path.

- [ ] **Step 8: Run static invariants and GREEN graphs**

```sh
rg -n 'frameCount|frame_advance_ms|maybeAdvance|getMonotonicMs' src tests bench
rg -n 'effect\\.speed\\(|setSpeed\\(' src/render src/wayland
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3b-t3 \
  zig build test-wayland-egl --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3b-t3 \
  zig build test --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3b-t3-config \
  zig test src/config/config.zig
zig fmt --check build.zig bench src tests
git diff --check
```

Expected: legacy timing scans are empty except design/audit prose; all tests pass.

- [ ] **Step 9: Commit**

```sh
git add build.zig bench src tests
git commit -m "fix(renderer): centralize animation timing"
```

---

### Task 4: Extract a change-driven CPU stand-in resolver

**Files:**
- Create: `src/render/cpu_standin.zig`
- Create: `tests/cpu_standin_test.zig`
- Modify: `src/wayland/surface_state.zig`
- Modify: `src/render/effect.zig`
- Modify: `src/test_exports.zig`
- Modify: `src/test_wayland_exports.zig`
- Modify: `tests/wayland_egl/surface_detach_test.zig`
- Modify: `build.zig`

**Interfaces:**
- Consumes: renderer-only `Effect` from Task 3.
- Produces: `CpuStandin.resolve(source) *Effect` and
`CpuStandin.invalidate()` with change-driven palette synchronization.

- [ ] **Step 1: Add failing resolver tests**

Create tests for:

- native colormix returns the source pointer and clears an obsolete stand-in;
- first GPU-only resolve creates colormix from the source palette;
- a stable second resolve returns the identical stand-in pointer without
  rebuilding its palette;
- a source palette change rebuilds once and records the new palette;
- invalidate removes the cached effect and palette;
- invalidation followed by a GPU effect-type change creates a fresh stand-in.

Use a sentinel in `standin.effect.?.colormix.palette_data[0]` after the
first resolve; a stable second resolve must preserve it, proving
`updatePalette` was not called.

- [ ] **Step 2: Run RED**

Expected: missing `CpuStandin` module/type.

- [ ] **Step 3: Implement the pure resolver**

```zig
const std = @import("std");
const Effect = @import("effect.zig").Effect;
const Rgb = @import("../config/defaults.zig").Rgb;

pub const CpuStandin = struct {
    effect: ?Effect = null,
    source_palette: ?[3]Rgb = null,

    pub fn invalidate(self: *CpuStandin) void {
        self.* = .{};
    }

    pub fn resolve(self: *CpuStandin, source: *Effect) *Effect {
        const colors = source.gpuPalette() orelse {
            self.invalidate();
            return source;
        };
        if (self.effect == null or self.source_palette == null) {
            self.effect = Effect.initColormix(colors);
            self.source_palette = colors;
        } else if (!std.meta.eql(self.source_palette.?, colors)) {
            self.effect.?.updatePalette(colors);
            self.source_palette = colors;
        }
        return &self.effect.?;
    }
};
```

Add `Effect.initColormix(colors)` as a renderer-only constructor used
by fallback conversion and stand-ins.

- [ ] **Step 4: Integrate one resolution per SHM frame**

Replace `SurfaceState.shm_effect` with `cpu_standin: CpuStandin`.
In the SHM path:

```zig
const cpu_effect = self.cpu_standin.resolve(self.effect);
cpu_effect.renderGrid(
    self.animation.time(),
    self.grid_w,
    self.grid_h,
    self.cell_grid,
);
```

Resolve once and use that pointer for the whole frame. Configuration-time render
also resolves once. App effect switch and permanent fallback call
`cpu_standin.invalidate()` for each surface.

- [ ] **Step 5: Verify and commit**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3b-t4 \
  zig build test-wayland-egl --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3b-t4 \
  zig build test --summary all
zig fmt --check build.zig bench src tests
git diff --check
git add build.zig src tests
git commit -m "perf(renderer): cache CPU fallback stand-ins"
```

---

### Task 5: Introduce checked typed grid and framebuffer APIs

**Files:**
- Create: `src/render/cell_grid.zig`
- Create: `tests/cell_grid_test.zig`
- Modify: `src/wayland/dimensions.zig`
- Modify: `src/wayland/shm_pool.zig`
- Modify: `src/wayland/surface_state.zig`
- Modify: `src/render/colormix.zig`
- Modify: `src/render/effect.zig`
- Modify: `src/render/framebuffer.zig`
- Modify: `src/test_exports.zig`
- Modify: `tests/wayland_egl/dimensions_test.zig`
- Create: `tests/framebuffer_test.zig`
- Modify: `bench/cpu_path.zig`
- Modify: `build.zig`

**Interfaces:**
- Consumes: Task 3 explicit animation time and Task 4 resolved CPU effect.
- Produces: checked `CellGridLayout`, `ShmLayout.grid`,
fallible exact-length render/expand APIs, and `ShmPool.releaseBuffer`.

- [ ] **Step 1: Add failing CellGridLayout tests**

Cover:

```zig
test "grid preserves floor sizing and minimum one cell" {
    try std.testing.expectEqual(
        CellGridLayout{ .width = 192, .height = 67, .len = 12_864 },
        try CellGridLayout.initForPixels(1920, 1080),
    );
    try std.testing.expectEqual(
        CellGridLayout{ .width = 1, .height = 1, .len = 1 },
        try CellGridLayout.initForPixels(1, 1),
    );
}

test "fabricated grid metadata is rejected" {
    const bad = CellGridLayout{ .width = 2, .height = 3, .len = 5 };
    try std.testing.expectError(error.InvalidGridLength, bad.validate());
}
```

Add product-overflow coverage using fabricated `usize` dimensions.
`rowOffset` is tested only after `validate` and for
`y < height`.

- [ ] **Step 2: Implement CellGridLayout**

```zig
const std = @import("std");
const defaults = @import("../config/defaults.zig");

pub const GridError = error{ GridSizeOverflow, InvalidGridLength, RowOutOfBounds };

pub const CellGridLayout = struct {
    width: usize,
    height: usize,
    len: usize,

    pub fn initForPixels(
        pixel_width: u32,
        pixel_height: u32,
    ) error{GridSizeOverflow}!CellGridLayout {
        const width = @max(
            @divFloor(@as(usize, pixel_width), defaults.CELL_W),
            1,
        );
        const height = @max(
            @divFloor(@as(usize, pixel_height), defaults.CELL_H),
            1,
        );
        const len = std.math.mul(usize, width, height) catch
            return error.GridSizeOverflow;
        return .{ .width = width, .height = height, .len = len };
    }

    pub fn validate(
        self: CellGridLayout,
    ) error{ GridSizeOverflow, InvalidGridLength }!void {
        const expected = std.math.mul(usize, self.width, self.height) catch
            return error.GridSizeOverflow;
        if (expected != self.len) return error.InvalidGridLength;
    }

    pub fn rowOffset(self: CellGridLayout, y: usize) GridError!usize {
        try self.validate();
        if (y >= self.height) return error.RowOutOfBounds;
        return std.math.mul(usize, y, self.width) catch
            return error.GridSizeOverflow;
    }
};
```

- [ ] **Step 3: Make ShmLayout the single layout authority**

Replace `grid_w/grid_h/grid_len` with:

```zig
grid: CellGridLayout,
```

`ShmLayout.init` calls `CellGridLayout.initForPixels`.
Remove duplicate grid dimensions from `SurfaceState`. Allocation and
all render calls use `layout.grid.len` from the pool/replacement
transaction.

Add `error.InvalidShmLayout` to `LayoutError`, then add
`ShmLayout.validate()` which recomputes and compares stride,
`buffer_bytes`, `total_bytes`, both offsets, and the exact grid derived from
`extent`, using the same checked arithmetic/error set as `init`. This closes
the fabricated-layout case before `expandCells` trusts any public field.

- [ ] **Step 4: Add RED no-write-on-error tests**

For colormix rendering, initialize sentinel slices and require both short and
oversized outputs to return `error.OutputLengthMismatch` without
changing any sentinel.

For framebuffer expansion, require short/oversized cell and pixel slices to
return the exact mismatch error without changing the output.

Add a fabricated inconsistent grid inside a copied `ShmLayout` and
require rejection before writes.

- [ ] **Step 5: Implement fallible exact APIs**

```zig
pub const RenderGridError = cell_grid.GridError || error{OutputLengthMismatch};

pub fn renderGrid(
    self: *const ColormixRenderer,
    time: f32,
    grid: CellGridLayout,
    out: []Rgb,
) RenderGridError!void {
    try grid.validate();
    if (out.len != grid.len) return error.OutputLengthMismatch;

    for (0..grid.width) |x| {
        for (0..grid.height) |y| {
            const xi: i32 = @intCast(x);
            const yi: i32 = @intCast(y);
            const wi: i32 = @intCast(grid.width);
            const hi: i32 = @intCast(grid.height);
            var uvx = @as(f32, @floatFromInt(xi * 2 - wi)) /
                @as(f32, @floatFromInt(hi * 2));
            var uvy = @as(f32, @floatFromInt(yi * 2 - hi)) /
                @as(f32, @floatFromInt(hi));
            var uv2x = uvx + uvy;
            var uv2y = uvx + uvy;
            for (0..3) |_| {
                const len = vecLength(uvx, uvy);
                uv2x += uvx + len;
                uv2y += uvy + len;
                uvx += 0.5 * @cos(self.pattern_cos_mod + uv2y * 0.2 + time * 0.1);
                uvy += 0.5 * @sin(self.pattern_sin_mod + uv2x - time * 0.1);
                const warp = @cos(uvx + uvy) - @sin(uvx * 0.7 - uvy);
                uvx -= warp;
                uvy -= warp;
            }
            const len = vecLength(uvx, uvy);
            const palette_index = @mod(
                @as(usize, @intFromFloat(@floor(len * 5.0))),
                PALETTE_LEN,
            );
            const cell = self.palette[palette_index];
            out[x * grid.height + y] =
                palette_mod.blend(cell.fg, cell.bg, cell.alpha);
        }
    }
}
```

```zig
pub const ExpandError = dimensions.LayoutError || cell_grid.GridError || error{
    CellLengthMismatch,
    PixelLengthMismatch,
};

pub fn expandCells(
    cells: []const Rgb,
    pixel_buf: []u8,
    layout: ShmLayout,
) ExpandError!void {
    try layout.validate();
    if (cells.len != layout.grid.len) return error.CellLengthMismatch;
    if (pixel_buf.len != layout.buffer_bytes) return error.PixelLengthMismatch;

    const pw: usize = layout.extent.width;
    const ph: usize = layout.extent.height;
    for (0..layout.grid.height) |cy| {
        const py_start = cy * defaults.CELL_H;
        const py_end = if (cy + 1 < layout.grid.height)
            (cy + 1) * defaults.CELL_H
        else
            ph;
        if (py_start >= ph) break;
        const py_limit = @min(py_end, ph);

        for (0..layout.grid.width) |cx| {
            const px_start = cx * defaults.CELL_W;
            const px_end = if (cx + 1 < layout.grid.width)
                (cx + 1) * defaults.CELL_W
            else
                pw;
            if (px_start >= pw) break;
            const px_limit = @min(px_end, pw);
            const color = cells[cx * layout.grid.height + cy];
            const pixel: [4]u8 = .{ color.b, color.g, color.r, 0x00 };
            for (py_start..py_limit) |py| {
                const row_offset = py * pw;
                for (px_start..px_limit) |px| {
                    const base = (row_offset + px) * 4;
                    pixel_buf[base..][0..4].* = pixel;
                }
            }
        }
    }
}
```

`Effect.renderGrid` becomes fallible and returns
`error.NoCpuRenderer` for every GPU-only arm.

- [ ] **Step 6: Release acquired buffers on impossible render errors**

Add:

```zig
pub fn releaseBuffer(self: *ShmPool, idx: u1) void {
    self.busy[idx] = false;
}
```

After acquisition, use:

```zig
errdefer pool.releaseBuffer(idx);
try cpu_effect.renderGrid(...);
try framebuffer.expandCells(...);
```

Because `renderTick` returns `void`, put the fallible work in
a private helper returning an error. The caller logs once and returns. Do not
leave an `errdefer` in a scope that continues after successful
Wayland attachment.

Configuration remains transactional: render and expand the replacement before
destroying the old pool/grid.

- [ ] **Step 7: Verify and commit**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3b-t5 \
  zig build test-wayland-egl --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3b-t5 \
  zig build test --summary all
zig fmt --check build.zig bench src tests
git diff --check
git add build.zig bench src tests
git commit -m "fix(renderer): validate CPU grid layouts"
```

---

### Task 6: Convert cells to row-major and optimize colormix invariants

**Files:**
- Modify: `src/render/colormix.zig`
- Modify: `src/render/effect.zig`
- Modify: `src/render/framebuffer.zig`
- Modify: `tests/framebuffer_test.zig`
- Create: `tests/colormix_render_test.zig`
- Modify: `bench/cpu_path.zig`
- Modify: `build.zig`

**Interfaces:**
- Consumes: checked Task 5 layouts/APIs.
- Produces: atomic row-major producer/consumer, cached blended palette, and
hoisted invariant calculations.

- [ ] **Step 1: Add row-major RED tests**

Use a 2x2 cell grid with four unique colors:

```zig
const cells = [_]Rgb{
    red, green,
    blue, white,
};
```

Expand into an extent with one cell per quadrant and assert top-left red,
top-right green, bottom-left blue, bottom-right white. This must fail against
the column-major consumer.

Add a reference colormix renderer in the test that implements the old formulas
and maps expected coordinates to row-major indices. Compare every cell at
several fixed times and non-square grids.

- [ ] **Step 2: Add palette-cache RED tests**

Require:

- every cached blended entry equals `palette.blend` of its source cell;
- palette mutation rebuilds all 12 cached entries;
- rendering does not mutate either palette representation;
- cached and old per-cell blending produce identical RGB grids.

- [ ] **Step 3: Implement one palette rebuild method**

Add:

```zig
blended_palette: [12]Rgb,

pub fn rebuildPalette(self: *ColormixRenderer, colors: [3]Rgb) void {
    self.palette = palette_mod.buildPalette(colors[0], colors[1], colors[2]);
    self.palette_data = ColormixShader.buildPaletteData(&self.palette);
    for (self.palette, 0..) |cell, i| {
        self.blended_palette[i] =
            palette_mod.blend(cell.fg, cell.bg, cell.alpha);
    }
}
```

Initialization and `Effect.updatePalette` call this single method.
Expose it through a renderer method rather than duplicating palette-building
imports inside `effect.zig`.

- [ ] **Step 4: Switch producer and consumer atomically to row-major**

Colormix loops `y` outer, `x` inner and writes:

```zig
const row_base = try grid.rowOffset(y);
out[row_base + x] = self.blended_palette[palette_index];
```

Framebuffer reads:

```zig
const color = cells[cy * layout.grid.width + cx];
```

No commit may contain only one side of the migration.

- [ ] **Step 5: Hoist exact invariants**

Before both loops compute integer/float width and height, reciprocal height,
reciprocal double-height, and `time * 0.1`. Per row compute `yi`,
the vertical numerator/component, and row base. Preserve integer numerator
evaluation before conversion; do not accumulate floating x coordinates.

Keep the inner three-iteration warp in the exact existing order. Do not change
shader constants, palette-index rounding, or pattern seed.

- [ ] **Step 6: Run correctness and benchmark comparison**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3b-t6 \
  zig build test --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3b-bench-head \
  zig build bench-cpu
```

Compare checksums to the baseline logical workload. Expected RGB checksums are
identical. Record medians in
`.superpowers/sdd/phase3b-benchmark-head.md`.

- [ ] **Step 7: Verify and commit**

```sh
zig fmt --check build.zig bench src tests
git diff --check
git add build.zig bench src tests
git commit -m "perf(renderer): optimize row-major CPU rendering"
```

---

### Task 7: Evaluate the optional row-linear framebuffer fill

**Files:**
- Modify only if retained: `src/render/framebuffer.zig`
- Modify only if retained: `tests/framebuffer_test.zig`
- Update ignored evidence: `.superpowers/sdd/phase3b-benchmark-head.md`

**Interfaces:**
- Consumes: Task 6 row-major checked expansion and benchmark harness.
- Produces: either a benchmark-approved row-linear span fill or an explicit
rejected-candidate record with the simpler rectangle fill preserved.

- [ ] **Step 1: Record the Task 6 expansion medians**

Identify whether expansion remains a meaningful share of combined time. If it
does not, record `candidate not justified` and skip to Step 5 without
changing production code.

- [ ] **Step 2: Add a behavior-preserving candidate**

When justified, change traversal to cell row -> pixel row -> cell column and
write contiguous horizontal spans. Preserve partial final cells and exact
XRGB8888 bytes. Add tests for sub-cell extents, partial right/bottom edges,
and both buffer slices before benchmarking.

- [ ] **Step 3: Run the identical ReleaseFast benchmark**

Run at least three full benchmark invocations after warmup and compare median
of run medians. The candidate passes only when:

- combined median improves by at least 3% on two target sizes;
- no target regresses by more than 2%;
- checksums remain identical;
- no allocation moves into the timed region.

- [ ] **Step 4: Retain or revert the candidate cleanly**

If it passes, retain code/tests and commit:

```sh
git add src/render/framebuffer.zig tests/framebuffer_test.zig
git commit -m "perf(renderer): streamline SHM row fills"
```

If it fails, revert only the uncommitted candidate with `apply_patch`,
rerun formatting/tests, and record exact rejection medians. Do not create an
empty production commit and do not weaken the gate.

- [ ] **Step 5: Review the benchmark evidence**

An independent reviewer checks commands, checksums, baseline/head provenance,
governor context, retention arithmetic, and that no required correctness change
was reverted based on timing.

---

### Task 8: Complete automated, live, review, and audit closeout

**Files:**
- Modify after evidence/review: `docs/security/2026-07-19-security-performance-audit.md`

**Interfaces:**
- Consumes: Tasks 1-7 and the approved Phase 3B design.
- Produces: whole-branch approval, benchmark/live evidence, and Fixed
dispositions for all seven Phase 3B findings.

- [ ] **Step 1: Run static invariants**

```sh
zig fmt --check build.zig bench src tests
git diff --check
rg -n 'frameCount|frame_advance_ms|maybeAdvance|getMonotonicMs' src tests bench
rg -n 'x \\* grid.*height|cx \\*.*grid.*height|column-major' src tests bench
rg -n 'cpu_standin\\.resolve' src/wayland/surface_state.zig
rg -n 'monotonicNs|clock_gettime' src/wayland src/render
```

Expected:

- removed timing/column-major scans have no production match;
- exactly one CPU-effect resolution appears in each SHM render/config helper;
- normal animation rendering contains no clock call;
- debug telemetry and fade-only App clock calls are documented separately.

- [ ] **Step 2: Run complete build/test matrices**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3b-debug zig build --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3b-debug \
  zig build test-wayland-egl --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3b-debug \
  zig build test --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3b-config \
  zig test src/config/config.zig
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3b-safe \
  zig build -Doptimize=ReleaseSafe --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3b-safe \
  zig build test -Doptimize=ReleaseSafe --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3b-fast \
  zig build -Doptimize=ReleaseFast --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase3b-fast \
  zig build test -Doptimize=ReleaseFast --summary all
```

Use host Unix-socket permission for the complete graph. Record exact totals.

- [ ] **Step 3: Run and record final benchmarks**

Run baseline-compatible and final benchmark commands under the same power
context. Report every median/checksum and calculated percent change. Also
report structural counts: clock calls per timer tick, palette rebuilds for
stable/changed palettes, and CPU-effect resolutions.

- [ ] **Step 4: Prepare safe live acceptance**

Read exact current PID/executable/argv/cwd/unit, IPC socket/query, config hash,
Niri socket, and output state. Build isolated ReleaseSafe normal and forced
shader-failure binaries/configs. Stop only through the exact IPC socket. Arm
and dry-run an explicit user-systemd output recovery action before disabling
the final output.

- [ ] **Step 5: Run timing and CPU live tests**

Verify:

- same-effect speed 0.25 -> 2.5 changes no phase immediately and increases only
  future motion on normal EGL;
- the same behavior under forced SHM;
- stable SHM frames produce no palette rebuild/retry warnings;
- output disable, palette/speed mutation while output-less, and watchdog return
  retain the authoritative phase/settings;
- resize and output return have fully painted right/bottom edges and no busy
  buffer starvation;
- IPC remains responsive and logs contain no layout, EGL, ownership,
  allocation, timer-read, or retry warning.

If screenshot approval is unavailable, use deterministic phase/query/log/fd
evidence and explicitly leave visual pixel claims unclaimed. If only one output
exists, record multi-output hardware acceptance as unavailable.

- [ ] **Step 6: Restore the original session exactly**

Stop isolated daemons through their exact sockets, collect transient units,
remove inspected temporary files, restart the captured original executable and
config, then verify PID/query/config hash and every output mode/scale.

- [ ] **Step 7: Request whole-branch independent review**

Generate a review package from `5bdc843` through HEAD. Reviewer checks
the design, plan, all task reports/diffs, benchmark arithmetic, static scans,
test matrices, live evidence, pointer lifetimes, error paths, ReleaseFast
arithmetic, and every finding disposition. Critical/Important findings are
fixed and re-reviewed; Minor findings are fixed or explicitly dispositioned.

- [ ] **Step 8: Update the audit ledger only after approval**

Change only these rows to Fixed with exact commits:

- `RENDER-M1`;
- `RENDER-L1`;
- `PERF-L2`;
- `PERF-L3`;
- `PERF-L4`;
- `PERF-L5`;
- `PERF-L6`.

Append the Phase 3B completion record with implementation commits, exact test
totals, benchmark commands/medians/checksums/percent changes, operation counts,
review evidence, live environment/watchdog evidence, restoration proof, and
unavailable screenshot/multi-output limitations. Preserve original finding
descriptions.

- [ ] **Step 9: Commit closeout**

```sh
git add docs/security/2026-07-19-security-performance-audit.md
git commit -m "docs(security): close phase 3b renderer findings"
git status --short --branch
```

Expected: clean branch, all seven Phase 3B rows Fixed, original session
restored, and no journal entry yet.
