const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const wayland = @import("wayland_test");
const App = wayland.app.App;
const FrameSchedule = wayland.frame_schedule.FrameSchedule;
const SurfaceState = wayland.surface_state.SurfaceState;

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
    palette_seen: ?[3]wayland.defaults.Rgb = null,

    pub fn hasReady(self: *@This(), _: *const App) bool {
        return self.ready;
    }

    pub fn render(self: *@This(), app: *App, _: u64) void {
        self.renders += 1;
        self.phase_seen = app.animation.phase;
        self.palette_seen = app.current_palette;
        if (self.block_after_render) self.ready = false;
    }
};

const PacingFixture = struct {
    app: App,
    storage: [2]SurfaceState,
    outputs: [2]wayland.output.OutputInfo,

    const colors: [3]wayland.defaults.Rgb = .{
        .{ .r = 0x10, .g = 0x20, .b = 0x30 },
        .{ .r = 0x40, .g = 0x50, .b = 0x60 },
        .{ .r = 0x70, .g = 0x80, .b = 0x90 },
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
        self.app.ipc_client = null;
        self.app.reload_job = null;
        self.app.reload_ops = wayland.reload_job.production_ops;
        App.TestAdapter.seedFrameTimerDisarmed(&self.app);
    }

    fn deinit(self: *@This()) void {
        self.app.surfaces.deinit(std.testing.allocator);
    }
};

fn service(fixture: *PacingFixture, now_ns: u64, timer: *FakeTimer, ops: *FakeFrameOps) !void {
    try App.TestAdapter.serviceFrameScheduleAt(
        &fixture.app,
        now_ns,
        FakeTimer,
        timer,
        FakeFrameOps,
        ops,
    );
}

test "all callback-blocked surfaces disarm without consuming overdue work" {
    var fixture: PacingFixture = undefined;
    try fixture.init(1, 4);
    defer fixture.deinit();
    fixture.app.frame_schedule = try FrameSchedule.begin(0, 4);
    App.TestAdapter.seedFrameTimerAbsolute(&fixture.app, 4);
    var timer = FakeTimer{};
    var ops = FakeFrameOps{ .ready = false };

    try service(&fixture, 16, &timer, &ops);

    try std.testing.expectEqual(@as(usize, 0), ops.renders);
    try std.testing.expectEqual(@as(f64, 0), fixture.app.animation.phase);
    try std.testing.expectEqual(@as(?u64, 4), fixture.app.frame_schedule.next_logical_deadline_ns);
    try std.testing.expectEqual(App.TestAdapter.TimerMode.disarmed, App.TestAdapter.timerMode(&fixture.app));
}

test "callback before deadline reuses the absolute deadline" {
    var fixture: PacingFixture = undefined;
    try fixture.init(1, 20);
    defer fixture.deinit();
    fixture.app.frame_schedule = try FrameSchedule.begin(100, 20);
    var timer = FakeTimer{};
    var ops = FakeFrameOps{ .ready = true };

    try service(&fixture, 110, &timer, &ops);

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
    var ops = FakeFrameOps{ .ready = true };

    try service(&fixture, 16, &timer, &ops);

    try std.testing.expectEqual(@as(usize, 1), ops.renders);
    try std.testing.expectApproxEqAbs(@as(f64, 0.04), fixture.app.animation.phase, 1e-12);
    try std.testing.expectEqual(@as(?u64, 20), fixture.app.frame_schedule.next_logical_deadline_ns);
    try std.testing.expectEqual(App.TestAdapter.TimerMode.disarmed, App.TestAdapter.timerMode(&fixture.app));
}

test "initial ready surface installs the first absolute one-shot" {
    var fixture: PacingFixture = undefined;
    try fixture.init(1, 20);
    defer fixture.deinit();
    var timer = FakeTimer{};
    var ops = FakeFrameOps{ .ready = true };

    try service(&fixture, 100, &timer, &ops);

    try std.testing.expectEqual(@as(?u64, 120), fixture.app.frame_schedule.next_logical_deadline_ns);
    try std.testing.expectEqual(@as(usize, 1), timer.calls);
    try std.testing.expect(timer.last_flags.?.ABSTIME);
    try std.testing.expectEqual(@as(i64, 120), timer.last_spec.?.it_value.nsec);
}

