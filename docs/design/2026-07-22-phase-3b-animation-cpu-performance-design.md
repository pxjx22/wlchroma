# Phase 3B Animation and CPU Performance Design

Date: 2026-07-22

## Scope

Phase 3B closes these audit findings:

- `RENDER-M1`: runtime speed changes jump GPU phase, while CPU colormix
  ignores speed.
- `RENDER-L1`: `renderGrid` accepts independently inconsistent dimensions and
  output slices.
- `PERF-L2`: GPU-only SHM stand-ins resolve and rebuild palette state twice per
  rendered frame.
- `PERF-L3`: every CPU-rendered output samples the monotonic clock separately.
- `PERF-L4`: colormix repeats invariant conversions and palette blending in
  its hot grid loop.
- `PERF-L5`: column-major cell storage produces strided reads during
  row-oriented framebuffer expansion.
- `PERF-L6`: ever-growing frame counters lose animation precision at the
  GLES `f32` boundary.

The phase also removes the adjacent stale-cadence defect in which runtime FPS
changes update the timer interval but not the active effect's private
`frame_advance_ms`. Phase 3C still owns atomic reporting and rollback when a
timer reconfiguration fails (`APP-L2`).

Out of scope:

- asynchronous config reload and parser/build metadata work from Phase 3C;
- new effects, shader appearance changes, or public IPC commands;
- changing the configured relationship between FPS and animation rate;
- a new rendering thread or worker pool;
- GPU shader rewrites for forward-only infinite time.

## Goals and invariants

1. One authoritative animation phase is consumed by every GPU and SHM output.
2. A speed mutation leaves the current phase unchanged and affects only future
   timer steps.
3. Animation remains continuous and representable for unlimited daemon uptime.
4. Normal animation advancement adds no clock syscall, allocation, fd, poll
   wake-up, thread, EGL context switch, or per-output work.
5. Zero outputs still disarm the timer and pause animation. Output return
   continues from the retained phase.
6. All CPU grid and framebuffer lengths are validated before the first write.
7. Row-major cell order is used consistently by producer and consumer.
8. Stable CPU frames perform zero palette rebuilds and resolve the CPU effect
   once.
9. Required safety changes do not depend on benchmark results. Optional hot
   loop changes are retained only with measurable evidence and no regression.

## Chosen architecture

### 1. App-owned animation state

`App` owns one `AnimationState` in `src/render/animation_state.zig`:

```zig
pub const Direction = enum { forward, backward };

pub const AnimationState = struct {
    phase: f64,
    speed: f32,
    direction: Direction,

    pub fn init(speed: f32) AnimationState;
    pub fn reset(self: *AnimationState, speed: f32) void;
    pub fn setSpeed(self: *AnimationState, speed: f32) void;
    pub fn advance(self: *AnimationState, expirations: u64) void;
    pub fn time(self: *const AnimationState) f32;
};
```

`PHASE_LIMIT` is `16_384.0`. The state uses `f64` internally and reflects at
both endpoints rather than wrapping:

- a normal accepted timer expiration advances by
  `TIME_SCALE * current_speed`;
- `setSpeed` changes only the future step size;
- reaching the upper endpoint reflects the overshoot and changes direction;
- reaching zero reflects the overshoot and changes direction again;
- `time()` performs the only bounded conversion to `f32`.

At the upper endpoint, `f32` spacing is `0.001953125`, below the smallest
valid step (`TIME_SCALE * 0.25 == 0.0025`). Minimum-speed animation therefore
continues to produce distinguishable shader times. Reflection is continuous
for arbitrary shader expressions; unlike modular reset, it cannot introduce a
time discontinuity. The deliberate long-period behavior is that motion
eventually retraces its trajectory.

The normal `expirations == 1` path is one `f64` multiply/add, one comparison,
and a predictable no-reflection branch. A rare large expiration count uses a
bounded triangular-wave fold so it cannot loop once per missed tick. No modulo
or division is executed on the normal path.

### 2. Timerfd is the animation clock

The main loop already reads the timerfd once per render event. Phase 3B decodes
the returned native-endian `u64` expiration count and advances the App-owned
animation state once before rendering surfaces.

- An exact 8-byte read is required. Read failure or a short read logs the
  failure and skips that timer event without interpreting undefined bytes.
- Multiple expirations advance by the corresponding number of logical frame
  steps, preserving elapsed timer cadence after a temporary stall.
- When the timer is disarmed at zero outputs, no phase is advanced.
- Frame callbacks only destroy/clear their callback and no longer mutate
  animation state.
- Palette fades remain wall-clock based and request one monotonic sample only
  while a fade is active. Normal animation adds no clock syscall.
- Debug-only performance telemetry may continue to sample the clock and is not
  part of ReleaseSafe or ReleaseFast hot-path accounting.

This preserves the existing FPS-dependent animation cadence: one configured
timer step advances one logical phase step. A successful FPS change needs only
to reconfigure the timer. Renderer-private `frame_advance_ms` and timestamp
gates are removed, so they cannot become stale.

