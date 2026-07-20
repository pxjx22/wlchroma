# Phase 2 Wayland and EGL Safety Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close audit findings `WL-H1`, `WL-H2`, `GPU-M1`, `GPU-M2`, `GPU-M3`, and `WL-L1` with checked compositor dimensions and a recoverable, explicitly owned GPU context epoch.

**Architecture:** Pure helpers validate every protocol dimension and SHM product before state mutation or C calls. `App` owns a GPU epoch and drives one generic lifecycle sequence shared with fake-backend tests; surfaces atomically detach borrowed/context-owned state before epoch teardown, and a zero-output transition recreates the epoch lazily when an output returns.

**Tech Stack:** Zig 0.16.0, Linux, Wayland client APIs, wlr-layer-shell, EGL, OpenGL ES 2.0, SHM/mmap; no new dependencies.

## Global Constraints

- Preserve all existing config, CLI, IPC, effect, palette, renderer-scale, and GPU/CPU selection behavior except the approved recoverable zero-output GPU epoch lifecycle.
- Do not implement Phase 3 findings, including `GPU-M4`, `GPU-M5`, `GPU-M6`, `RENDER-M1`, or any performance/modernization item.
- No heap allocation, new system call, or synchronization may be added to the ordinary per-frame render path.
- GL deletion functions may run only after the owning EGL context is confirmed current.
- EGL surfaces must be unbound and destroyed before their borrowed `EGLDisplay` is terminated.
- If `App.egl_ctx` is null, no `SurfaceState` may retain `egl_ctx`, `egl_surface`, or `offscreen` state.
- A failed current-context acquisition may not silently discard a program, VBO, FBO, or texture owner.
- Invalid compositor dimensions must be rejected before any narrowing cast, allocation, mmap, EGL, GLES, SHM, or framebuffer call.
- Keep listener userdata heap-stable and destroy surfaces before their owning outputs.
- Use `ZIG_GLOBAL_CACHE_DIR` under `/tmp`; socket tests need normal host syscall access when the managed sandbox blocks `bind` or `send`.
- Before any all-outputs-off live test, resolve exact Niri output names and arm and validate an independent automatic recovery action using the current `NIRI_SOCKET`.
- Never use a name-wide `pkill wlchroma`; inspect and target the exact process.

---

### Task 1: Add checked extent and SHM layout primitives

**Audit rows:** Foundation for `WL-H2`

**Files:**

- Create: `src/wayland/dimensions.zig`
- Create: `tests/wayland_egl/dimensions_test.zig`
- Modify: `src/test_exports.zig`
- Modify: `build.zig`

**Interfaces:**

- Consumes: `config/defaults.zig` cell dimensions and Zig checked arithmetic.
- Produces: `Extent`, `resolve`, `ShmLayout`, `BufferRange`, and the focused `test-wayland-egl` build step.

- [ ] **Step 1: Wire the focused test artifact and write the failing boundary tests**

Add this export to `src/test_exports.zig`:

```zig
pub const dimensions = @import("wayland/dimensions.zig");
```

After `src_exports_mod` is created in `build.zig`, add:

```zig
const phase2_test_step = b.step(
    "test-wayland-egl",
    "Run Wayland/EGL lifecycle safety tests",
);

const dimensions_test_mod = b.createModule(.{
    .root_source_file = b.path("tests/wayland_egl/dimensions_test.zig"),
    .target = target,
    .optimize = optimize,
});
dimensions_test_mod.addImport("wlchroma_src", src_exports_mod);
const dimensions_tests = b.addTest(.{
    .root_module = dimensions_test_mod,
});
const run_dimensions_tests = b.addRunArtifact(dimensions_tests);
phase2_test_step.dependOn(&run_dimensions_tests.step);
test_step.dependOn(&run_dimensions_tests.step);
```

Create `tests/wayland_egl/dimensions_test.zig` with tests that assert these exact cases:

```zig
const std = @import("std");
const dimensions = @import("wlchroma_src").dimensions;

test "resolve returns null until both axes are known" {
    try std.testing.expectEqual(@as(?dimensions.Extent, null), try dimensions.resolve(null, 0, 0));
    try std.testing.expectEqual(@as(?dimensions.Extent, null), try dimensions.resolve(null, 1920, 0));
}

test "resolve reuses only zero protocol axes" {
    const previous = try dimensions.Extent.init(1920, 1080);
    const height_change = (try dimensions.resolve(previous, 0, 720)).?;
    try std.testing.expectEqual(@as(u32, 1920), height_change.width);
    try std.testing.expectEqual(@as(u32, 720), height_change.height);
    const width_change = (try dimensions.resolve(previous, 1280, 0)).?;
    try std.testing.expectEqual(@as(u32, 1280), width_change.width);
    try std.testing.expectEqual(@as(u32, 1080), width_change.height);
}

test "extent accepts the C ABI maximum and rejects the next value" {
    const maximum = try dimensions.Extent.init(2_147_483_647, 1);
    try std.testing.expectEqual(@as(i32, 2_147_483_647), maximum.c_width);
    try std.testing.expectError(
        error.WidthExceedsCInt,
        dimensions.Extent.init(2_147_483_648, 1),
    );
    try std.testing.expectError(
        error.HeightExceedsCInt,
        dimensions.Extent.init(1, 2_147_483_648),
    );
}

test "invalid configure does not require overwriting the previous extent" {
    const previous = try dimensions.Extent.init(1920, 1080);
    try std.testing.expectError(
        error.WidthExceedsCInt,
        dimensions.resolve(previous, 2_147_483_648, 720),
    );
    try std.testing.expectEqual(@as(u32, 1920), previous.width);
    try std.testing.expectEqual(@as(u32, 1080), previous.height);
}

test "SHM layout computes two XRGB8888 buffers and the CPU grid" {
    const layout = try dimensions.ShmLayout.init(try dimensions.Extent.init(1920, 1080));
    try std.testing.expectEqual(@as(i32, 7680), layout.stride);
    try std.testing.expectEqual(@as(usize, 8_294_400), layout.buffer_bytes);
    try std.testing.expectEqual(@as(usize, 16_588_800), layout.total_bytes);
    try std.testing.expectEqual([2]i32{ 0, 8_294_400 }, layout.offsets);
    try std.testing.expectEqual(@as(usize, 192), layout.grid_w);
    try std.testing.expectEqual(@as(usize, 67), layout.grid_h);
    try std.testing.expectEqual(@as(usize, 12_864), layout.grid_len);
}

test "SHM layout accepts the exact pool boundary" {
    const layout = try dimensions.ShmLayout.init(try dimensions.Extent.init(1, 268_435_455));
    try std.testing.expectEqual(@as(usize, 1_073_741_820), layout.buffer_bytes);
    try std.testing.expectEqual(@as(usize, 2_147_483_640), layout.total_bytes);
    try std.testing.expectEqual(
        dimensions.BufferRange{ .start = 1_073_741_820, .end = 2_147_483_640 },
        layout.bufferRange(1),
    );
}

test "SHM layout rejects ABI overflow before narrowing" {
    try std.testing.expectError(
        error.PoolSizeExceedsCInt,
        dimensions.ShmLayout.init(try dimensions.Extent.init(1, 268_435_456)),
    );
    try std.testing.expectError(
        error.StrideExceedsCInt,
        dimensions.ShmLayout.init(try dimensions.Extent.init(536_870_912, 1)),
    );
}

test "scaled extent stays nonzero and within the signed ABI" {
    const native = try dimensions.Extent.init(1920, 1080);
    const scaled = try native.scaled(0.5);
    try std.testing.expectEqual(@as(u32, 960), scaled.width);
    try std.testing.expectEqual(@as(u32, 540), scaled.height);
    const tiny = try (try dimensions.Extent.init(1, 1)).scaled(0.1);
    try std.testing.expectEqual(@as(u32, 1), tiny.width);
    try std.testing.expectEqual(@as(u32, 1), tiny.height);
}
```

- [ ] **Step 2: Run the red test**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase2-task1 zig build test-wayland-egl --summary all
```

Expected: compilation fails because `src/wayland/dimensions.zig` and its declarations do not exist.

- [ ] **Step 3: Implement the pure checked types**

Create `src/wayland/dimensions.zig` with these public declarations and behavior:

```zig
const std = @import("std");
const defaults = @import("../config/defaults.zig");

pub const ExtentError = error{
    ZeroDimension,
    WidthExceedsCInt,
    HeightExceedsCInt,
    InvalidScale,
};

pub const LayoutError = error{
    StrideOverflow,
    StrideExceedsCInt,
    BufferBytesOverflow,
    TotalBytesOverflow,
    PoolSizeExceedsCInt,
    OffsetExceedsCInt,
    GridSizeOverflow,
};