test "zero surfaces pause schedule and disarm once" {
    var fixture: PacingFixture = undefined;
    try fixture.init(0, 4);
    defer fixture.deinit();
    fixture.app.frame_schedule = try FrameSchedule.begin(0, 4);
    App.TestAdapter.seedFrameTimerAbsolute(&fixture.app, 4);
    var timer = FakeTimer{};
    var ops = FakeFrameOps{ .ready = false };

    try service(&fixture, 16, &timer, &ops);
    try std.testing.expectEqual(@as(usize, 1), timer.calls);
    try std.testing.expectEqual(std.mem.zeroes(linux.itimerspec), timer.last_spec.?);
    try std.testing.expectEqual(@as(?u64, null), fixture.app.frame_schedule.next_logical_deadline_ns);
    try std.testing.expectEqual(@as(f64, 0), fixture.app.animation.phase);

    try service(&fixture, 20, &timer, &ops);
    try std.testing.expectEqual(@as(usize, 1), timer.calls);
}

test "zero surfaces pause without sampling a failing clock" {
    var fixture: PacingFixture = undefined;
    try fixture.init(0, 20);
    defer fixture.deinit();
    fixture.app.frame_schedule = try FrameSchedule.begin(100, 20);
    var clock = FakeClock{ .failure = error.ClockGetTimeFailed };
    var timer = FakeTimer{};
    var ops = FakeFrameOps{ .ready = false };

    App.TestAdapter.serviceFrameSchedule(
        &fixture.app,
        FakeClock,
        &clock,
        FakeTimer,
        &timer,
        FakeFrameOps,
        &ops,
    );

    try std.testing.expectEqual(@as(usize, 0), clock.calls);
    try std.testing.expectEqual(@as(?u64, null), fixture.app.frame_schedule.next_logical_deadline_ns);
    try std.testing.expectEqual(App.TestAdapter.TimerMode.disarmed, App.TestAdapter.timerMode(&fixture.app));
    try std.testing.expect(!fixture.app.timer_recovery_pending);
}

test "zero surfaces pause logical schedule when timer disarm fails" {
    var fixture: PacingFixture = undefined;
    try fixture.init(0, 20);
    defer fixture.deinit();
    fixture.app.frame_schedule = try FrameSchedule.begin(100, 20);
    App.TestAdapter.seedFrameTimerAbsolute(&fixture.app, 120);
    var clock = FakeClock{ .value = 200 };
    var timer = FakeTimer{ .fail = true };
    var ops = FakeFrameOps{ .ready = false };

    App.TestAdapter.serviceFrameSchedule(
        &fixture.app,
        FakeClock,
        &clock,
        FakeTimer,
        &timer,
        FakeFrameOps,
        &ops,
    );

    try std.testing.expectEqual(@as(usize, 0), clock.calls);
    try std.testing.expectEqual(@as(usize, 1), timer.calls);
    try std.testing.expectEqual(@as(?u64, null), fixture.app.frame_schedule.next_logical_deadline_ns);
    try std.testing.expectEqual(@as(?u64, 120), App.TestAdapter.timerDeadline(&fixture.app));
    try std.testing.expect(fixture.app.timer_recovery_pending);
    try std.testing.expectEqual(@as(i32, 100), App.TestAdapter.pollTimeoutAt(&fixture.app, 200));
}

test "inactive schedule starts while the only surface is unconfigured" {
    var fixture: PacingFixture = undefined;
    try fixture.init(1, 20);
    defer fixture.deinit();
    fixture.storage[0].configured = false;
    var timer = FakeTimer{};
    var ops = FakeFrameOps{ .ready = App.TestAdapter.hasReadySurface(&fixture.app) };

    try service(&fixture, 100, &timer, &ops);

    try std.testing.expectEqual(@as(?u64, 120), fixture.app.frame_schedule.next_logical_deadline_ns);
    try std.testing.expectEqual(App.TestAdapter.TimerMode.disarmed, App.TestAdapter.timerMode(&fixture.app));
    try std.testing.expectEqual(@as(usize, 0), timer.calls);
    try std.testing.expectEqual(@as(usize, 0), ops.renders);
}