### 3. Stable borrowing and effect lifecycle

`SurfaceState` already borrows the stable address of `App.effect`. It will also
borrow `*const AnimationState` from the final App storage. The pointer is
installed only after `App` is in its final stack location, and every surface
is destroyed before App teardown, matching the existing listener-userdata
lifetime proof.

The effect lifecycle is:

- App initialization creates `Effect` plus `AnimationState.init(config.speed)`.
- Same-effect reload calls `animation.setSpeed`; the current phase is
  bit-identical before and after the mutation.
- Effect-type switch replaces the effect and calls
  `animation.reset(config.speed)`, preserving the current reset-on-switch
  behavior.
- Palette updates do not touch animation.
- Permanent GPU fallback replaces only renderer/effect state; the App-owned
  animation phase remains authoritative.
- Output removal/recreation does not move or reset the animation state.

Timing fields and APIs are removed from `GpuEffectState`,
`ColormixRenderer`, and `Effect`: duplicated frame counters, timestamp gates,
cadence, `frameCount`, `maybeAdvance`, renderer-owned `speed`, and
`frameAdvanceMs` no longer exist. `EffectShader.setUniforms` receives the
bounded animation time explicitly.

## CPU fallback data flow

### 4. One resolution and change-driven stand-ins

Each SHM render tick follows this order:

1. complete dead/configured/frame-callback checks;
2. acquire one free SHM buffer;
3. resolve `cpuEffect()` exactly once;
4. synchronize a GPU-only colormix stand-in only if its source palette changed;
5. render using `self.animation.time()`;
6. expand cells into the acquired buffer;
7. attach, damage, arm the callback, and commit.

GPU-only stand-ins no longer own or advance animation. They contain only the
colormix pattern and palette data needed for CPU rendering. `SurfaceState`
stores the last synchronized source palette. A stable palette performs a
fixed comparison and zero rebuilds. A fade or palette mutation rebuilds each
affected stand-in once for that changed palette, never twice in one frame.

If rendering or expansion rejects an invariant after buffer acquisition, the
busy bit for that buffer is released before returning. No failed frame can
permanently starve the double buffer.

Configuration-time first render uses the same borrowed animation state, so a
new or hotplugged SHM surface begins at the current phase rather than zero.

## Checked row-major grid design

### 5. Typed cell layout

`src/render/cell_grid.zig` defines the renderer-neutral layout:

```zig
pub const CellGridLayout = struct {
    width: usize,
    height: usize,
    len: usize,

    pub fn initForPixels(width: u32, height: u32) GridError!CellGridLayout;
    pub fn validate(self: CellGridLayout) GridError!void;
    pub fn rowOffset(self: CellGridLayout, y: usize) usize;
};
```

The grid preserves the existing floor-based formula and minimum of one cell
per dimension. It calculates `width * height` with checked arithmetic and
rejects inconsistent fabricated values. `ShmLayout` owns a `grid` value and
removes the separate `grid_w`, `grid_h`, and `grid_len` fields.

`SurfaceState` removes its duplicate grid dimensions. The grid slice, pool,
pixel extent, and grid layout are always derived from the same checked
`ShmLayout` transaction.

### 6. Fallible exact-length APIs

The CPU APIs become:

```zig
pub fn renderGrid(
    self: *const ColormixRenderer,
    time: f32,
    grid: CellGridLayout,
    out: []Rgb,
) RenderGridError!void;

pub fn expandCells(
    cells: []const Rgb,
    pixel_buf: []u8,
    layout: ShmLayout,
) ExpandError!void;
```

Validation occurs before the first write:

- `grid.validate()` succeeds;
- `out.len == grid.len`;
- `cells.len == layout.grid.len`;
- `pixel_buf.len == layout.buffer_bytes`;
- the layout's grid is the exact grid derived from its extent.

Exact equality rejects stale oversized slices after resize instead of hiding a
layout mismatch. GPU-only `Effect.renderGrid` returns `error.NoCpuRenderer`
rather than silently leaving an output slice untouched. The stand-in path
ensures only colormix reaches CPU rendering.

Cells use row-major indexing everywhere:

```text
index = y * grid.width + x
```

Producer and consumer change in the same commit, making the migration visually
neutral. Resize publication remains transactional: new grid/pool resources are
fully rendered and expanded before old resources are destroyed.

## Colormix hot-loop work

### 7. Invariant hoisting and palette cache

`ColormixRenderer` keeps both representations built on palette mutation:

- the existing 12 palette cells and 36-float GPU upload data;
- a new 12-entry blended `Rgb` cache for CPU cell lookup.

The CPU cache moves three-channel float blending out of every grid cell. It is
rebuilt at initialization and exactly once per palette mutation.

`renderGrid` hoists outside both loops:

- integer and float width/height forms;
- reciprocal height and reciprocal double-height;
- the bounded animation time multiplied by its fixed shader coefficient.

It hoists per row:

- the row base index;
- the row's integer coordinate conversion;
- the initial vertical UV component.

The loop remains `y` outer and `x` inner. Integer numerator evaluation is kept
before floating conversion so CPU/GPU parity is not changed by accumulated
floating-coordinate rounding.

Framebuffer expansion initially changes only to row-major cell reads while
preserving the proven rectangle-fill algorithm. A row-linear span-fill
candidate may be retained only if the benchmark gate below passes.

## Error handling and ownership

- Checked layout errors occur before output mutation.
- Configuration-time allocation, render, or expansion failure unwinds the new
  grid and pool and leaves the previous published resources intact.
- Per-frame invariant failure releases the acquired busy slot, emits one
  bounded diagnostic, and skips that surface's commit.
- No error path frees listener userdata during dispatch.
- No grid pointer survives pool/layout replacement.
- Animation has no allocator, fd, GL object, Wayland proxy, or destructor.
- Arithmetic that depends on external dimensions or timer expirations is
  checked or folded before narrowing.

## Performance measurement

### 8. Deterministic operation counts

Unit adapters prove structural improvements without timing noise:

- one App animation advance per timer event;
- zero animation clock calls in Release paths;
- one `cpuEffect` resolution per rendered SHM surface;
- zero palette rebuilds for stable stand-ins;
- one palette rebuild per changed palette per stand-in;
- one phase value shared by all surfaces in the same timer event.

### 9. ReleaseFast CPU benchmark

A dependency-free Zig benchmark is added as `zig build bench-cpu`. It uses
fixed palettes, phase, dimensions, warm-up batches, and checksums. It reports
median nanoseconds for:

- colormix grid rendering;
- cell expansion;
- combined render plus expansion;
- stable and changing-palette workloads;
- one and two simulated outputs;
- 1920x1200, 2560x1440, and 3840x2160 extents.

The benchmark harness is committed before hot-loop implementation so a clean
pre-optimization baseline exists. Logical workload constants and checksum
expectations remain unchanged when adapting the harness to checked signatures.

Retention rules:

- typed bounds checks, centralized animation, palette change detection, and
  row-major layout are required correctness/structural changes;
- optional row-linear framebuffer filling is retained only if it improves the
  combined median by at least 3% on two target sizes and regresses no target by
  more than 2%; otherwise the simpler rectangle fill remains;
- no benchmark timing becomes a flaky unit-test threshold;
- before/after commands, CPU governor context, medians, and checksums are
  recorded in the audit completion entry.

## Test strategy

### Animation tests

- initial phase/time and direction;
- one and multiple timer expirations;
- speed mutation leaves phase unchanged and changes only the next delta;
- upper and lower endpoint overshoot reflection;
- a large expiration count crosses multiple endpoints in bounded work;
- repeated reflection always maintains `0 <= phase <= PHASE_LIMIT`;
- minimum-speed adjacent steps remain distinct near the upper endpoint;
- effect switch reset versus same-effect reload continuity;
- every effect and every output receives one identical animation time;
- zero-output timer disarm preserves phase;
- short/error timerfd reads cannot advance or consume undefined bytes;
- fallback conversion and hotplugged SHM configuration preserve App phase.

### Grid and framebuffer tests

- checked grid product and fabricated-layout rejection;
- short and oversized render slices rejected before sentinel mutation;
- short and oversized framebuffer slices rejected before writes;
- 2x2 unique row-major cells expand into the expected quadrants;
- partial right/bottom cells and sub-cell extents remain fully painted;
- existing 1920x1080 and pool-boundary calculations remain unchanged;
- palette cache exactly matches the former per-cell blend;
- CPU coordinates/palette indices match a reference implementation;
- configuration failure preserves the old pool, layout, and grid;
- per-frame failure releases the acquired buffer slot.

### Integration and live acceptance

- Debug, ReleaseSafe, and ReleaseFast complete test graphs;
- direct config tests and formatting/diff/static scans;
- normal GPU and forced-SHM speed change from 0.25 to 2.5 with no immediate
  phase change and faster subsequent motion;
- same-palette stable SHM frames produce no rebuild diagnostics/counters;
- output disable, palette/speed mutation while output-less, and watchdog
  restoration continue from the authoritative phase;
- resize and output removal/re-add show no stale grid, unpainted edge, buffer
  starvation, or ownership warning;
- multi-output same-tick phase and CPU syscall acceptance when hardware is
  available; otherwise deterministic tests are recorded as the evidence.

The user's exact daemon, IPC socket, config, and output state are captured and
restored around live acceptance. No name-wide process signal is used.

## Expected outcome

The normal GPU path removes per-output frame conversion and speed
multiplication and adds no syscall or allocation. The SHM path removes all
per-output animation clock calls, halves CPU-effect resolution, eliminates
steady palette rebuilds, avoids per-cell blending, and consumes cells
sequentially. Safety becomes explicit at API boundaries rather than relying on
callers to maintain matching dimensions and slice lengths.