pub const Extent = struct {
    width: u32,
    height: u32,
    c_width: i32,
    c_height: i32,

    pub fn init(width: u32, height: u32) ExtentError!Extent {
        if (width == 0 or height == 0) return error.ZeroDimension;
        const c_max: u32 = @intCast(std.math.maxInt(i32));
        if (width > c_max) return error.WidthExceedsCInt;
        if (height > c_max) return error.HeightExceedsCInt;
        return .{
            .width = width,
            .height = height,
            .c_width = @intCast(width),
            .c_height = @intCast(height),
        };
    }

    pub fn scaled(self: Extent, scale: f32) ExtentError!Extent {
        if (!std.math.isFinite(scale) or scale <= 0.0 or scale > 1.0) {
            return error.InvalidScale;
        }
        if (scale == 1.0) return self;
        const width_f = @as(f64, @floatFromInt(self.width)) * @as(f64, scale);
        const height_f = @as(f64, @floatFromInt(self.height)) * @as(f64, scale);
        const width: u32 = @intFromFloat(@max(1.0, width_f));
        const height: u32 = @intFromFloat(@max(1.0, height_f));
        return init(width, height);
    }
};

pub fn resolve(previous: ?Extent, event_width: u32, event_height: u32) ExtentError!?Extent {
    const c_max: u32 = @intCast(std.math.maxInt(i32));
    if (event_width > c_max) return error.WidthExceedsCInt;
    if (event_height > c_max) return error.HeightExceedsCInt;
    const width = if (event_width == 0)
        if (previous) |extent| extent.width else 0
    else
        event_width;
    const height = if (event_height == 0)
        if (previous) |extent| extent.height else 0
    else
        event_height;
    if (width == 0 or height == 0) return null;
    return try Extent.init(width, height);
}

pub const BufferRange = struct { start: usize, end: usize };

pub const ShmLayout = struct {
    extent: Extent,
    stride: i32,
    buffer_bytes: usize,
    total_bytes: usize,
    offsets: [2]i32,
    grid_w: usize,
    grid_h: usize,
    grid_len: usize,

    pub fn init(extent: Extent) LayoutError!ShmLayout {
        const stride = std.math.mul(usize, @as(usize, extent.width), 4) catch
            return error.StrideOverflow;
        if (stride > std.math.maxInt(i32)) return error.StrideExceedsCInt;
        const buffer_bytes = std.math.mul(usize, stride, @as(usize, extent.height)) catch
            return error.BufferBytesOverflow;
        const total_bytes = std.math.mul(usize, buffer_bytes, 2) catch
            return error.TotalBytesOverflow;
        if (total_bytes > std.math.maxInt(i32)) return error.PoolSizeExceedsCInt;
        if (buffer_bytes > std.math.maxInt(i32)) return error.OffsetExceedsCInt;
        const grid_w = @max(@divFloor(@as(usize, extent.width), defaults.CELL_W), 1);
        const grid_h = @max(@divFloor(@as(usize, extent.height), defaults.CELL_H), 1);
        const grid_len = std.math.mul(usize, grid_w, grid_h) catch
            return error.GridSizeOverflow;
        return .{
            .extent = extent,
            .stride = @intCast(stride),
            .buffer_bytes = buffer_bytes,
            .total_bytes = total_bytes,
            .offsets = .{ 0, @intCast(buffer_bytes) },
            .grid_w = grid_w,
            .grid_h = grid_h,
            .grid_len = grid_len,
        };
    }

    pub fn bufferRange(self: ShmLayout, index: u1) BufferRange {
        const start = @as(usize, index) * self.buffer_bytes;
        return .{ .start = start, .end = start + self.buffer_bytes };
    }
};
```

- [ ] **Step 4: Run green and project regression tests**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase2-task1 zig build test-wayland-egl --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase2-task1 zig build test --summary all
```

Expected: focused dimension tests and all existing 89 tests pass.

- [ ] **Step 5: Commit**

```sh
git add build.zig src/test_exports.zig src/wayland/dimensions.zig tests/wayland_egl/dimensions_test.zig
git commit -m "fix(renderer): add checked Wayland dimensions"
```

### Task 2: Migrate EGL, GLES, framebuffer, and SHM consumers

**Audit rows:** `WL-H2`

**Files:**

- Modify: `src/wayland/surface_state.zig`
- Modify: `src/wayland/shm_pool.zig`
- Modify: `src/render/egl_surface.zig`
- Modify: `src/render/offscreen.zig`
- Modify: `src/render/framebuffer.zig`
- Test: `tests/wayland_egl/dimensions_test.zig`

**Interfaces:**

- Consumes: `dimensions.Extent`, `dimensions.resolve`, and `dimensions.ShmLayout` from Task 1.
- Produces: validated extents at every compositor-controlled ABI crossing and stored SHM teardown sizes.

- [ ] **Step 1: Add failing tests for buffer ranges and scaled ABI values**

Extend `tests/wayland_egl/dimensions_test.zig`:

```zig
test "buffer ranges exactly partition the stored mapping" {
    const layout = try dimensions.ShmLayout.init(try dimensions.Extent.init(8, 4));
    try std.testing.expectEqual(dimensions.BufferRange{ .start = 0, .end = 128 }, layout.bufferRange(0));
    try std.testing.expectEqual(dimensions.BufferRange{ .start = 128, .end = 256 }, layout.bufferRange(1));
    try std.testing.expectEqual(layout.total_bytes, layout.bufferRange(1).end);
}

test "scaled C dimensions are produced once by the checked extent" {
    const scaled = try (try dimensions.Extent.init(3840, 2160)).scaled(0.5);
    try std.testing.expectEqual(@as(i32, 1920), scaled.c_width);
    try std.testing.expectEqual(@as(i32, 1080), scaled.c_height);
}
```

- [ ] **Step 2: Run the focused tests before integration**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase2-task2 zig build test-wayland-egl --summary all
```

Expected: the new pure assertions pass, establishing the values production must consume; `rg` still finds the old unchecked call sites.

- [ ] **Step 3: Change every consumer to accept checked types**

Use these exact signatures:

```zig
// render/egl_surface.zig
pub fn create(ctx: *const EglContext, wl_surface: *c.wl_surface, extent: Extent) !EglSurface
pub fn resize(self: *EglSurface, extent: Extent) void

// render/offscreen.zig
pub fn init(extent: Extent, filter: UpscaleFilter) !Offscreen
pub fn resize(self: *Offscreen, extent: Extent) bool

// wayland/shm_pool.zig
pub fn init(shm: *c.wl_shm, layout: ShmLayout) !ShmPool