test "render success blocks and disarms while render failure schedules retry" {
    var blocked: PacingFixture = undefined;
    try blocked.init(1, 4);
    defer blocked.deinit();
    blocked.app.frame_schedule = try FrameSchedule.begin(0, 4);
    var blocked_timer = FakeTimer{};
    var blocked_ops = FakeFrameOps{ .ready = true, .block_after_render = true };
    try service(&blocked, 16, &blocked_timer, &blocked_ops);
    try std.testing.expectEqual(@as(usize, 1), blocked_ops.renders);
    try std.testing.expectEqual(App.TestAdapter.TimerMode.disarmed, App.TestAdapter.timerMode(&blocked.app));

    var ready: PacingFixture = undefined;
    try ready.init(1, 4);
    defer ready.deinit();
    ready.app.frame_schedule = try FrameSchedule.begin(0, 4);
    var ready_timer = FakeTimer{};
    var ready_ops = FakeFrameOps{ .ready = true, .block_after_render = false };
    try service(&ready, 16, &ready_timer, &ready_ops);
    try std.testing.expectEqual(@as(usize, 1), ready_ops.renders);
    try std.testing.expectEqual(@as(?u64, 20), App.TestAdapter.timerDeadline(&ready.app));
}

test "mixed ready and blocked surfaces follow the ready surface" {
    var fixture: PacingFixture = undefined;
    try fixture.init(2, 20);
    defer fixture.deinit();
    fixture.app.frame_schedule = try FrameSchedule.begin(0, 20);
    fixture.storage[0].frame_callback = @ptrFromInt(0x3000);

    try std.testing.expect(App.TestAdapter.hasReadySurface(&fixture.app));
    try std.testing.expectEqual(@as(i32, 0), fixture.outputs[0].refresh_mhz);
    try std.testing.expectEqual(@as(i32, 0), fixture.outputs[1].refresh_mhz);

    var timer = FakeTimer{};
    var ops = FakeFrameOps{ .ready = App.TestAdapter.hasReadySurface(&fixture.app) };
    try service(&fixture, 10, &timer, &ops);
    try std.testing.expectEqual(@as(?u64, 20), App.TestAdapter.timerDeadline(&fixture.app));
}

test "non-renderable surfaces cannot keep the timer awake" {
    const Mutation = enum { unconfigured, dead, torn_down, removed, extent_less };
    inline for (std.meta.tags(Mutation)) |mutation| {
        var fixture: PacingFixture = undefined;
        try fixture.init(1, 20);
        defer fixture.deinit();
        fixture.app.frame_schedule = try FrameSchedule.begin(0, 20);
        App.TestAdapter.seedFrameTimerAbsolute(&fixture.app, 20);
        switch (mutation) {
            .unconfigured => fixture.storage[0].configured = false,
            .dead => fixture.storage[0].dead = true,
            .torn_down => fixture.storage[0].torn_down = true,
            .removed => fixture.outputs[0].removed = true,
            .extent_less => fixture.storage[0].extent = null,
        }
        try std.testing.expect(!App.TestAdapter.hasReadySurface(&fixture.app));
        var timer = FakeTimer{};
        var ops = FakeFrameOps{ .ready = false };
        try service(&fixture, 10, &timer, &ops);
        try std.testing.expectEqual(@as(?u64, 20), fixture.app.frame_schedule.next_logical_deadline_ns);
        try std.testing.expectEqual(@as(usize, 0), ops.renders);
        try std.testing.expectEqual(App.TestAdapter.TimerMode.disarmed, App.TestAdapter.timerMode(&fixture.app));
    }
}

fn expectSequence(
    fixture: *PacingFixture,
    times: []const u64,
    ticks: []const f64,
    deadlines: []const u64,
    ready_indices: []const usize,
) !void {
    var timer = FakeTimer{};
    var ops = FakeFrameOps{ .ready = true, .block_after_render = true };
    for (times, ticks, deadlines, ready_indices) |now_ns, phase, deadline, ready_index| {
        for (fixture.storage[0..fixture.app.surfaces.items.len]) |*surface| {
            surface.frame_callback = @ptrFromInt(0x3000);
        }
        fixture.storage[ready_index].frame_callback = null;
        ops.ready = App.TestAdapter.hasReadySurface(&fixture.app);
        try service(fixture, now_ns, &timer, &ops);
        try std.testing.expectEqual(@as(usize, 1), ops.renders);
        try std.testing.expectApproxEqAbs(phase, fixture.app.animation.phase, 1e-12);
        try std.testing.expectEqual(@as(?u64, deadline), fixture.app.frame_schedule.next_logical_deadline_ns);
        fixture.storage[ready_index].frame_callback = @ptrFromInt(0x3000);
        ops.renders = 0;
    }
}