// render/framebuffer.zig
pub fn expandCells(
    cells: []const Rgb,
    grid_w: usize,
    grid_h: usize,
    pixel_buf: []u8,
    extent: Extent,
) void
```

In the C calls use only `extent.c_width`, `extent.c_height`, `layout.stride`, `layout.offsets[i]`, and `@intCast(layout.total_bytes)` after Task 1 validation. Change `ShmPool` ownership to:

```zig
layout: ShmLayout,
total_bytes: usize,
```

Set both fields during initialization, use `layout.bufferRange(idx)` in `pixelSlice`, and pass stored `total_bytes` directly to `munmap` in `deinit`.

- [ ] **Step 4: Make configure validation and SHM replacement transactional**

Replace `SurfaceState.pixel_w`/`pixel_h` with:

```zig
extent: ?Extent,
```

Initialize it from positive `OutputInfo.width`/`height`; otherwise use null. At the start of `layerSurfaceConfigure`, acknowledge first and then resolve without mutating stored state:

```zig
c.zwlr_layer_surface_v1_ack_configure(layer_surface, serial);
const next_extent = dimensions.resolve(self.extent, width, height) catch |err| {
    std.debug.print("configure: rejecting dimensions {}x{}: {}\n", .{ width, height, err });
    return;
};
const extent = next_extent orelse {
    self.configured = false;
    std.debug.print("configure: zero dimensions, skipping\n", .{});
    return;
};
self.extent = extent;
```

Pass `extent` through `EglSurface`, `glViewport`, scaled `Offscreen`, SHM, and framebuffer calls. `glViewport` and `glTexImage2D` must consume checked signed fields without `@intCast`.

Change the private helper to return errors so `errdefer` runs on every failed preparation:

```zig
fn configureShmFallback(self: *SurfaceState, extent: Extent) !void {
    const layout = try ShmLayout.init(extent);
    const wl_surface = self.layer_surface.wl_surface orelse return error.MissingWlSurface;

    const new_grid = try self.allocator.alloc(defaults.Rgb, layout.grid_len);
    errdefer self.allocator.free(new_grid);
    var new_pool = try ShmPool.init(self.shm, layout);
    errdefer new_pool.deinit();

    self.cpuEffect().renderGrid(layout.grid_w, layout.grid_h, new_grid);
    const first = new_pool.acquireBuffer() orelse return error.NoFreeShmBuffer;
    framebuffer.expandCells(
        new_grid,
        layout.grid_w,
        layout.grid_h,
        new_pool.pixelSlice(first),
        extent,
    );

    if (self.frame_callback) |old_callback| {
        c.wl_callback_destroy(old_callback);
        self.frame_callback = null;
    }
    if (self.shm_pool) |*old_pool| old_pool.deinit();
    if (self.cell_grid.len > 0) self.allocator.free(self.cell_grid);

    self.shm_pool = new_pool;
    self.cell_grid = new_grid;
    self.grid_w = layout.grid_w;
    self.grid_h = layout.grid_h;
    self.buf_ctx[0] = .{ .pool_busy = &self.shm_pool.?.busy[0], .surface = self };
    self.buf_ctx[1] = .{ .pool_busy = &self.shm_pool.?.busy[1], .surface = self };
    self.shm_pool.?.attachListeners(
        &SurfaceState.buf_release_listener,
        @ptrCast(&self.buf_ctx[0]),
        @ptrCast(&self.buf_ctx[1]),
    );

    c.wl_surface_attach(wl_surface, self.shm_pool.?.wlBuffer(first), 0, 0);
    c.wl_surface_damage_buffer(wl_surface, 0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
    if (c.wl_surface_frame(wl_surface)) |callback| {
        self.frame_callback = callback;
        _ = c.wl_callback_add_listener(callback, &SurfaceState.frame_callback_listener, self);
    } else {
        std.debug.print("configure: wl_surface_frame returned null (OOM)\n", .{});
    }
    c.wl_surface_commit(wl_surface);
    self.configured = true;
}
```

Catch and log this helper once at each caller, setting `configured = false` on failure. No `catch { return; }` is allowed between acquiring `new_grid`/`new_pool` and transferring ownership because a successful `return` would bypass `errdefer`. After every fallible preparation succeeds, the code destroys the old pool/grid, moves `new_pool` and `new_grid` into `self`, rebuilds `buf_ctx`, attaches/commits the already-acquired buffer, and sets `configured = true` last.

- [ ] **Step 5: Prove unchecked compositor casts are gone**

```sh
rg -n '@intCast\((pw|ph|width|height|w|h)\)' src/wayland/surface_state.zig src/wayland/shm_pool.zig src/render/egl_surface.zig src/render/offscreen.zig
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase2-task2 zig build
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase2-task2 zig build test --summary all
```

Expected: the targeted scan has no compositor-derived narrowing; the executable and full test graph pass.

- [ ] **Step 6: Commit**

```sh
git add src/wayland/surface_state.zig src/wayland/shm_pool.zig src/render/egl_surface.zig src/render/offscreen.zig src/render/framebuffer.zig tests/wayland_egl/dimensions_test.zig
git commit -m "fix(renderer): validate compositor dimensions"
```

### Task 3: Make output registration transactional

**Audit rows:** `WL-L1`

**Files:**

- Create: `src/test_wayland_exports.zig`
- Create: `tests/wayland_egl/output_registration_test.zig`
- Modify: `src/wayland/registry.zig`
- Modify: `src/wayland/output.zig`
- Modify: `build.zig`

**Interfaces:**

- Consumes: existing heap-stable `OutputInfo` ownership and the `test-wayland-egl` step.
- Produces: `registerOutputWithOps`, `OutputRegistrationOps`, and `output.releaseProxy`.

- [ ] **Step 1: Add a C-linked Wayland test shim and failing transaction tests**

Create `src/test_wayland_exports.zig`:

```zig
pub const registry = @import("wayland/registry.zig");
pub const output = @import("wayland/output.zig");
pub const c = @import("wl.zig").c;
```

Add this dedicated module in `build.zig` after `phase2_test_step` is created. It deliberately receives the same generated protocol C sources, include paths, libc setting, and system libraries as the executable:

```zig
const wayland_exports_mod = b.createModule(.{
    .root_source_file = b.path("src/test_wayland_exports.zig"),
    .target = target,
    .optimize = optimize,
    .link_libc = true,
});
wayland_exports_mod.addImport("sys", sys_mod);
wayland_exports_mod.addCSourceFile(.{ .file = src, .flags = &.{} });
wayland_exports_mod.addCSourceFile(.{ .file = xdg_src, .flags = &.{} });
wayland_exports_mod.addIncludePath(hdr.dirname());
wayland_exports_mod.addIncludePath(xdg_hdr.dirname());
wayland_exports_mod.linkSystemLibrary("wayland-client", .{});
wayland_exports_mod.linkSystemLibrary("EGL", .{});
wayland_exports_mod.linkSystemLibrary("GLESv2", .{});
wayland_exports_mod.linkSystemLibrary("wayland-egl", .{});

const output_registration_test_mod = b.createModule(.{
    .root_source_file = b.path("tests/wayland_egl/output_registration_test.zig"),
    .target = target,
    .optimize = optimize,
});
output_registration_test_mod.addImport("wayland_test", wayland_exports_mod);
const output_registration_tests = b.addTest(.{
    .root_module = output_registration_test_mod,
});
const run_output_registration_tests = b.addRunArtifact(output_registration_tests);
phase2_test_step.dependOn(&run_output_registration_tests.step);
test_step.dependOn(&run_output_registration_tests.step);
```

Use this fixture in `tests/wayland_egl/output_registration_test.zig`:

```zig
const std = @import("std");
const wayland = @import("wayland_test");
const registry = wayland.registry;
const OutputInfo = wayland.output.OutputInfo;
const c = wayland.c;

const FakeState = struct {
    outputs: *std.ArrayList(*OutputInfo),
    bind_succeeds: bool = true,
    listener_result: c_int = 0,
    bind_calls: usize = 0,
    listener_calls: usize = 0,
    release_calls: usize = 0,
    listener_userdata: ?*OutputInfo = null,
};

fn fakeProxy() *c.wl_output {
    return @ptrFromInt(0x1000);
}

fn fakeBind(context: ?*anyopaque, _: ?*c.wl_registry, _: u32, _: u32) ?*c.wl_output {
    const state: *FakeState = @ptrCast(@alignCast(context));
    state.bind_calls += 1;
    return if (state.bind_succeeds) fakeProxy() else null;
}

fn fakeAddListener(context: ?*anyopaque, _: *c.wl_output, info: *OutputInfo) c_int {
    const state: *FakeState = @ptrCast(@alignCast(context));
    state.listener_calls += 1;
    state.listener_userdata = info;
    std.debug.assert(state.outputs.items.len == 1);
    std.debug.assert(state.outputs.items[0] == info);
    return state.listener_result;
}

fn fakeRelease(context: ?*anyopaque, _: *c.wl_output) void {
    const state: *FakeState = @ptrCast(@alignCast(context));
    state.release_calls += 1;
}

fn fakeOps(state: *FakeState) registry.OutputRegistrationOps {
    return .{
        .context = state,
        .bind = fakeBind,
        .add_listener = fakeAddListener,
        .release = fakeRelease,
    };
}

test "allocation failure binds no output proxy" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const allocator = failing.allocator();
    var outputs: std.ArrayList(*OutputInfo) = .empty;
    defer outputs.deinit(allocator);
    var state = FakeState{ .outputs = &outputs };
    try std.testing.expectError(
        error.OutOfMemory,
        registry.registerOutputWithOps(allocator, &outputs, null, 7, 3, fakeOps(&state)),
    );
    try std.testing.expectEqual(@as(usize, 0), state.bind_calls);
    try std.testing.expectEqual(@as(usize, 0), state.listener_calls);
    try std.testing.expectEqual(@as(usize, 0), state.release_calls);
    try std.testing.expectEqual(@as(usize, 0), outputs.items.len);
}

test "bind failure destroys the uninitialized allocation" {
    var outputs: std.ArrayList(*OutputInfo) = .empty;
    defer outputs.deinit(std.testing.allocator);
    var state = FakeState{ .outputs = &outputs, .bind_succeeds = false };
    try std.testing.expectError(
        error.OutputBindFailed,
        registry.registerOutputWithOps(std.testing.allocator, &outputs, null, 7, 3, fakeOps(&state)),
    );
    try std.testing.expectEqual(@as(usize, 1), state.bind_calls);
    try std.testing.expectEqual(@as(usize, 0), state.listener_calls);
    try std.testing.expectEqual(@as(usize, 0), state.release_calls);
    try std.testing.expectEqual(@as(usize, 0), outputs.items.len);
}

test "append failure releases the proxy exactly once" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const allocator = failing.allocator();
    var outputs: std.ArrayList(*OutputInfo) = .empty;
    defer outputs.deinit(allocator);
    var state = FakeState{ .outputs = &outputs };
    try std.testing.expectError(
        error.OutOfMemory,
        registry.registerOutputWithOps(allocator, &outputs, null, 7, 3, fakeOps(&state)),
    );
    try std.testing.expectEqual(@as(usize, 1), state.bind_calls);
    try std.testing.expectEqual(@as(usize, 0), state.listener_calls);
    try std.testing.expectEqual(@as(usize, 1), state.release_calls);
    try std.testing.expectEqual(@as(usize, 0), outputs.items.len);
}

test "listener failure removes the appended userdata before release" {
    var outputs: std.ArrayList(*OutputInfo) = .empty;
    defer outputs.deinit(std.testing.allocator);
    var state = FakeState{ .outputs = &outputs, .listener_result = -1 };
    try std.testing.expectError(
        error.OutputListenerFailed,
        registry.registerOutputWithOps(std.testing.allocator, &outputs, null, 7, 3, fakeOps(&state)),
    );
    try std.testing.expectEqual(@as(usize, 1), state.listener_calls);
    try std.testing.expectEqual(@as(usize, 1), state.release_calls);
    try std.testing.expectEqual(@as(usize, 0), outputs.items.len);
}

test "successful registration transfers one heap-stable userdata pointer" {
    var outputs: std.ArrayList(*OutputInfo) = .empty;
    defer outputs.deinit(std.testing.allocator);
    var state = FakeState{ .outputs = &outputs };
    try registry.registerOutputWithOps(std.testing.allocator, &outputs, null, 7, 3, fakeOps(&state));
    try std.testing.expectEqual(@as(usize, 1), outputs.items.len);
    try std.testing.expect(outputs.items[0] == state.listener_userdata.?);
    try std.testing.expectEqual(@as(usize, 0), state.release_calls);

    const info = outputs.pop().?;
    fakeRelease(&state, info.wl_output.?);
    info.wl_output = null;
    info.deinit();
    std.testing.allocator.destroy(info);
    try std.testing.expectEqual(@as(usize, 1), state.release_calls);
}
```

- [ ] **Step 2: Run the red test**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase2-task3 zig build test-wayland-egl --summary all
```

Expected: compilation fails because `OutputRegistrationOps` and `registerOutputWithOps` do not exist.

- [ ] **Step 3: Implement one concrete injectable transaction**

Add to `registry.zig`:

```zig
pub const OutputRegistrationOps = struct {
    context: ?*anyopaque,
    bind: *const fn (?*anyopaque, ?*c.wl_registry, u32, u32) ?*c.wl_output,
    add_listener: *const fn (?*anyopaque, *c.wl_output, *OutputInfo) c_int,
    release: *const fn (?*anyopaque, *c.wl_output) void,
};

pub fn registerOutputWithOps(
    allocator: std.mem.Allocator,
    outputs: *std.ArrayList(*OutputInfo),
    registry: ?*c.wl_registry,
    name: u32,
    version: u32,
    ops: OutputRegistrationOps,
) !void {
    const info = try allocator.create(OutputInfo);
    errdefer allocator.destroy(info);

    const proxy = ops.bind(ops.context, registry, name, @min(version, 3)) orelse
        return error.OutputBindFailed;
    info.* = .{
        .wl_output = proxy,
        .registry_name = name,
        .name = "",
        .width = 0,
        .height = 0,
        .refresh_mhz = 0,
        .done = false,
        .removed = false,
        .allocator = allocator,
    };
    errdefer {
        ops.release(ops.context, proxy);
        info.wl_output = null;
        info.deinit();
    }

    try outputs.append(allocator, info);
    errdefer std.debug.assert(outputs.pop().? == info);
    if (ops.add_listener(ops.context, proxy, info) != 0) {
        return error.OutputListenerFailed;
    }
}
```

Add `pub fn releaseProxy(out: *c.wl_output) void` to `output.zig`, move the version-aware release/destroy branch there, and call it from `OutputInfo.deinit`. Production ops call `wl_registry_bind`, `wl_output_add_listener`, and `releaseProxy`. The registry callback resolves `self.outputs` before calling the transaction and logs any returned error.

- [ ] **Step 4: Run focused and full regression tests**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase2-task3 zig build test-wayland-egl --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase2-task3 zig build test --summary all
```

Expected: all allocation/bind/append/listener/success cases and the full graph pass.

- [ ] **Step 5: Commit**

```sh
git add build.zig src/test_wayland_exports.zig src/wayland/registry.zig src/wayland/output.zig tests/wayland_egl/output_registration_test.zig
git commit -m "fix(renderer): make output registration transactional"
```

### Task 4: Add the driver-independent GPU epoch state machine

**Audit rows:** Foundation for `WL-H1`, `GPU-M1`, `GPU-M2`, and `GPU-M3`

**Files:**

- Create: `src/render/gpu_epoch.zig`
- Create: `tests/wayland_egl/gpu_epoch_test.zig`
- Modify: `src/test_exports.zig`
- Modify: `build.zig`

**Interfaces:**

- Consumes: only Zig types; no EGL or Wayland import.
- Produces: `handlesMatch`, `acquireCurrent`, `close`, `start`, `shouldStart`, and `requiresCpuFallback` used unchanged by production and fake tests.

- [ ] **Step 1: Write failing fake-backend lifecycle tests**

Export `gpu_epoch` through `src/test_exports.zig`, add `tests/wayland_egl/gpu_epoch_test.zig` as another `wlchroma_src` artifact, and attach it to both test steps.

Use this complete fixture and initial tests:

```zig
const std = @import("std");
const gpu_epoch = @import("wlchroma_src").gpu_epoch;

const Event = union(enum) {
    detach_all,
    try_current: usize,
    delete_app_gl,
    delete_surface_gl: usize,
    clear_current,
    destroy_surface: usize,
    destroy_context,
    clear_handles,
};

const FakeOps = struct {
    successes: [4]bool = .{ false, false, false, false },
    count: usize,
    app_wrapper_present: bool = true,
    surface_wrapper_present: [4]bool = @splat(true),
    context_destroy_saw_wrappers: bool = false,
    events: [64]Event = undefined,
    events_len: usize = 0,

    fn record(self: *FakeOps, event: Event) void {
        self.events[self.events_len] = event;
        self.events_len += 1;
    }

    pub fn detachAll(self: *FakeOps) void { self.record(.detach_all); }
    pub fn candidateCount(self: *FakeOps) usize { return self.count; }
    pub fn tryMakeCurrent(self: *FakeOps, index: usize) bool {
        self.record(.{ .try_current = index });
        return self.successes[index];
    }
    pub fn deleteAppGl(self: *FakeOps) void {
        self.record(.delete_app_gl);
        self.app_wrapper_present = false;
    }
    pub fn deleteSurfaceGl(self: *FakeOps, index: usize) void {
        self.record(.{ .delete_surface_gl = index });
        self.surface_wrapper_present[index] = false;
    }
    pub fn clearCurrent(self: *FakeOps) void { self.record(.clear_current); }
    pub fn destroySurface(self: *FakeOps, index: usize) void {
        self.record(.{ .destroy_surface = index });
    }
    pub fn destroyContext(self: *FakeOps) void {
        self.record(.destroy_context);
        self.context_destroy_saw_wrappers = self.app_wrapper_present;
        for (0..self.count) |index| {
            self.context_destroy_saw_wrappers =
                self.context_destroy_saw_wrappers or self.surface_wrapper_present[index];
        }
    }
    pub fn clearHandles(self: *FakeOps) void {
        self.record(.clear_handles);
        self.app_wrapper_present = false;
        for (0..self.count) |index| self.surface_wrapper_present[index] = false;
    }
};

const StartOps = struct {
    context_live: bool = false,
    failed: bool = false,
    ready_outputs: usize = 0,
    generations_created: usize = 0,

    pub fn hasContext(self: *StartOps) bool { return self.context_live; }
    pub fn permanentFailure(self: *StartOps) bool { return self.failed; }
    pub fn readyOutputCount(self: *StartOps) usize { return self.ready_outputs; }
    pub fn createContext(self: *StartOps) bool {
        self.generations_created += 1;
        self.context_live = true;
        return true;
    }
};

fn eventTag(event: Event) std.meta.Tag(Event) {
    return std.meta.activeTag(event);
}

fn firstTag(ops: *const FakeOps, tag: std.meta.Tag(Event)) ?usize {
    for (ops.events[0..ops.events_len], 0..) |event, index| {
        if (eventTag(event) == tag) return index;
    }
    return null;
}

test "current ownership requires both draw surface and context handles" {
    try std.testing.expect(!gpu_epoch.handlesMatch(@as(usize, 10), 10, @as(usize, 20), 21));
    try std.testing.expect(!gpu_epoch.handlesMatch(@as(usize, 10), 11, @as(usize, 20), 20));
    try std.testing.expect(gpu_epoch.handlesMatch(@as(usize, 10), 10, @as(usize, 20), 20));
}

test "acquireCurrent tries later candidates after the first failure" {
    var ops = FakeOps{ .successes = .{ false, true, false, false }, .count = 3 };
    try std.testing.expect(gpu_epoch.acquireCurrent(FakeOps, &ops));
    try std.testing.expectEqual(@as(usize, 2), ops.events_len);
    try std.testing.expectEqual(@as(usize, 0), ops.events[0].try_current);
    try std.testing.expectEqual(@as(usize, 1), ops.events[1].try_current);
}

test "close invalidates borrows before deletion and destruction" {
    var ops = FakeOps{ .successes = .{ true, false, false, false }, .count = 2 };
    gpu_epoch.close(FakeOps, &ops);
    try std.testing.expectEqual(.detach_all, eventTag(ops.events[0]));
    try std.testing.expect(firstTag(&ops, .delete_app_gl).? > 0);
    try std.testing.expect(firstTag(&ops, .destroy_context).? > 0);
}