test "240 requested cadence advances four logical ticks at a 60Hz callback" {
    var fixture: PacingFixture = undefined;
    try fixture.init(1, 4_166_666);
    defer fixture.deinit();
    fixture.app.frame_schedule = try FrameSchedule.begin(0, 4_166_666);
    try expectSequence(&fixture, &.{16_666_666}, &.{0.04}, &.{20_833_330}, &.{0});
}

test "60-only callback sequence stays on one absolute timeline" {
    var fixture: PacingFixture = undefined;
    try fixture.init(1, 4_166_666);
    defer fixture.deinit();
    fixture.app.frame_schedule = try FrameSchedule.begin(0, 4_166_666);
    try expectSequence(
        &fixture,
        &.{ 16_666_666, 33_333_333, 50_000_000 },
        &.{ 0.04, 0.08, 0.12 },
        &.{ 20_833_330, 37_499_994, 54_166_658 },
        &.{ 0, 0, 0 },
    );
}

test "144-only callback sequence is not refresh-capped" {
    var fixture: PacingFixture = undefined;
    try fixture.init(1, 6_944_444);
    defer fixture.deinit();
    fixture.app.frame_schedule = try FrameSchedule.begin(0, 6_944_444);
    try expectSequence(
        &fixture,
        &.{ 6_944_444, 13_888_888, 20_833_332 },
        &.{ 0.01, 0.02, 0.03 },
        &.{ 13_888_888, 20_833_332, 27_777_776 },
        &.{ 0, 0, 0 },
    );
}

test "mixed 60 and 144 callback sequence shares the requested timeline" {
    var fixture: PacingFixture = undefined;
    try fixture.init(2, 4_166_666);
    defer fixture.deinit();
    fixture.app.frame_schedule = try FrameSchedule.begin(0, 4_166_666);
    try expectSequence(
        &fixture,
        &.{ 6_944_444, 13_888_888, 16_666_666 },
        &.{ 0.01, 0.03, 0.04 },
        &.{ 8_333_332, 16_666_664, 20_833_330 },
        &.{ 1, 1, 0 },
    );
    try std.testing.expectEqual(@as(i32, 0), fixture.outputs[0].refresh_mhz);
    try std.testing.expectEqual(@as(i32, 0), fixture.outputs[1].refresh_mhz);
}

test "withheld callback settles a completed fade on the next due render" {
    var fixture: PacingFixture = undefined;
    try fixture.init(1, 20);
    defer fixture.deinit();
    const target: [3]wayland.defaults.Rgb = .{
        .{ .r = 1, .g = 2, .b = 3 },
        .{ .r = 4, .g = 5, .b = 6 },
        .{ .r = 7, .g = 8, .b = 9 },
    };
    fixture.app.fade = .{ .start = PacingFixture.colors, .target = target, .start_ns = 0, .dur_ns = 100 };
    fixture.app.frame_schedule = try FrameSchedule.begin(0, 20);
    var timer = FakeTimer{};
    var ops = FakeFrameOps{ .ready = false };

    try service(&fixture, 50, &timer, &ops);
    try std.testing.expectEqual(@as(f64, 0), fixture.app.animation.phase);
    try std.testing.expect(fixture.app.fade != null);

    ops.ready = true;
    try service(&fixture, 200, &timer, &ops);

    try std.testing.expect(fixture.app.fade == null);
    try std.testing.expectEqual(target, fixture.app.current_palette);
    try std.testing.expectEqual(target, ops.palette_seen.?);
}

test "zero to one surface starts from retained phase without outputless catchup" {
    var fixture: PacingFixture = undefined;
    try fixture.init(0, 20);
    defer fixture.deinit();
    var timer = FakeTimer{};
    var ops = FakeFrameOps{ .ready = false };
    try service(&fixture, 100, &timer, &ops);
    try std.testing.expectEqual(@as(f64, 0), fixture.app.animation.phase);

    fixture.outputs[0] = .{
        .wl_output = null,
        .registry_name = 1,
        .name = "",
        .width = 1920,
        .height = 1080,
        .refresh_mhz = 0,
        .done = true,
        .removed = false,
        .allocator = std.testing.allocator,
    };
    fixture.storage[0] = undefined;
    fixture.storage[0].output = &fixture.outputs[0];
    fixture.storage[0].dead = false;
    fixture.storage[0].torn_down = false;
    fixture.storage[0].configured = true;
    fixture.storage[0].extent = try wayland.dimensions.Extent.init(1920, 1080);
    fixture.storage[0].frame_callback = null;
    fixture.storage[0].layer_surface = .{ .wl_surface = @ptrFromInt(0x1000), .layer_surface = null };
    try fixture.app.surfaces.append(std.testing.allocator, &fixture.storage[0]);
    ops.ready = true;
    try service(&fixture, 1_000, &timer, &ops);
    try std.testing.expectEqual(@as(f64, 0), fixture.app.animation.phase);
    try std.testing.expectEqual(@as(?u64, 1_020), fixture.app.frame_schedule.next_logical_deadline_ns);
}

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