test "close skips every GL deletion when all candidates fail" {
    var ops = FakeOps{ .count = 2 };
    gpu_epoch.close(FakeOps, &ops);
    try std.testing.expectEqual(@as(?usize, null), firstTag(&ops, .delete_app_gl));
    try std.testing.expectEqual(@as(?usize, null), firstTag(&ops, .delete_surface_gl));
    try std.testing.expect(firstTag(&ops, .destroy_context) != null);
    try std.testing.expect(ops.context_destroy_saw_wrappers);
    try std.testing.expect(!ops.app_wrapper_present);
    try std.testing.expect(!ops.surface_wrapper_present[0]);
    try std.testing.expect(!ops.surface_wrapper_present[1]);
    try std.testing.expect(firstTag(&ops, .destroy_context).? < firstTag(&ops, .clear_handles).?);
}

test "close clears current before destroying any EGL surface" {
    var ops = FakeOps{ .successes = .{ false, true, false, false }, .count = 2 };
    gpu_epoch.close(FakeOps, &ops);
    try std.testing.expect(firstTag(&ops, .clear_current).? < firstTag(&ops, .destroy_surface).?);
}

test "close destroys context before clearing CPU handle wrappers" {
    var ops = FakeOps{ .successes = .{ true, false, false, false }, .count = 1 };
    gpu_epoch.close(FakeOps, &ops);
    try std.testing.expect(firstTag(&ops, .destroy_context).? < firstTag(&ops, .clear_handles).?);
}

test "idle epochs restart only for a ready output" {
    try std.testing.expect(!gpu_epoch.shouldStart(false, false, 0));
    try std.testing.expect(gpu_epoch.shouldStart(false, false, 1));
    try std.testing.expect(!gpu_epoch.shouldStart(true, false, 1));
    try std.testing.expect(!gpu_epoch.shouldStart(false, true, 1));
}

test "repeated idle effect switches allocate nothing and output return starts one generation" {
    var ops = StartOps{};
    for (0..3) |_| {
        try std.testing.expect(!gpu_epoch.start(StartOps, &ops));
        try std.testing.expectEqual(@as(usize, 0), ops.generations_created);
    }
    ops.ready_outputs = 1;
    try std.testing.expect(gpu_epoch.start(StartOps, &ops));
    try std.testing.expectEqual(@as(usize, 1), ops.generations_created);
    try std.testing.expect(gpu_epoch.start(StartOps, &ops));
    try std.testing.expectEqual(@as(usize, 1), ops.generations_created);
}

test "only permanent GPU failure forces a GPU-only effect to CPU" {
    try std.testing.expect(!gpu_epoch.requiresCpuFallback(false, true));
    try std.testing.expect(!gpu_epoch.requiresCpuFallback(true, false));
    try std.testing.expect(gpu_epoch.requiresCpuFallback(true, true));
}
```

- [ ] **Step 2: Run the red test**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase2-task4 zig build test-wayland-egl --summary all
```

Expected: compilation fails because `gpu_epoch.zig` and its API do not exist.

- [ ] **Step 3: Implement the shared orchestration**

Create `src/render/gpu_epoch.zig`:

```zig
pub fn handlesMatch(
    current_draw: anytype,
    expected_draw: @TypeOf(current_draw),
    current_context: anytype,
    expected_context: @TypeOf(current_context),
) bool {
    return current_draw == expected_draw and current_context == expected_context;
}

pub fn acquireCurrent(comptime Ops: type, ops: *Ops) bool {
    for (0..ops.candidateCount()) |index| {
        if (ops.tryMakeCurrent(index)) return true;
    }
    return false;
}

pub fn close(comptime Ops: type, ops: *Ops) void {
    ops.detachAll();
    const has_current = acquireCurrent(Ops, ops);
    const count = ops.candidateCount();
    if (has_current) {
        ops.deleteAppGl();
        for (0..count) |index| ops.deleteSurfaceGl(index);
    }
    ops.clearCurrent();
    for (0..count) |index| ops.destroySurface(index);
    ops.destroyContext();
    ops.clearHandles();
}

pub fn shouldStart(has_context: bool, permanent_failure: bool, ready_outputs: usize) bool {
    return !has_context and !permanent_failure and ready_outputs > 0;
}

pub fn start(comptime Ops: type, ops: *Ops) bool {
    if (!shouldStart(
        ops.hasContext(),
        ops.permanentFailure(),
        ops.readyOutputCount(),
    )) return ops.hasContext();
    return ops.createContext();
}

pub fn requiresCpuFallback(permanent_failure: bool, gpu_only: bool) bool {
    return permanent_failure and gpu_only;
}
```

- [ ] **Step 4: Run focused and full tests**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase2-task4 zig build test-wayland-egl --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase2-task4 zig build test --summary all
```

Expected: all fake-backend ordering and state tests pass with no EGL driver.

- [ ] **Step 5: Commit**

```sh
git add build.zig src/test_exports.zig src/render/gpu_epoch.zig tests/wayland_egl/gpu_epoch_test.zig
git commit -m "refactor(renderer): add GPU epoch orchestration"
```

### Task 5: Validate real EGL current-context ownership

**Audit rows:** `GPU-M3`

**Files:**

- Modify: `src/render/egl_surface.zig`
- Modify: `src/render/egl_context.zig`
- Test: `tests/wayland_egl/gpu_epoch_test.zig`

**Interfaces:**

- Consumes: `gpu_epoch.handlesMatch` from Task 4 and checked `Extent` from Task 1.
- Produces: confirmed `EglSurface.isCurrent`, postcondition-checked `makeCurrent`, and split `EglContext.clearCurrent`/`destroy` operations.

- [ ] **Step 1: Strengthen the handle-predicate regression tests**

Add exact cases for same draw/different context, different draw/same context, and both matching to `gpu_epoch_test.zig`.

- [ ] **Step 2: Run the focused test and record the production gap**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase2-task5 zig build test-wayland-egl --summary all
rg -n 'eglGetCurrentSurface' src/render/egl_surface.zig
```

Expected: helper tests pass; the scan shows production checks only the draw-surface handle.

- [ ] **Step 3: Use the shared predicate in EGL wrappers**

Implement:

```zig
pub fn isCurrent(self: *const EglSurface, ctx: *const EglContext) bool {
    return gpu_epoch.handlesMatch(
        c.eglGetCurrentSurface(c.EGL_DRAW),
        self.egl_surface,
        c.eglGetCurrentContext(),
        ctx.context,
    );
}

pub fn makeCurrent(self: *EglSurface, ctx: *const EglContext) bool {
    if (self.isCurrent(ctx)) return true;
    if (c.eglMakeCurrent(ctx.display, self.egl_surface, self.egl_surface, ctx.context) != c.EGL_TRUE) {
        return false;
    }
    return self.isCurrent(ctx);
}
```

Split context cleanup without changing `deinit` behavior:

```zig
pub fn clearCurrent(self: *const EglContext) void {
    _ = c.eglMakeCurrent(self.display, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, c.EGL_NO_CONTEXT);
}

pub fn destroy(self: *EglContext) void {
    _ = c.eglDestroyContext(self.display, self.context);
    _ = c.eglTerminate(self.display);
    _ = c.eglReleaseThread();
    self.display = c.EGL_NO_DISPLAY;
    self.context = c.EGL_NO_CONTEXT;
}

pub fn deinit(self: *EglContext) void {
    self.clearCurrent();
    self.destroy();
}
```

Before `EglSurface.deinit` destroys its surface, clear the current binding when `eglGetCurrentSurface(EGL_DRAW)` equals that surface.

- [ ] **Step 4: Run the executable and full tests**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase2-task5 zig build
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase2-task5 zig build test --summary all
```

Expected: build and all tests pass.

- [ ] **Step 5: Commit**

```sh
git add src/render/egl_surface.zig src/render/egl_context.zig tests/wayland_egl/gpu_epoch_test.zig
git commit -m "fix(renderer): validate current EGL ownership"
```

### Task 6: Centralize surface detachment and GPU epoch teardown

**Audit rows:** `WL-H1`, `GPU-M2`, `GPU-M3`

**Files:**

- Modify: `src/wayland/surface_state.zig`
- Modify: `src/app.zig`
- Modify: `src/test_wayland_exports.zig`
- Modify: `build.zig`
- Create: `tests/wayland_egl/surface_detach_test.zig`
- Test: `tests/wayland_egl/gpu_epoch_test.zig`

**Interfaces:**

- Consumes: Tasks 1–5, especially `gpu_epoch.close` and checked `Extent`.
- Produces: `SurfaceState.DetachedGpu`, `detachGpu`, `configureCpuFallbackAfterDetach`, App-owned preallocated detach scratch, and one epoch-close backend.

- [ ] **Step 1: Add failing lifecycle cases for dead/zero/unconfigured detachment and multi-candidate shutdown**

Extend `FakeOps` with `detached: [4]bool = @splat(false)` and replace `detachAll` with this implementation:

```zig
pub fn detachAll(self: *FakeOps) void {
    self.record(.detach_all);
    for (0..self.count) |index| self.detached[index] = true;
}

test "every candidate detaches before context destruction" {
    var ops = FakeOps{ .successes = .{ true, false, false, false }, .count = 3 };
    gpu_epoch.close(FakeOps, &ops);
    try std.testing.expect(ops.detached[0]);
    try std.testing.expect(ops.detached[1]);
    try std.testing.expect(ops.detached[2]);
    try std.testing.expectEqual(.detach_all, eventTag(ops.events[0]));
    try std.testing.expect(firstTag(&ops, .destroy_context).? > 0);
}