test "active set-fps rebases deadline and commits only after timer success" {
    var fixture: PacingFixture = undefined;
    try fixture.init(1, 20);
    defer fixture.deinit();
    fixture.app.frame_schedule = try FrameSchedule.begin(100, 20);
    App.TestAdapter.seedFrameTimerAbsolute(&fixture.app, 120);
    var clock = FakeClock{ .value = 150 };
    var timer = FakeTimer{};

    try App.TestAdapter.applyFrameInterval(&fixture.app, 10, FakeClock, &clock, FakeTimer, &timer);
    try std.testing.expectEqual(@as(u32, 10), fixture.app.frame_interval_ns);
    try std.testing.expectEqual(@as(?u64, 160), fixture.app.frame_schedule.next_logical_deadline_ns);
    try std.testing.expectEqual(@as(?u64, 160), App.TestAdapter.timerDeadline(&fixture.app));

    fixture.app.frame_interval_ns = 20;
    fixture.app.frame_schedule = try FrameSchedule.begin(100, 20);
    App.TestAdapter.seedFrameTimerAbsolute(&fixture.app, 120);
    timer = .{ .fail = true };
    try std.testing.expectError(error.TimerFdSetTimeFailed, App.TestAdapter.applyFrameInterval(
        &fixture.app,
        10,
        FakeClock,
        &clock,
        FakeTimer,
        &timer,
    ));
    try std.testing.expectEqual(@as(u32, 20), fixture.app.frame_interval_ns);
    try std.testing.expectEqual(@as(?u64, 120), fixture.app.frame_schedule.next_logical_deadline_ns);
    try std.testing.expectEqual(@as(?u64, 120), App.TestAdapter.timerDeadline(&fixture.app));
}

test "callback-blocked set-fps rebases without arming a timer" {
    var fixture: PacingFixture = undefined;
    try fixture.init(1, 20);
    defer fixture.deinit();
    fixture.storage[0].frame_callback = @ptrFromInt(0x3000);
    fixture.app.frame_schedule = try FrameSchedule.begin(100, 20);
    var clock = FakeClock{ .value = 150 };
    var timer = FakeTimer{};
    try App.TestAdapter.applyFrameInterval(&fixture.app, 10, FakeClock, &clock, FakeTimer, &timer);
    try std.testing.expectEqual(@as(usize, 0), timer.calls);
    try std.testing.expectEqual(@as(?u64, 160), fixture.app.frame_schedule.next_logical_deadline_ns);

    fixture.storage[0].frame_callback = null;
    var ops = FakeFrameOps{ .ready = true };
    try service(&fixture, 159, &timer, &ops);
    try std.testing.expectEqual(@as(?u64, 160), App.TestAdapter.timerDeadline(&fixture.app));
    App.TestAdapter.seedFrameTimerDisarmed(&fixture.app);
    try service(&fixture, 160, &timer, &ops);
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), fixture.app.animation.phase, 1e-12);
}

test "outputless set-fps stores request without clock or timer work" {
    var fixture: PacingFixture = undefined;
    try fixture.init(0, 20);
    defer fixture.deinit();
    var clock = FakeClock{ .failure = error.ClockGetTimeFailed };
    var timer = FakeTimer{ .fail = true };
    try App.TestAdapter.applyFrameInterval(&fixture.app, 10, FakeClock, &clock, FakeTimer, &timer);
    try std.testing.expectEqual(@as(u32, 10), fixture.app.frame_interval_ns);
    try std.testing.expectEqual(@as(?u64, null), fixture.app.frame_schedule.next_logical_deadline_ns);
    try std.testing.expectEqual(@as(usize, 0), clock.calls);
    try std.testing.expectEqual(@as(usize, 0), timer.calls);
}