test "shutdown continues after the first makeCurrent failure" {
    var ops = FakeOps{ .successes = .{ false, true, false, false }, .count = 3 };
    gpu_epoch.close(FakeOps, &ops);
    try std.testing.expectEqual(@as(usize, 0), ops.events[1].try_current);
    try std.testing.expectEqual(@as(usize, 1), ops.events[2].try_current);
    try std.testing.expect(firstTag(&ops, .delete_app_gl) != null);
}

test "all acquisition failures rely on context destruction without GL calls" {
    var ops = FakeOps{ .count = 3 };
    gpu_epoch.close(FakeOps, &ops);
    try std.testing.expectEqual(@as(?usize, null), firstTag(&ops, .delete_app_gl));
    try std.testing.expectEqual(@as(?usize, null), firstTag(&ops, .delete_surface_gl));
    try std.testing.expect(firstTag(&ops, .destroy_context).? < firstTag(&ops, .clear_handles).?);
}
```

Export the real production type through `src/test_wayland_exports.zig`:

```zig
pub const surface_state = @import("wayland/surface_state.zig");
pub const dimensions = @import("wayland/dimensions.zig");
pub const egl_context = @import("render/egl_context.zig");
```

Create `tests/wayland_egl/surface_detach_test.zig`. These tests intentionally initialize only fields read or written by `detachGpu`; they do not invoke Wayland or EGL:

```zig
const std = @import("std");
const wayland = @import("wayland_test");
const SurfaceState = wayland.surface_state.SurfaceState;

fn setDetachFields(state: *SurfaceState, dead: bool, configured: bool, has_extent: bool) void {
    state.dead = dead;
    state.configured = configured;
    state.extent = if (has_extent)
        wayland.dimensions.Extent.init(1920, 1080) catch unreachable
    else
        null;
    state.egl_ctx = @as(
        *const wayland.egl_context.EglContext,
        @ptrFromInt(0x1000),
    );
    state.egl_surface = null;
    state.offscreen = null;
}

fn expectDetached(state: *SurfaceState) !void {
    const detached = state.detachGpu();
    try std.testing.expect(detached.egl_surface == null);
    try std.testing.expect(detached.offscreen == null);
    try std.testing.expect(state.egl_ctx == null);
    try std.testing.expect(state.egl_surface == null);
    try std.testing.expect(state.offscreen == null);
}

test "dead surface invalidates its context borrow" {
    var state: SurfaceState = undefined;
    setDetachFields(&state, true, true, true);
    try expectDetached(&state);
}

test "zero-sized surface invalidates its context borrow" {
    var state: SurfaceState = undefined;
    setDetachFields(&state, false, false, false);
    try expectDetached(&state);
}

test "unconfigured surface invalidates its context borrow" {
    var state: SurfaceState = undefined;
    setDetachFields(&state, false, false, true);
    try expectDetached(&state);
}
```

Wire it beside the Task 3 C-linked test artifact:

```zig
const surface_detach_test_mod = b.createModule(.{
    .root_source_file = b.path("tests/wayland_egl/surface_detach_test.zig"),
    .target = target,
    .optimize = optimize,
});
surface_detach_test_mod.addImport("wayland_test", wayland_exports_mod);
const surface_detach_tests = b.addTest(.{ .root_module = surface_detach_test_mod });
const run_surface_detach_tests = b.addRunArtifact(surface_detach_tests);
phase2_test_step.dependOn(&run_surface_detach_tests.step);
test_step.dependOn(&run_surface_detach_tests.step);
```

- [ ] **Step 2: Run red against current production structure**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase2-task6 zig build test-wayland-egl --summary all
rg -n 'if \(self.dead\) return|pw == 0 or ph == 0' src/wayland/surface_state.zig
```

Expected: compilation fails because real `SurfaceState.detachGpu`/`extent` do not exist, while the scan proves production still returns before invalidating the borrow.

- [ ] **Step 3: Add unconditional surface detachment**

Add:

```zig
pub const DetachedGpu = struct {
    egl_surface: ?EglSurface,
    offscreen: ?Offscreen,
};

pub fn detachGpu(self: *SurfaceState) DetachedGpu {
    const detached = DetachedGpu{
        .egl_surface = self.egl_surface,
        .offscreen = self.offscreen,
    };
    self.egl_ctx = null;
    self.egl_surface = null;
    self.offscreen = null;
    return detached;
}

pub fn configureCpuFallbackAfterDetach(self: *SurfaceState) void {
    std.debug.assert(self.egl_ctx == null);
    std.debug.assert(self.egl_surface == null);
    std.debug.assert(self.offscreen == null);
    if (self.dead) return;
    const extent = self.extent orelse {
        self.configured = false;
        return;
    };
    self.configureShmFallback(extent) catch |err| {
        std.debug.print("failed to configure CPU fallback: {}\n", .{err});
        self.configured = false;
    };
}
```

Split non-GPU teardown into a method that asserts all three GPU fields are null. Change `layerSurfaceClosed` to record `dead = true` only; the main-loop reaper performs teardown outside callback dispatch.

Add `torn_down: bool` beside `dead`, initialize it to `false`, and make the non-GPU teardown idempotent independently of the compositor's `dead` fact:

```zig
fn teardownWayland(self: *SurfaceState) void {
    if (self.torn_down) return;
    self.torn_down = true;
    std.debug.assert(self.egl_ctx == null);
    std.debug.assert(self.egl_surface == null);
    std.debug.assert(self.offscreen == null);

    if (self.frame_callback) |cb| {
        c.wl_callback_destroy(cb);
        self.frame_callback = null;
    }
    if (self.configured) {
        if (self.layer_surface.wl_surface) |ws| {
            c.wl_surface_attach(ws, null, 0, 0);
            c.wl_surface_commit(ws);
        }
    }
    self.layer_surface.destroy();
    if (self.shm_pool) |*pool| {
        pool.deinit();
        self.shm_pool = null;
    }
    if (self.cell_grid.len > 0) {
        self.allocator.free(self.cell_grid);
        self.cell_grid = &.{};
    }
    self.configured = false;
    self.shm_effect = null;
}

pub fn deinit(self: *SurfaceState) void {
    self.teardownWayland();
}
```

`layerSurfaceClosed` must only set `dead = true`; it must not destroy listener-owned objects during libwayland callback dispatch. Callers invoke `deinit()` regardless of `dead`, and `torn_down` prevents double teardown.

- [ ] **Step 4: Add App scratch ownership and the production epoch backend**

Add to `App`:

```zig
detached_gpu: std.ArrayList(SurfaceState.DetachedGpu),
```

Initialize it to `.empty` and deinitialize it with the allocator. Before `SurfaceState.create`, reserve both the published surface slot and the matching cleanup slot transactionally:

```zig
self.surfaces.ensureUnusedCapacity(self.allocator, 1) catch |err| {
    std.debug.print("surface list reserve failed for output {}: {}\n", .{ out.registry_name, err });
    continue;
};
self.detached_gpu.ensureTotalCapacity(
    self.allocator,
    self.surfaces.items.len + 1,
) catch |err| {
    std.debug.print("surface GPU cleanup reserve failed for output {}: {}\n", .{ out.registry_name, err });
    continue;
};
```

After `SurfaceState.create` succeeds, publish it with `self.surfaces.appendAssumeCapacity(surface_state)`. No allocation may occur between listener registration and list publication.

Implement `closeGpuEpoch` with this App adapter. The adapter borrows the context from `App`, while `detached_gpu` owns every detached surface wrapper until its EGL surface has been destroyed:

```zig
const GpuEpochOps = struct {
    app: *App,
    ctx: *EglContext,

    pub fn detachAll(self: *GpuEpochOps) void {
        for (self.app.surfaces.items) |surface| {
            self.app.detached_gpu.appendAssumeCapacity(surface.detachGpu());
        }
    }

    pub fn candidateCount(self: *GpuEpochOps) usize {
        return self.app.detached_gpu.items.len;
    }

    pub fn tryMakeCurrent(self: *GpuEpochOps, index: usize) bool {
        const egl_surface = if (self.app.detached_gpu.items[index].egl_surface) |*value| value else return false;
        return egl_surface.makeCurrent(self.ctx);
    }

    pub fn deleteAppGl(self: *GpuEpochOps) void {
        if (self.app.blit_shader) |*shader| shader.deinit();
        self.app.blit_shader = null;
        if (self.app.effect_shader) |*shader| shader.deinit();
        self.app.effect_shader = null;
    }

    pub fn deleteSurfaceGl(self: *GpuEpochOps, index: usize) void {
        const detached = &self.app.detached_gpu.items[index];
        if (detached.offscreen) |*offscreen| offscreen.deinit();
        detached.offscreen = null;
    }

    pub fn clearCurrent(self: *GpuEpochOps) void {
        self.ctx.clearCurrent();
    }

    pub fn destroySurface(self: *GpuEpochOps, index: usize) void {
        const detached = &self.app.detached_gpu.items[index];
        if (detached.egl_surface) |*egl_surface| egl_surface.deinit();
        detached.egl_surface = null;
    }

    pub fn destroyContext(self: *GpuEpochOps) void {
        self.ctx.destroy();
        self.app.egl_ctx = null;
    }

    pub fn clearHandles(self: *GpuEpochOps) void {
        self.app.blit_shader = null;
        self.app.effect_shader = null;
        for (self.app.detached_gpu.items) |*detached| {
            std.debug.assert(detached.egl_surface == null);
            detached.offscreen = null;
        }
        self.app.detached_gpu.clearRetainingCapacity();
        for (self.app.surfaces.items) |surface| {
            std.debug.assert(surface.egl_ctx == null);
            std.debug.assert(surface.egl_surface == null);
            std.debug.assert(surface.offscreen == null);
        }
    }
};

fn closeGpuEpoch(self: *App) void {
    const ctx = if (self.egl_ctx) |*value| value else {
        std.debug.assert(self.detached_gpu.items.len == 0);
        std.debug.assert(self.effect_shader == null);
        std.debug.assert(self.blit_shader == null);
        return;
    };
    var ops = GpuEpochOps{ .app = self, .ctx = ctx };
    gpu_epoch.close(GpuEpochOps, &ops);
}
```