test "blocked no-change reconciliation allocates nothing" {
    var fixture: PacingFixture = undefined;
    try fixture.init(1, 20);
    defer fixture.deinit();
    fixture.storage[0].frame_callback = @ptrFromInt(0x3000);
    fixture.app.frame_schedule = try FrameSchedule.begin(100, 20);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    fixture.app.allocator = failing.allocator();
    var timer = FakeTimer{};
    var ops = FakeFrameOps{ .ready = false };

    for (0..3) |_| {
        try service(&fixture, 110, &timer, &ops);
        try std.testing.expect(!failing.has_induced_failure);
    }
    try std.testing.expectEqual(@as(usize, 0), timer.calls);
    try std.testing.expectEqual(@as(usize, 0), ops.renders);
}

test "EAGAIN after timer readiness cannot strand a ready surface" {
    var fixture: PacingFixture = undefined;
    try fixture.init(1, 20);
    defer fixture.deinit();
    fixture.app.frame_schedule = try FrameSchedule.begin(100, 20);
    App.TestAdapter.seedFrameTimerAbsolute(&fixture.app, 120);
    var reader = FakeReader{ .failure = error.WouldBlock };
    App.TestAdapter.consumeFrameTimer(&fixture.app, FakeReader, &reader);

    try std.testing.expectEqual(App.TestAdapter.TimerMode.disarmed, App.TestAdapter.timerMode(&fixture.app));
    try std.testing.expect(fixture.app.timer_recovery_pending);
    try std.testing.expectEqual(@as(f64, 0), fixture.app.animation.phase);

    var timer = FakeTimer{};
    var ops = FakeFrameOps{ .ready = true };
    try service(&fixture, 110, &timer, &ops);
    try std.testing.expectEqual(@as(usize, 1), timer.calls);
    try std.testing.expect(timer.last_flags.?.ABSTIME);
    try std.testing.expectEqual(@as(i64, 120), timer.last_spec.?.it_value.nsec);
}

test "short successful timer read clears trust and preserves animation until reconciliation" {
    var fixture: PacingFixture = undefined;
    try fixture.init(1, 20);
    defer fixture.deinit();
    fixture.app.frame_schedule = try FrameSchedule.begin(100, 20);
    fixture.app.fade = .{ .start = PacingFixture.colors, .target = PacingFixture.colors, .start_ns = 0, .dur_ns = 100 };
    App.TestAdapter.seedFrameTimerAbsolute(&fixture.app, 120);
    const schedule_before = fixture.app.frame_schedule;
    const fade_before = fixture.app.fade;
    var reader = FakeReader{ .result_len = 4 };

    App.TestAdapter.consumeFrameTimer(&fixture.app, FakeReader, &reader);

    try std.testing.expectEqual(App.TestAdapter.TimerMode.disarmed, App.TestAdapter.timerMode(&fixture.app));
    try std.testing.expect(fixture.app.timer_recovery_pending);
    try std.testing.expectEqual(@as(f64, 0), fixture.app.animation.phase);
    try std.testing.expectEqualDeep(schedule_before, fixture.app.frame_schedule);
    try std.testing.expectEqualDeep(fade_before, fixture.app.fade);
    var timer = FakeTimer{};
    var ops = FakeFrameOps{ .ready = true };
    try service(&fixture, 140, &timer, &ops);
    try std.testing.expectEqual(@as(usize, 1), ops.renders);
    try std.testing.expectApproxEqAbs(@as(f64, 0.02), fixture.app.animation.phase, 1e-12);
    try std.testing.expectEqual(@as(?u64, 160), fixture.app.frame_schedule.next_logical_deadline_ns);
}

test "EINTR after timer readiness cannot strand a ready surface" {
    var fixture: PacingFixture = undefined;
    try fixture.init(1, 20);
    defer fixture.deinit();
    fixture.app.frame_schedule = try FrameSchedule.begin(100, 20);
    App.TestAdapter.seedFrameTimerAbsolute(&fixture.app, 120);
    var reader = FakeReader{ .failure = error.Interrupted };
    App.TestAdapter.consumeFrameTimer(&fixture.app, FakeReader, &reader);
    try std.testing.expectEqual(App.TestAdapter.TimerMode.disarmed, App.TestAdapter.timerMode(&fixture.app));

    var timer = FakeTimer{};
    var ops = FakeFrameOps{ .ready = true };
    try service(&fixture, 110, &timer, &ops);
    try std.testing.expectEqual(@as(?u64, 120), App.TestAdapter.timerDeadline(&fixture.app));
}

test "zero expiration record never directly advances or renders" {
    var fixture: PacingFixture = undefined;
    try fixture.init(1, 20);
    defer fixture.deinit();
    fixture.app.frame_schedule = try FrameSchedule.begin(100, 20);
    App.TestAdapter.seedFrameTimerAbsolute(&fixture.app, 120);
    var reader = FakeReader{};

    App.TestAdapter.consumeFrameTimer(&fixture.app, FakeReader, &reader);

    try std.testing.expectEqual(App.TestAdapter.TimerMode.disarmed, App.TestAdapter.timerMode(&fixture.app));
    try std.testing.expect(fixture.app.timer_recovery_pending);
    try std.testing.expectEqual(@as(f64, 0), fixture.app.animation.phase);
    try std.testing.expectEqual(@as(?u64, 120), fixture.app.frame_schedule.next_logical_deadline_ns);
}

test "persistent clock failure logs only the first relative recovery cycle" {
    var fixture: PacingFixture = undefined;
    try fixture.init(1, 20);
    defer fixture.deinit();
    fixture.app.frame_schedule = try FrameSchedule.begin(100, 20);
    var clock = FakeClock{ .failure = error.ClockGetTimeFailed };
    var timer = FakeTimer{};
    var ops = FakeFrameOps{ .ready = true };

    App.TestAdapter.serviceFrameSchedule(&fixture.app, FakeClock, &clock, FakeTimer, &timer, FakeFrameOps, &ops);
    const first_log_marker = fixture.app.last_timer_error_log_ns;
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), first_log_marker);

    var reader = FakeReader{};
    std.mem.writeInt(u64, &reader.bytes, 1, @import("builtin").cpu.arch.endian());
    App.TestAdapter.consumeFrameTimer(&fixture.app, FakeReader, &reader);
    App.TestAdapter.serviceFrameSchedule(&fixture.app, FakeClock, &clock, FakeTimer, &timer, FakeFrameOps, &ops);

    try std.testing.expectEqual(@as(usize, 2), timer.calls);
    try std.testing.expectEqual(first_log_marker, fixture.app.last_timer_error_log_ns);
}

test "ordinary clock failure installs relative recovery when ready and disarmed" {
    var fixture: PacingFixture = undefined;
    try fixture.init(1, 20);
    defer fixture.deinit();
    fixture.app.frame_schedule = try FrameSchedule.begin(100, 20);
    var clock = FakeClock{ .failure = error.ClockGetTimeFailed };
    var timer = FakeTimer{};
    var ops = FakeFrameOps{ .ready = true };

    App.TestAdapter.serviceFrameSchedule(&fixture.app, FakeClock, &clock, FakeTimer, &timer, FakeFrameOps, &ops);

    try std.testing.expectEqual(@as(usize, 1), timer.calls);
    try std.testing.expect(!timer.last_flags.?.ABSTIME);
    try std.testing.expectEqual(@as(i64, 20), timer.last_spec.?.it_value.nsec);
    try std.testing.expectEqual(@as(i64, 0), timer.last_spec.?.it_interval.nsec);
    try std.testing.expectEqual(App.TestAdapter.TimerMode.relative_recovery, App.TestAdapter.timerMode(&fixture.app));
    try std.testing.expectEqual(@as(f64, 0), fixture.app.animation.phase);
}

test "ordinary clock failure preserves a trusted installed timer" {
    var fixture: PacingFixture = undefined;
    try fixture.init(1, 20);
    defer fixture.deinit();
    fixture.app.frame_schedule = try FrameSchedule.begin(100, 20);
    App.TestAdapter.seedFrameTimerAbsolute(&fixture.app, 120);
    var clock = FakeClock{ .failure = error.ClockGetTimeFailed };
    var timer = FakeTimer{};
    var ops = FakeFrameOps{ .ready = true };

    App.TestAdapter.serviceFrameSchedule(&fixture.app, FakeClock, &clock, FakeTimer, &timer, FakeFrameOps, &ops);

    try std.testing.expectEqual(@as(usize, 0), timer.calls);
    try std.testing.expectEqual(@as(?u64, 120), App.TestAdapter.timerDeadline(&fixture.app));
    try std.testing.expect(!fixture.app.timer_recovery_pending);
}