`detachAll` may begin with one entry already in scratch when partial retirement escalates. In that case the retiring surface has already been removed from `self.surfaces`, so the loop appends only survivors. The reserved capacity remains sufficient: one retired entry plus `n - 1` survivors equals the previous `n` surfaces.

Every `SurfaceState.deinit()` call therefore follows either `retireSurfaceGpu` or `closeGpuEpoch`; there is no fallible append cleanup path holding a live borrowed context.

At the end assert in Debug that every surface has null GPU fields whenever `self.egl_ctx == null`.

- [ ] **Step 5: Route shutdown and GPU-only fallback through the shared closure**

Replace the hand-written shutdown acquisition/deletion block with:

```zig
self.closeGpuEpoch();
```

Then run non-GPU surface teardown and output teardown. Replace `forceCpuFallbackForGpuOnly` with:

```zig
fn forceCpuFallbackForGpuOnly(self: *App) void {
    if (!self.effect.isGpuOnly()) return;
    self.closeGpuEpoch();
    for (self.surfaces.items) |surface| {
        surface.configureCpuFallbackAfterDetach();
    }
}
```

The close backend must null CPU wrappers without calling their GL destructors when no context was confirmed current.

- [ ] **Step 6: Run focused, build, and full tests**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase2-task6 zig build test-wayland-egl --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase2-task6 zig build
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase2-task6 zig build test --summary all
```

Expected: fake lifecycle ordering, executable build, and all tests pass.

- [ ] **Step 7: Commit**

```sh
git add build.zig src/app.zig src/test_wayland_exports.zig src/wayland/surface_state.zig tests/wayland_egl/gpu_epoch_test.zig tests/wayland_egl/surface_detach_test.zig
git commit -m "fix(app): centralize GPU epoch teardown"
```

### Task 7: Preserve ownership during hotplug, effect switching, and filter changes

**Audit rows:** `GPU-M1`, `GPU-M2`, remaining `GPU-M3`

**Files:**

- Modify: `src/app.zig`
- Modify: `src/render/gpu_epoch.zig`
- Modify: `src/wayland/surface_state.zig`
- Modify: `src/render/offscreen.zig`
- Test: `tests/wayland_egl/gpu_epoch_test.zig`

**Interfaces:**

- Consumes: App epoch closure and detach scratch from Task 6.
- Produces: safe per-surface retirement, recoverable zero-output closure, lazy epoch recreation, and transactional filter replacement.

- [ ] **Step 1: Add failing state/ownership tests**

Add these tests to the driver-independent suite:

```zig
test "recoverable idle state does not latch fallback and restarts on return" {
    const permanent_failure = false;
    try std.testing.expect(!gpu_epoch.requiresCpuFallback(permanent_failure, true));
    for (0..3) |_| {
        try std.testing.expect(!gpu_epoch.shouldStart(false, permanent_failure, 0));
    }
    try std.testing.expect(gpu_epoch.shouldStart(false, permanent_failure, 1));
}

test "permanent context failure still forces a GPU-only effect to CPU" {
    try std.testing.expect(gpu_epoch.requiresCpuFallback(true, true));
    try std.testing.expect(!gpu_epoch.shouldStart(false, true, 1));
}

test "failed current acquisition retains ownership until context destruction" {
    var ops = FakeOps{ .count = 2 };
    gpu_epoch.close(FakeOps, &ops);
    try std.testing.expectEqual(@as(?usize, null), firstTag(&ops, .delete_app_gl));
    try std.testing.expectEqual(@as(?usize, null), firstTag(&ops, .delete_surface_gl));
    try std.testing.expect(firstTag(&ops, .destroy_context).? < firstTag(&ops, .clear_handles).?);
}

const ReplacementOps = struct {
    acquire_succeeds: bool,
    create_succeeds: bool,
    owner: u32 = 11,
    deleted_owner: ?u32 = null,
    create_calls: usize = 0,

    pub fn acquireCurrent(self: *ReplacementOps) bool {
        return self.acquire_succeeds;
    }
    pub fn createReplacement(self: *ReplacementOps) !u32 {
        self.create_calls += 1;
        if (!self.create_succeeds) return error.InjectedCreationFailure;
        return 22;
    }
    pub fn commitReplacement(self: *ReplacementOps, replacement: u32) void {
        const old = self.owner;
        self.owner = replacement;
        self.deleted_owner = old;
    }
};

test "replacement retains the old owner when acquisition fails" {
    var ops = ReplacementOps{ .acquire_succeeds = false, .create_succeeds = true };
    try std.testing.expect(!gpu_epoch.replaceCurrentOwned(ReplacementOps, &ops));
    try std.testing.expectEqual(@as(u32, 11), ops.owner);
    try std.testing.expectEqual(@as(?u32, null), ops.deleted_owner);
    try std.testing.expectEqual(@as(usize, 0), ops.create_calls);
}

test "replacement retains the old owner when creation fails" {
    var ops = ReplacementOps{ .acquire_succeeds = true, .create_succeeds = false };
    try std.testing.expect(!gpu_epoch.replaceCurrentOwned(ReplacementOps, &ops));
    try std.testing.expectEqual(@as(u32, 11), ops.owner);
    try std.testing.expectEqual(@as(?u32, null), ops.deleted_owner);
}

test "replacement transfers ownership before deleting the old owner" {
    var ops = ReplacementOps{ .acquire_succeeds = true, .create_succeeds = true };
    try std.testing.expect(gpu_epoch.replaceCurrentOwned(ReplacementOps, &ops));
    try std.testing.expectEqual(@as(u32, 22), ops.owner);
    try std.testing.expectEqual(@as(?u32, 11), ops.deleted_owner);
}
```

- [ ] **Step 2: Run the red/characterization checks**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase2-task7 zig build test-wayland-egl --summary all
rg -n 'self.effect_shader = null|self.offscreen = null|egl_ctx == null or self.gpu_pipeline_failed' src/app.zig src/wayland/surface_state.zig
```

Expected: compilation fails because `replaceCurrentOwned` does not exist; the already-green state tests still describe idle/permanent behavior, and the scan shows current ownership-discard and idle-fallback branches.

- [ ] **Step 3: Add safe partial-surface retirement**

In `reapSurfaces`, first `swapRemove` the retiring surface from `self.surfaces`, but keep its heap allocation alive. Then call `retireSurfaceGpu(surface)` before `surface.deinit()` and `allocator.destroy(surface)`. Removing it first guarantees an escalated whole-epoch close sees only survivors and keeps the scratch-capacity invariant from Task 6.

Implement the retirement flow exactly as follows:

```zig
fn retireSurfaceGpu(self: *App, surface: *SurfaceState) void {
    const detached_index = self.detached_gpu.items.len;
    self.detached_gpu.appendAssumeCapacity(surface.detachGpu());
    const detached = &self.detached_gpu.items[detached_index];

    if (self.surfaces.items.len == 0) {
        self.closeGpuEpoch();
        return;
    }

    if (self.egl_ctx) |*ctx| {
        var current = false;
        if (detached.egl_surface) |*egl_surface| current = egl_surface.makeCurrent(ctx);
        if (!current) {
            for (self.surfaces.items) |survivor| {
                if (survivor.egl_surface) |*egl_surface| {
                    if (egl_surface.makeCurrent(ctx)) {
                        current = true;
                        break;
                    }
                }
            }
        }

        if (current) {
            if (detached.offscreen) |*offscreen| offscreen.deinit();
            detached.offscreen = null;
            ctx.clearCurrent();
            if (detached.egl_surface) |*egl_surface| egl_surface.deinit();
            detached.egl_surface = null;
            _ = self.detached_gpu.pop();
            return;
        }

        if (detached.offscreen != null) {
            self.gpu_pipeline_failed = true;
            self.closeGpuEpoch();
            for (self.surfaces.items) |survivor| survivor.configureCpuFallbackAfterDetach();
            return;
        }
    }

    std.debug.assert(detached.offscreen == null);
    if (detached.egl_surface) |*egl_surface| egl_surface.deinit();
    detached.egl_surface = null;
    _ = self.detached_gpu.pop();
}
```