test "failed relative recovery clamps poll timeout to 100ms" {
    var fixture: PacingFixture = undefined;
    try fixture.init(1, 20);
    defer fixture.deinit();
    var clock = FakeClock{ .failure = error.ClockGetTimeFailed };
    var timer = FakeTimer{ .fail = true };
    var ops = FakeFrameOps{ .ready = true };

    App.TestAdapter.serviceFrameSchedule(&fixture.app, FakeClock, &clock, FakeTimer, &timer, FakeFrameOps, &ops);

    try std.testing.expect(fixture.app.timer_recovery_pending);
    try std.testing.expectEqual(@as(i32, 100), App.TestAdapter.pollTimeoutAt(&fixture.app, 0));
}

test "failed absolute arm while ready enters bounded recovery" {
    var fixture: PacingFixture = undefined;
    try fixture.init(1, 20);
    defer fixture.deinit();
    fixture.app.frame_schedule = try FrameSchedule.begin(100, 20);
    var clock = FakeClock{ .value = 110 };
    var timer = FakeTimer{ .fail = true };
    var ops = FakeFrameOps{ .ready = true };

    App.TestAdapter.serviceFrameSchedule(&fixture.app, FakeClock, &clock, FakeTimer, &timer, FakeFrameOps, &ops);

    try std.testing.expectEqual(@as(?u64, 120), fixture.app.frame_schedule.next_logical_deadline_ns);
    try std.testing.expectEqual(App.TestAdapter.TimerMode.disarmed, App.TestAdapter.timerMode(&fixture.app));
    try std.testing.expect(fixture.app.timer_recovery_pending);
    try std.testing.expect(App.TestAdapter.pollTimeoutAt(&fixture.app, 110) <= 100);
}

test "failed disarm preserves the prior trusted timer belief" {
    var fixture: PacingFixture = undefined;
    try fixture.init(1, 20);
    defer fixture.deinit();
    fixture.app.frame_schedule = try FrameSchedule.begin(100, 20);
    App.TestAdapter.seedFrameTimerAbsolute(&fixture.app, 120);
    var timer = FakeTimer{ .fail = true };
    var ops = FakeFrameOps{ .ready = false };

    try std.testing.expectError(error.TimerFdSetTimeFailed, service(&fixture, 130, &timer, &ops));

    try std.testing.expectEqual(@as(?u64, 120), App.TestAdapter.timerDeadline(&fixture.app));
    try std.testing.expectEqual(@as(?u64, 120), fixture.app.frame_schedule.next_logical_deadline_ns);
}

test "successful absolute arm clears recovery pending" {
    var fixture: PacingFixture = undefined;
    try fixture.init(1, 20);
    defer fixture.deinit();
    fixture.app.frame_schedule = try FrameSchedule.begin(100, 20);
    fixture.app.timer_recovery_pending = true;
    var timer = FakeTimer{};
    var ops = FakeFrameOps{ .ready = true };

    try service(&fixture, 110, &timer, &ops);

    try std.testing.expect(!fixture.app.timer_recovery_pending);
    try std.testing.expectEqual(@as(?u64, 120), App.TestAdapter.timerDeadline(&fixture.app));
}

test "set-fps clock failure preserves interval schedule and kernel belief" {
    var fixture: PacingFixture = undefined;
    try fixture.init(1, 20);
    defer fixture.deinit();
    fixture.app.frame_schedule = try FrameSchedule.begin(100, 20);
    App.TestAdapter.seedFrameTimerAbsolute(&fixture.app, 120);
    var clock = FakeClock{ .failure = error.ClockGetTimeFailed };
    var timer = FakeTimer{};

    try std.testing.expectError(error.ClockGetTimeFailed, App.TestAdapter.applyFrameInterval(
        &fixture.app,
        10,
        FakeClock,
        &clock,
        FakeTimer,
        &timer,
    ));

    try std.testing.expectEqual(@as(usize, 0), timer.calls);
    try std.testing.expectEqual(@as(u32, 20), fixture.app.frame_interval_ns);
    try std.testing.expectEqual(@as(?u64, 120), fixture.app.frame_schedule.next_logical_deadline_ns);
    try std.testing.expectEqual(@as(?u64, 120), App.TestAdapter.timerDeadline(&fixture.app));
}