The caller asserts `detached_gpu.items.len == 0` after normal retirement or after an escalated `closeGpuEpoch`. It must never free `SurfaceState` while its detached entry remains in scratch. If the retiring surface owns an offscreen GL object and no compatible surface can make the context current, retaining the entry and escalating is mandatory; context destruction is what releases that GL ownership.

The retirement path therefore:

- deletes the detached offscreen only after confirmation;
- clears a matching current binding before destroying the detached EGL surface;
- removes the retired entry from scratch after destruction;
- escalates to `closeGpuEpoch`, sets `gpu_pipeline_failed = true`, and configures surviving surfaces for CPU fallback if GL ownership exists but no candidate succeeds.

- [ ] **Step 4: Close and recreate epochs only at the output boundary**

The last-surface branch above calls `closeGpuEpoch()` while its detached EGL surface is still available as a current-context candidate; it must not set `gpu_pipeline_failed`. At the end of reaping, an idempotent `closeGpuEpoch()` when `self.surfaces.items.len == 0` is allowed as a defensive invariant check, but the real epoch closure must already have happened through the retained last-surface entry.

Move EGL initialization out of `setup` and route the production decision through the tested `gpu_epoch.start` helper:

```zig
fn readyOutputCount(self: *const App) usize {
    var count: usize = 0;
    for (self.outputs.items) |output| {
        if (output.done and !output.removed) count += 1;
    }
    return count;
}

const StartGpuEpochOps = struct {
    app: *App,

    pub fn hasContext(self: *StartGpuEpochOps) bool {
        return self.app.egl_ctx != null;
    }

    pub fn permanentFailure(self: *StartGpuEpochOps) bool {
        return self.app.gpu_pipeline_failed;
    }

    pub fn readyOutputCount(self: *StartGpuEpochOps) usize {
        return self.app.readyOutputCount();
    }

    pub fn createContext(self: *StartGpuEpochOps) bool {
        self.app.egl_ctx = EglContext.init(self.app.display) catch |err| {
            std.debug.print("EGL init failed: {}, falling back to CPU path\n", .{err});
            self.app.gpu_pipeline_failed = true;
            return false;
        };
        return true;
    }
};

fn startGpuEpoch(self: *App) bool {
    var ops = StartGpuEpochOps{ .app = self };
    return gpu_epoch.start(StartGpuEpochOps, &ops);
}
```

Call it in `syncSurfaces` before creating the first missing surface. Use `requiresCpuFallback` so a deliberately idle null context does not convert a selected GPU-only effect to colormix; only permanent creation/pipeline failure does.

- [ ] **Step 5: Stop effect switching from losing shader ownership**

When an effect shader exists, try every surface for a confirmed current context. If successful, delete it normally. If every candidate fails, set `gpu_pipeline_failed = true`, close the whole epoch, and configure **all** surviving surfaces for CPU fallback; `SurfaceState.cpuEffect` supplies the colormix stand-in for GPU-only effects. When the epoch is recoverably idle (`egl_ctx == null` and `gpu_pipeline_failed == false`), update `self.effect` without creating or deleting GPU resources and without converting a GPU-only selection; the next epoch rebuilds the selected shader lazily.

- [ ] **Step 6: Make filter replacement transactional through the tested helper**

Add the driver-independent helper to `gpu_epoch.zig`:

```zig
pub fn replaceCurrentOwned(comptime Ops: type, ops: *Ops) bool {
    if (!ops.acquireCurrent()) return false;
    const replacement = ops.createReplacement() catch return false;
    ops.commitReplacement(replacement);
    return true;
}
```

Add `filter: UpscaleFilter` to `Offscreen`, initialized by `Offscreen.init`. In `surface_state.zig`, add this production adapter:

```zig
const OffscreenReplacementOps = struct {
    surface: *SurfaceState,
    ctx: *const EglContext,
    extent: Extent,
    filter: UpscaleFilter,

    pub fn acquireCurrent(self: *OffscreenReplacementOps) bool {
        const egl_surface = if (self.surface.egl_surface) |*value| value else return false;
        return egl_surface.makeCurrent(self.ctx);
    }

    pub fn createReplacement(self: *OffscreenReplacementOps) !Offscreen {
        return Offscreen.init(self.extent, self.filter);
    }

    pub fn commitReplacement(self: *OffscreenReplacementOps, replacement: Offscreen) void {
        var old = self.surface.offscreen.?;
        self.surface.offscreen = replacement;
        old.deinit();
    }
};
```

On filter reload, update the desired filter but do not drop the old object. In `applyRendererScale`, when an existing `Offscreen.filter` differs, construct this adapter with the newly checked scaled extent and call `gpu_epoch.replaceCurrentOwned`. A false result logs that replacement is deferred and leaves the old wrapper and handles owned. Other resize/create/delete branches continue to confirm the context before GL calls. Remove `dropOffscreenForFilterChange` and its ownership-discard branch.

- [ ] **Step 7: Run targeted static scans and regressions**

```sh
rg -n 'orphan|leaked|GL cleanup may be incomplete|dropOffscreenForFilterChange' src/app.zig src/wayland/surface_state.zig
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase2-task7 zig build test-wayland-egl --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase2-task7 zig build
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase2-task7 zig build test --summary all
```

Expected: ownership-loss comments/paths are gone and all checks pass.

- [ ] **Step 8: Commit**

```sh
git add src/app.zig src/render/gpu_epoch.zig src/wayland/surface_state.zig src/render/offscreen.zig tests/wayland_egl/gpu_epoch_test.zig
git commit -m "fix(app): recover GPU epochs after hotplug"
```

### Task 8: Verify all modes, run live Niri acceptance, and close the ledger

**Audit rows:** `WL-H1`, `WL-H2`, `GPU-M1`, `GPU-M2`, `GPU-M3`, `WL-L1`

**Files:**

- Modify: `docs/security/2026-07-19-security-performance-audit.md`

**Interfaces:**

- Consumes: all Phase 2 implementation commits and the approved design.
- Produces: repeatable automated/live evidence and final ledger dispositions.

- [ ] **Step 1: Run formatting, static ownership scans, and diff checks**

```sh
zig fmt --check build.zig src tests
git diff --check
rg -n '@intCast\((pw|ph|width|height|w|h)\)|orphan|offscreen FBO leaked|GL cleanup may be incomplete' src/app.zig src/wayland src/render
```

Expected: formatting/diff checks exit zero and the audit-pattern scan finds no Phase 2 ownership loss or compositor-derived narrowing path. Review any unrelated cast match manually rather than suppressing it blindly.

- [ ] **Step 2: Run Debug verification**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase2-debug zig build --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase2-debug zig build test --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase2-debug zig test src/config/config.zig
```

Expected: executable, focused tests, full graph, and all 48 config tests pass.

- [ ] **Step 3: Run ReleaseSafe verification**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase2-safe zig build -Doptimize=ReleaseSafe --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase2-safe zig build test -Doptimize=ReleaseSafe --summary all
```

Expected: build and full test graph pass.

- [ ] **Step 4: Run ReleaseFast verification**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase2-fast zig build -Doptimize=ReleaseFast --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-phase2-fast zig build test -Doptimize=ReleaseFast --summary all
```

Expected: build and full test graph pass without relying on safe-build overflow traps.

- [ ] **Step 5: Prepare the live Niri recovery path before changing outputs**

Resolve the compositor socket and exact output names with read-only Niri commands, inspect the exact wlchroma PID/executable, create an independent user-systemd recovery timer that re-enables the selected outputs using absolute command paths and the explicit current `NIRI_SOCKET`, and dry-run it while displays remain enabled. Confirm the recovery unit succeeds in the user journal before proceeding.

- [ ] **Step 6: Run live acceptance in increasing-risk order**

Verify, recording commands and observed results:

1. Launch the new binary without replacing an unrelated session process.
2. Query and switch between colormix and a GPU-only effect.
3. Change scale/filter and confirm rendering remains visible.
4. Resize/reconfigure one output.
5. Disable and restore one non-primary output; confirm the survivor keeps rendering.
6. Confirm the recovery timer is armed, disable all test outputs, switch effects while output-less, and wait for automatic restoration.
7. Confirm the daemon stayed alive, the selected effect renders through a fresh GPU epoch, IPC responds, and logs show ordered cleanup without stale-pointer/resource warnings.
8. Stop only the exact test process and confirm clean shutdown.

- [ ] **Step 7: Update the audit ledger and completion evidence**

Change only the six Phase 2 ledger statuses to `Fixed (<commit ids>)`. Append a Phase 2 completion record listing implementation commits, focused tests, Debug/ReleaseSafe/ReleaseFast totals, formatting/static evidence, live Niri compositor/session evidence, recovery precautions, and review results. Do not rewrite original finding descriptions.

- [ ] **Step 8: Commit the ledger**

```sh
git add docs/security/2026-07-19-security-performance-audit.md
git commit -m "docs(security): close phase two audit findings"
```
