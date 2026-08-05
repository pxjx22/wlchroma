const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const wayland = @import("wayland_test");
const App = wayland.app.App;
const AppConfig = wayland.config.AppConfig;
const Effect = wayland.effect.Effect;
const LoadResult = wayland.config.LoadResult;
const NamedPalette = wayland.config.NamedPalette;
const Rgb = wayland.defaults.Rgb;
const reload_job = wayland.reload_job;
const SurfaceState = wayland.surface_state.SurfaceState;

const IpcConnection = switch (@typeInfo(@FieldType(App, "ipc_client"))) {
    .optional => |optional| optional.child,
    else => @compileError("App.ipc_client must remain optional"),
};

const service_now_ns: u64 = 10 * std.time.ns_per_ms;

const old_colors: [3]Rgb = .{
    .{ .r = 0x11, .g = 0x22, .b = 0x33 },
    .{ .r = 0x44, .g = 0x55, .b = 0x66 },
    .{ .r = 0x77, .g = 0x88, .b = 0x99 },
};

const new_colors: [3]Rgb = .{
    .{ .r = 0xaa, .g = 0xbb, .b = 0xcc },
    .{ .r = 0xdd, .g = 0xee, .b = 0xff },
    .{ .r = 0x01, .g = 0x02, .b = 0x03 },
};

const FakeTimer = struct {
    calls: usize = 0,
    last_fd: ?std.posix.fd_t = null,
    last_flags: ?linux.TFD.TIMER = null,
    last_interval: ?std.os.linux.itimerspec = null,
    fail: bool = false,

    pub fn set(
        self: *@This(),
        fd: std.posix.fd_t,
        flags: linux.TFD.TIMER,
        value: *const std.os.linux.itimerspec,
    ) !void {
        self.calls += 1;
        self.last_fd = fd;
        self.last_flags = flags;
        self.last_interval = value.*;
        if (self.fail) return error.TimerFdSetTimeFailed;
    }
};

fn appConfig() AppConfig {
    return .{
        .fps = 15,
        .frame_interval_ns = 66_666_667,
        .effect_type = .colormix,
        .palette = old_colors,
        .speed = 1.25,
        .renderer_scale = 0.5,
        .upscale_filter = .nearest,
    };
}

fn namedPalette(name: []const u8, colors: [3]Rgb) NamedPalette {
    var palette = NamedPalette{
        .name = std.mem.zeroes([64:0]u8),
        .name_len = name.len,
        .colors = colors,
    };
    @memcpy(palette.name[0..name.len], name);
    return palette;
}

fn reloadFixture(allocator: std.mem.Allocator, surface: *SurfaceState) !App {
    const cfg = appConfig();
    const palettes = try allocator.alloc(NamedPalette, 1);
    palettes[0] = namedPalette("old", old_colors);

    var app: App = undefined;
    app.allocator = allocator;
    app.surfaces = .empty;
    try app.surfaces.append(allocator, surface);
    app.configured_effect_type = cfg.effect_type;
    app.effect = Effect.init(&cfg);
    app.animation = wayland.animation_state.AnimationState.init(cfg.speed);
    app.egl_ctx = null;
    app.effect_shader = null;
    app.gpu_upload_state = .{};
    app.blit_shader = null;
    app.timer_armed = true;
    app.frame_interval_ns = cfg.frame_interval_ns;
    app.renderer_scale = cfg.renderer_scale;
    app.upscale_filter = cfg.upscale_filter;
    app.tfd = 42;
    app.palettes = palettes;
    app.active_palette_name_buf = std.mem.zeroes([64]u8);
    @memcpy(app.active_palette_name_buf[0..3], "old");
    app.active_palette_name_len = 3;
    app.current_palette = old_colors;
    app.fade = .{
        .start = old_colors,
        .target = new_colors,
        .start_ns = 100,
        .dur_ns = 200,
    };
    return app;
}

fn reloadCandidate(allocator: std.mem.Allocator) !LoadResult {
    const palettes = try allocator.alloc(NamedPalette, 1);
    palettes[0] = namedPalette("new", new_colors);
    return .{
        .config = .{
            .fps = 30,
            .frame_interval_ns = 33_333_333,
            .effect_type = .colormix,
            .palette = new_colors,
            .speed = 2.0,
            .renderer_scale = 0.75,
            .upscale_filter = .linear,
        },
        .palettes = palettes,
    };
}

fn runtimeReloadCandidate(allocator: std.mem.Allocator) !LoadResult {
    const palettes = try allocator.alloc(NamedPalette, 1);
    palettes[0] = namedPalette("new", new_colors);
    return .{
        .config = .{
            .fps = 25,
            .frame_interval_ns = 40_000_000,
            .effect_type = .glass_drift,
            .palette = new_colors,
            .speed = 2.0,
            .renderer_scale = 0.75,
            .upscale_filter = .linear,
        },
        .palettes = palettes,
    };
}

fn createTimerFd() !std.posix.fd_t {
    const rc = std.os.linux.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true });
    if (std.os.linux.errno(rc) != .SUCCESS) return error.TimerFdCreateFailed;
    return @intCast(rc);
}

fn socketPair() ![2]posix.fd_t {
    var fds: [2]posix.fd_t = undefined;
    const rc = linux.socketpair(
        posix.AF.UNIX,
        posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
        0,
        &fds,
    );
    if (linux.errno(rc) != .SUCCESS) return error.TestSocketPairFailed;
    return fds;
}

fn closeFd(fd: posix.fd_t) void {
    if (fd >= 0) _ = linux.close(fd);
}

fn sendExact(fd: posix.fd_t, bytes: []const u8) !void {
    const written = linux.write(fd, bytes.ptr, bytes.len);
    if (linux.errno(written) != .SUCCESS) return error.TestSendFailed;
    try std.testing.expectEqual(bytes.len, written);
}

const FakeReloadOps = struct {
    thread_starts: usize = 0,
    loads: usize = 0,
    monotonic_calls: usize = 0,
    gate: u32 align(4) = 0,
    eventfd_create_error: ?anyerror = null,
    thread_start_error: ?anyerror = null,
    load_error: ?anyerror = null,
    eventfd_read_error: ?anyerror = null,
    eventfd_write_error: ?anyerror = null,
    monotonic_error: ?anyerror = null,
    monotonic_now_ns: u64 = service_now_ns,
    use_candidate: bool = false,

    fn release(self: *@This()) void {
        @atomicStore(u32, &self.gate, 1, .release);
        std.Io.futexWake(std.testing.io, u32, &self.gate, 1);
    }

    fn load(
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        _: wayland.config.ResolvedConfigPath,
    ) !LoadResult {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        while (@atomicLoad(u32, &self.gate, .acquire) == 0) {
            std.Io.futexWaitUncancelable(io, u32, &self.gate, 0);
        }
        self.loads += 1;
        if (self.load_error) |err| return err;
        if (self.use_candidate) return runtimeReloadCandidate(allocator);
        return .{
            .config = wayland.config.defaultConfig(),
            .palettes = try allocator.alloc(NamedPalette, 0),
        };
    }

    fn eventfdCreate(context: ?*anyopaque) !posix.fd_t {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (self.eventfd_create_error) |err| return err;
        return reload_job.production_ops.eventfd_create(null);
    }

    fn eventfdRead(context: ?*anyopaque, fd: posix.fd_t) !u64 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (self.eventfd_read_error) |err| return err;
        return reload_job.production_ops.eventfd_read(null, fd);
    }

    fn eventfdWrite(context: ?*anyopaque, fd: posix.fd_t, value: u64) !void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (self.eventfd_write_error) |err| return err;
        return reload_job.production_ops.eventfd_write(null, fd, value);
    }

    fn threadStart(context: ?*anyopaque, job: *reload_job.ReloadJob) !std.Thread {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.thread_starts += 1;
        if (self.thread_start_error) |err| return err;
        return reload_job.production_ops.thread_start(null, job);
    }

    fn monotonicNs(context: ?*anyopaque) !u64 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.monotonic_calls += 1;
        if (self.monotonic_error) |err| return err;
        return self.monotonic_now_ns;
    }

    fn table(self: *@This()) reload_job.ReloadOps {
        var ops = reload_job.production_ops;
        ops.context = self;
        ops.load = load;
        ops.eventfd_create = eventfdCreate;
        ops.eventfd_read = eventfdRead;
        ops.eventfd_write = eventfdWrite;
        ops.thread_start = threadStart;
        ops.monotonic_ns = monotonicNs;
        return ops;
    }
};

const AppReloadFixture = struct {
    allocator: std.mem.Allocator,
    app: App,
    ops_state: *FakeReloadOps,
    peer_fd: posix.fd_t,

    fn init(allocator: std.mem.Allocator) !@This() {
        const ops_state = try allocator.create(FakeReloadOps);
        errdefer allocator.destroy(ops_state);
        ops_state.* = .{};

        const palettes = try allocator.alloc(NamedPalette, 1);
        errdefer allocator.free(palettes);
        palettes[0] = namedPalette("old", old_colors);

        const fds = try socketPair();
        errdefer closeFd(fds[0]);
        errdefer closeFd(fds[1]);

        const cfg = appConfig();
        var app: App = undefined;
        app.allocator = allocator;
        app.io = std.testing.io;
        app.environ = .empty;
        app.outputs = .empty;
        app.surfaces = .empty;
        app.detached_gpu = .empty;
        app.configured_effect_type = cfg.effect_type;
        app.effect = Effect.init(&cfg);
        app.animation = wayland.animation_state.AnimationState.init(cfg.speed);
        app.animation.phase = 7.5;
        app.egl_ctx = null;
        app.effect_shader = null;
        app.gpu_upload_state = .{ .dirty = .{ .palette = true } };
        app.blit_shader = null;
        app.gpu_pipeline_failed = false;
        app.gpu_fallback_applied = false;
        app.timer_armed = false;
        app.running = true;
        app.frame_interval_ns = cfg.frame_interval_ns;
        app.renderer_scale = cfg.renderer_scale;
        app.upscale_filter = cfg.upscale_filter;
        app.tfd = -1;
        app.sig_fd = -1;
        app.ipc_server = null;
        app.ipc_client = IpcConnection.init(fds[0], 0);
        app.config_path = "/tmp/wlchroma-app-reload-test.toml";
        app.palettes = palettes;
        app.active_palette_name_buf = std.mem.zeroes([64]u8);
        @memcpy(app.active_palette_name_buf[0..3], "old");
        app.active_palette_name_len = 3;
        app.current_palette = old_colors;
        app.fade = .{
            .start = old_colors,
            .target = new_colors,
            .start_ns = 100,
            .dur_ns = 200,
        };
        app.reload_job = null;
        app.reload_ops = ops_state.table();
        app.shutdown_pending = false;

        return .{
            .allocator = allocator,
            .app = app,
            .ops_state = ops_state,
            .peer_fd = fds[1],
        };
    }

    fn deinit(self: *@This()) void {
        self.ops_state.release();
        closeFd(self.peer_fd);
        self.peer_fd = -1;
        if (self.app.ipc_client) |*client| _ = client.close();
        self.app.ipc_client = null;
        if (self.app.reload_job) |job| {
            job.orphanClient();
            job.deinit();
            self.app.reload_job = null;
        }
        self.allocator.free(self.app.palettes);
        self.allocator.destroy(self.ops_state);
    }

    fn acceptReload(self: *@This()) !void {
        try self.acceptReloadWith(linux.POLL.IN);
    }

    fn acceptReloadWith(self: *@This(), revents: i16) !void {
        try sendExact(self.peer_fd, "reload\n");
        App.TestAdapter.serviceIpc(&self.app, revents, service_now_ns);
    }

    fn issueSecondReload(self: *@This()) !void {
        closeFd(self.peer_fd);
        const fds = try socketPair();
        self.app.ipc_client = IpcConnection.init(fds[0], service_now_ns);
        self.peer_fd = fds[1];
        try sendExact(self.peer_fd, "reload\n");
        App.TestAdapter.serviceIpc(&self.app, linux.POLL.IN, service_now_ns);
    }

    fn expectNormalResponse(self: *@This(), expected: []const u8) !void {
        const client = &self.app.ipc_client.?;
        try std.testing.expectEqual(.writing, client.state);
        try std.testing.expectEqualStrings(expected, client.response.bytes[0..client.response.len]);
    }

    fn installNormalClient(self: *@This(), now_ns: u64) !void {
        if (self.app.ipc_client) |*client| _ = client.close();
        self.app.ipc_client = null;
        closeFd(self.peer_fd);
        const fds = try socketPair();
        self.app.ipc_client = IpcConnection.init(fds[0], now_ns);
        self.peer_fd = fds[1];
    }

    fn completeReload(self: *@This()) void {
        self.ops_state.release();
        self.app.reload_job.?.joinOnce();
        App.TestAdapter.serviceReloadReady(&self.app);
    }

    fn expectReloadError(self: *@This()) !void {
        const client = &self.app.reload_job.?.client.?;
        try std.testing.expectEqual(.writing, client.state);
        try std.testing.expect(std.mem.startsWith(
            u8,
            client.response.bytes[0..client.response.len],
            "error: ",
        ));
    }

    fn issueNormalCommand(self: *@This(), command: []const u8, now_ns: u64) !void {
        try self.installNormalClient(now_ns);
        try sendExact(self.peer_fd, command);
        App.TestAdapter.serviceIpc(&self.app, linux.POLL.IN, now_ns);
    }
};

test "accepted reload transfers the whole connection and defers response" {
    var fixture = try AppReloadFixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.acceptReload();

    try std.testing.expect(fixture.app.ipc_client == null);
    try std.testing.expect(fixture.app.reload_job != null);
    try std.testing.expect(fixture.app.reload_job.?.client != null);
    try std.testing.expectEqual(reload_job.Phase.loading, fixture.app.reload_job.?.phase);
    try std.testing.expectEqual(.reading, fixture.app.reload_job.?.client.?.state);
    try std.testing.expectEqual(@as(usize, 0), fixture.app.reload_job.?.client.?.response.len);
}

test "second reload reports busy without starting another worker" {
    var fixture = try AppReloadFixture.init(std.testing.allocator);
    defer fixture.deinit();
    try fixture.acceptReload();
    const starts_before = fixture.ops_state.thread_starts;

    try fixture.issueSecondReload();

    try std.testing.expectEqual(starts_before, fixture.ops_state.thread_starts);
    try fixture.expectNormalResponse("error: reload already in progress\n");
}

test "eventfd start failure retains the normal client with a bounded error" {
    var fixture = try AppReloadFixture.init(std.testing.allocator);
    defer fixture.deinit();
    fixture.ops_state.eventfd_create_error = error.TestEventfdCreateFailed;

    try fixture.acceptReload();

    try std.testing.expect(fixture.app.reload_job == null);
    try fixture.expectNormalResponse("error: reload start failed: error.TestEventfdCreateFailed\n");
    try std.testing.expectEqual(
        service_now_ns + 500 * std.time.ns_per_ms,
        fixture.app.ipc_client.?.response_deadline_ns,
    );
}

test "thread start failure retains the normal client with a bounded error" {
    var fixture = try AppReloadFixture.init(std.testing.allocator);
    defer fixture.deinit();
    fixture.ops_state.thread_start_error = error.TestThreadStartFailed;

    try fixture.acceptReload();

    try std.testing.expect(fixture.app.reload_job == null);
    try std.testing.expectEqual(@as(usize, 1), fixture.ops_state.thread_starts);
    try fixture.expectNormalResponse("error: reload start failed: error.TestThreadStartFailed\n");
}

test "poll timeout is the minimum of normal and reload response deadlines" {
    var fixture = try AppReloadFixture.init(std.testing.allocator);
    defer fixture.deinit();
    fixture.ops_state.use_candidate = true;
    fixture.ops_state.monotonic_now_ns = 100 * std.time.ns_per_ms;
    try fixture.acceptReload();
    fixture.completeReload();
    try fixture.installNormalClient(0);

    fixture.app.ipc_client.?.response.appendLine("normal");
    fixture.app.ipc_client.?.beginWriting(0, false);
    fixture.app.ipc_client.?.response_deadline_ns = 450 * std.time.ns_per_ms;
    fixture.app.reload_job.?.client.?.response_deadline_ns = 700 * std.time.ns_per_ms;

    try std.testing.expectEqual(
        @as(i32, 350),
        App.TestAdapter.pollTimeoutAt(&fixture.app, 100 * std.time.ns_per_ms),
    );
}

test "loading reload caps an otherwise infinite poll at 500 milliseconds" {
    var fixture = try AppReloadFixture.init(std.testing.allocator);
    defer fixture.deinit();
    try fixture.acceptReload();

    try std.testing.expectEqual(
        @as(i32, 500),
        App.TestAdapter.pollTimeoutAt(&fixture.app, service_now_ns),
    );
}

test "normal and reload clients expire independently" {
    var fixture = try AppReloadFixture.init(std.testing.allocator);
    defer fixture.deinit();
    fixture.ops_state.use_candidate = true;
    try fixture.acceptReload();
    fixture.completeReload();
    try fixture.installNormalClient(0);

    fixture.app.ipc_client.?.response.appendLine("normal");
    fixture.app.ipc_client.?.beginWriting(0, false);
    fixture.app.ipc_client.?.response_deadline_ns = 100 * std.time.ns_per_ms;
    fixture.app.reload_job.?.client.?.response_deadline_ns = 200 * std.time.ns_per_ms;

    try std.testing.expectEqual(
        @as(i32, 100),
        App.TestAdapter.pollTimeoutAt(&fixture.app, 100 * std.time.ns_per_ms),
    );
    try std.testing.expect(fixture.app.ipc_client == null);
    try std.testing.expect(fixture.app.reload_job != null);
    try std.testing.expect(fixture.app.reload_job.?.client != null);

    try std.testing.expectEqual(
        @as(i32, -1),
        App.TestAdapter.pollTimeoutAt(&fixture.app, 200 * std.time.ns_per_ms),
    );
    try std.testing.expect(fixture.app.reload_job == null);
}

test "stale reload client terminal event cannot orphan its replacement" {
    var fixture = try AppReloadFixture.init(std.testing.allocator);
    defer fixture.deinit();
    fixture.ops_state.use_candidate = true;
    try fixture.acceptReload();
    fixture.completeReload();

    const expired_fd = fixture.app.reload_job.?.client.?.fd;
    fixture.app.reload_job.?.client.?.response_deadline_ns = 100 * std.time.ns_per_ms;
    try fixture.installNormalClient(0);
    try std.testing.expectEqual(
        @as(i32, 400),
        App.TestAdapter.pollTimeoutAt(&fixture.app, 100 * std.time.ns_per_ms),
    );
    try std.testing.expect(fixture.app.reload_job == null);

    try fixture.acceptReload();
    const replacement_fd = fixture.app.reload_job.?.client.?.fd;
    try std.testing.expect(replacement_fd != expired_fd);

    App.TestAdapter.serviceReloadClient(
        &fixture.app,
        expired_fd,
        linux.POLL.HUP | linux.POLL.ERR,
    );

    try std.testing.expectEqual(reload_job.Phase.loading, fixture.app.reload_job.?.phase);
    try std.testing.expect(fixture.app.reload_job.?.client != null);
    try std.testing.expectEqual(replacement_fd, fixture.app.reload_job.?.client.?.fd);
}

test "reload response expiry between aggregate check and write prevents flush" {
    var fixture = try AppReloadFixture.init(std.testing.allocator);
    defer fixture.deinit();
    fixture.ops_state.use_candidate = true;
    fixture.ops_state.monotonic_now_ns = 100 * std.time.ns_per_ms;
    try fixture.acceptReload();
    fixture.completeReload();

    const response_fd = fixture.app.reload_job.?.client.?.fd;
    fixture.app.reload_job.?.client.?.response_deadline_ns = 600 * std.time.ns_per_ms;
    try std.testing.expectEqual(
        @as(i32, 1),
        App.TestAdapter.pollTimeoutAt(&fixture.app, 599 * std.time.ns_per_ms),
    );
    const clock_calls_before_service = fixture.ops_state.monotonic_calls;
    fixture.ops_state.monotonic_now_ns = 601 * std.time.ns_per_ms;

    App.TestAdapter.serviceReloadClient(&fixture.app, response_fd, linux.POLL.OUT);

    try std.testing.expectEqual(
        clock_calls_before_service + 1,
        fixture.ops_state.monotonic_calls,
    );
    try std.testing.expect(fixture.app.reload_job == null);
    var buf: [16]u8 = undefined;
    const bytes_read = linux.read(fixture.peer_fd, &buf, buf.len);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(bytes_read));
    try std.testing.expectEqual(@as(usize, 0), bytes_read);
}

test "reload response service clock failure closes without flushing" {
    var fixture = try AppReloadFixture.init(std.testing.allocator);
    defer fixture.deinit();
    fixture.ops_state.use_candidate = true;
    try fixture.acceptReload();
    fixture.completeReload();

    const response_fd = fixture.app.reload_job.?.client.?.fd;
    const clock_calls_before_service = fixture.ops_state.monotonic_calls;
    fixture.ops_state.monotonic_error = error.TestMonotonicFailed;
    App.TestAdapter.serviceReloadClient(&fixture.app, response_fd, linux.POLL.OUT);

    try std.testing.expectEqual(
        clock_calls_before_service + 1,
        fixture.ops_state.monotonic_calls,
    );
    try std.testing.expect(fixture.app.reload_job == null);
    var buf: [16]u8 = undefined;
    const bytes_read = linux.read(fixture.peer_fd, &buf, buf.len);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(bytes_read));
    try std.testing.expectEqual(@as(usize, 0), bytes_read);
}

test "notification write failure completes through fallback with zero outputs" {
    var fixture = try AppReloadFixture.init(std.testing.allocator);
    defer fixture.deinit();
    fixture.ops_state.use_candidate = true;
    fixture.ops_state.eventfd_write_error = error.TestNotifyWriteFailed;
    try fixture.acceptReload();

    fixture.completeReload();

    try fixture.expectReloadError();
    try std.testing.expectEqual(old_colors, fixture.app.current_palette);
    try std.testing.expectEqual(@as(u32, 66_666_667), fixture.app.frame_interval_ns);
}

test "permanent notification read fault rejects application" {
    var fixture = try AppReloadFixture.init(std.testing.allocator);
    defer fixture.deinit();
    fixture.ops_state.use_candidate = true;
    fixture.ops_state.eventfd_read_error = error.TestNotifyReadFailed;
    try fixture.acceptReload();

    fixture.completeReload();

    try fixture.expectReloadError();
    try std.testing.expect(fixture.app.reload_job.?.notification_fault);
    try std.testing.expectEqual(old_colors, fixture.app.current_palette);
}

test "notification WouldBlock never reads unpublished outcome" {
    var fixture = try AppReloadFixture.init(std.testing.allocator);
    defer fixture.deinit();
    fixture.ops_state.use_candidate = true;
    fixture.ops_state.eventfd_read_error = error.WouldBlock;
    try fixture.acceptReload();

    App.TestAdapter.serviceReloadReady(&fixture.app);

    try std.testing.expectEqual(reload_job.Phase.loading, fixture.app.reload_job.?.phase);
    try std.testing.expect(fixture.app.reload_job.?.thread != null);
    try std.testing.expect(fixture.app.reload_job.?.outcome == .pending);
    try std.testing.expectEqual(old_colors, fixture.app.current_palette);
    try std.testing.expectEqual(@as(usize, 0), fixture.app.reload_job.?.client.?.response.len);
}

test "completed reload applies once then starts a fresh response deadline" {
    var fixture = try AppReloadFixture.init(std.testing.allocator);
    defer fixture.deinit();
    fixture.ops_state.use_candidate = true;
    fixture.ops_state.monotonic_now_ns = 900 * std.time.ns_per_ms;
    try fixture.acceptReload();

    fixture.completeReload();

    try std.testing.expectEqual(@as(u32, 40_000_000), fixture.app.frame_interval_ns);
    try std.testing.expectEqual(wayland.config.EffectType.glass_drift, fixture.app.configured_effect_type);
    try std.testing.expectEqual(wayland.config.EffectType.glass_drift, std.meta.activeTag(fixture.app.effect));
    try std.testing.expectEqual(@as(f64, 0), fixture.app.animation.phase);
    try std.testing.expectEqual(@as(f32, 2.0), fixture.app.animation.speed);
    try std.testing.expectEqual(wayland.animation_state.Direction.forward, fixture.app.animation.direction);
    try std.testing.expectEqual(new_colors, fixture.app.current_palette);
    try std.testing.expectEqual(@as(f32, 0.75), fixture.app.renderer_scale);
    try std.testing.expectEqual(wayland.config.UpscaleFilter.linear, fixture.app.upscale_filter);
    try std.testing.expect(fixture.app.fade == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.app.active_palette_name_len);
    try std.testing.expectEqualStrings("new", fixture.app.palettes[0].nameSlice());
    try std.testing.expectEqual(reload_job.Phase.responding, fixture.app.reload_job.?.phase);
    try std.testing.expectEqual(.writing, fixture.app.reload_job.?.client.?.state);
    try std.testing.expectEqualStrings(
        "ok\n",
        fixture.app.reload_job.?.client.?.response.bytes[0..fixture.app.reload_job.?.client.?.response.len],
    );
    try std.testing.expectEqual(
        1_400 * std.time.ns_per_ms,
        fixture.app.reload_job.?.client.?.response_deadline_ns,
    );
    try std.testing.expectEqual(@as(usize, 1), fixture.ops_state.loads);

    const palettes_ptr = fixture.app.palettes.ptr;
    fixture.app.animation.phase = 12;
    App.TestAdapter.serviceReloadReady(&fixture.app);
    try std.testing.expectEqual(@as(f64, 12), fixture.app.animation.phase);
    try std.testing.expectEqual(palettes_ptr, fixture.app.palettes.ptr);
}

test "service joins a worker-owned handle before applying one ready reload" {
    var fixture = try AppReloadFixture.init(std.testing.allocator);
    defer fixture.deinit();
    fixture.ops_state.use_candidate = true;
    fixture.ops_state.monotonic_now_ns = 900 * std.time.ns_per_ms;
    try fixture.acceptReload();

    fixture.ops_state.release();
    while (!fixture.app.reload_job.?.readyAcquire()) {
        try std.Thread.yield();
    }

    try std.testing.expect(fixture.app.reload_job.?.thread != null);
    App.TestAdapter.serviceReloadReady(&fixture.app);

    try std.testing.expect(fixture.app.reload_job.?.thread == null);
    try std.testing.expect(fixture.app.reload_job.?.outcome == .pending);
    try std.testing.expectEqual(@as(usize, 1), fixture.ops_state.loads);
    try std.testing.expectEqual(wayland.config.EffectType.glass_drift, fixture.app.configured_effect_type);
    try std.testing.expectEqual(new_colors, fixture.app.current_palette);
    try std.testing.expectEqual(reload_job.Phase.responding, fixture.app.reload_job.?.phase);
    try std.testing.expectEqual(.writing, fixture.app.reload_job.?.client.?.state);
    try std.testing.expectEqual(
        1_400 * std.time.ns_per_ms,
        fixture.app.reload_job.?.client.?.response_deadline_ns,
    );

    const palettes_ptr = fixture.app.palettes.ptr;
    App.TestAdapter.serviceReloadReady(&fixture.app);
    try std.testing.expectEqual(@as(usize, 1), fixture.ops_state.loads);
    try std.testing.expectEqual(palettes_ptr, fixture.app.palettes.ptr);
}

test "client HUP while loading still applies then discards response" {
    var fixture = try AppReloadFixture.init(std.testing.allocator);
    defer fixture.deinit();
    fixture.ops_state.use_candidate = true;

    try fixture.acceptReloadWith(linux.POLL.IN | linux.POLL.HUP);

    try std.testing.expect(fixture.app.reload_job != null);
    try std.testing.expectEqual(reload_job.Phase.orphaned, fixture.app.reload_job.?.phase);
    try std.testing.expect(fixture.app.reload_job.?.client == null);
    fixture.completeReload();
    try std.testing.expect(fixture.app.reload_job == null);
    try std.testing.expectEqual(wayland.config.EffectType.glass_drift, fixture.app.configured_effect_type);
    try std.testing.expectEqual(new_colors, fixture.app.current_palette);
}

test "stop request readiness suppresses simultaneous reload completion" {
    var fixture = try AppReloadFixture.init(std.testing.allocator);
    defer fixture.deinit();
    fixture.ops_state.use_candidate = true;
    try fixture.acceptReload();
    fixture.ops_state.release();
    fixture.app.reload_job.?.joinOnce();

    try fixture.issueNormalCommand("stop\n", 50 * std.time.ns_per_ms);
    App.TestAdapter.serviceReloadReady(&fixture.app);

    try std.testing.expect(fixture.app.shutdown_pending);
    try std.testing.expect(fixture.app.ipc_client.?.shutdown_after_flush);
    try std.testing.expectEqual(.writing, fixture.app.ipc_client.?.state);
    try std.testing.expectEqual(old_colors, fixture.app.current_palette);
    try std.testing.expect(fixture.app.reload_job != null);
    try std.testing.expect(fixture.app.reload_job.?.outcome == .loaded);
}

test "pending stop response suppresses simultaneous reload completion" {
    var fixture = try AppReloadFixture.init(std.testing.allocator);
    defer fixture.deinit();
    fixture.ops_state.use_candidate = true;
    try fixture.acceptReload();
    try fixture.issueNormalCommand("stop\n", 50 * std.time.ns_per_ms);
    try std.testing.expect(fixture.app.shutdown_pending);

    fixture.ops_state.release();
    fixture.app.reload_job.?.joinOnce();
    App.TestAdapter.serviceReloadReady(&fixture.app);

    try std.testing.expectEqual(old_colors, fixture.app.current_palette);
    try std.testing.expect(fixture.app.reload_job != null);
    try std.testing.expect(fixture.app.reload_job.?.outcome == .loaded);
}

test "shutdown joins worker and frees an unconsumed result exactly once" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var fixture_deinited = false;
    var fixture = try AppReloadFixture.init(failing.allocator());
    errdefer if (!fixture_deinited) fixture.deinit();
    fixture.ops_state.use_candidate = true;
    try fixture.acceptReload();

    fixture.deinit();
    fixture_deinited = true;

    try std.testing.expectEqual(failing.allocations, failing.deallocations);
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "reload-only timer fault leaves set-fps on the production timer path" {
    if (!App.TestAdapter.forceReloadTimerFailure()) return error.SkipZigTest;

    const tfd = try createTimerFd();
    defer closeFd(tfd);
    var fixture = try AppReloadFixture.init(std.testing.allocator);
    defer fixture.deinit();
    fixture.app.tfd = tfd;
    fixture.app.timer_armed = true;
    fixture.ops_state.use_candidate = true;
    try fixture.acceptReload();

    fixture.completeReload();

    try fixture.expectReloadError();
    try std.testing.expectEqual(@as(u32, 66_666_667), fixture.app.frame_interval_ns);
    try std.testing.expectEqual(old_colors, fixture.app.current_palette);

    try fixture.issueNormalCommand("set-fps 20\n", 50 * std.time.ns_per_ms);
    try fixture.expectNormalResponse("ok\n");
    try std.testing.expectEqual(@as(u32, 50_000_000), fixture.app.frame_interval_ns);
}

test "reload response clock failure closes only its completed job" {
    var fixture = try AppReloadFixture.init(std.testing.allocator);
    defer fixture.deinit();
    fixture.ops_state.use_candidate = true;
    fixture.ops_state.monotonic_error = error.TestMonotonicFailed;
    try fixture.acceptReload();

    fixture.completeReload();

    try std.testing.expect(fixture.app.reload_job == null);
    try std.testing.expectEqual(wayland.config.EffectType.glass_drift, fixture.app.configured_effect_type);
    try std.testing.expectEqual(new_colors, fixture.app.current_palette);
    try std.testing.expect(fixture.app.running);
}

test "armed frame interval commits only after timer success" {
    var app: App = undefined;
    app.timer_armed = true;
    app.tfd = 42;
    app.frame_interval_ns = 66_666_667;
    var timer = FakeTimer{};

    try App.TestAdapter.applyFrameInterval(&app, 33_333_333, FakeTimer, &timer);

    try std.testing.expectEqual(@as(usize, 1), timer.calls);
    try std.testing.expectEqual(@as(std.posix.fd_t, 42), timer.last_fd.?);
    try std.testing.expectEqual(false, timer.last_flags.?.ABSTIME);
    try std.testing.expectEqual(@as(i64, 0), timer.last_interval.?.it_value.sec);
    try std.testing.expectEqual(@as(i64, 33_333_333), timer.last_interval.?.it_value.nsec);
    try std.testing.expectEqual(@as(i64, 0), timer.last_interval.?.it_interval.sec);
    try std.testing.expectEqual(@as(i64, 33_333_333), timer.last_interval.?.it_interval.nsec);
    try std.testing.expectEqual(@as(u32, 33_333_333), app.frame_interval_ns);
}

test "armed one fps interval normalizes to a valid timespec" {
    var app: App = undefined;
    app.timer_armed = true;
    app.tfd = 42;
    app.frame_interval_ns = 66_666_667;
    var timer = FakeTimer{};

    try App.TestAdapter.applyFrameInterval(&app, 1_000_000_000, FakeTimer, &timer);

    try std.testing.expectEqual(@as(usize, 1), timer.calls);
    try std.testing.expectEqual(@as(i64, 1), timer.last_interval.?.it_value.sec);
    try std.testing.expectEqual(@as(i64, 0), timer.last_interval.?.it_value.nsec);
    try std.testing.expectEqual(@as(i64, 1), timer.last_interval.?.it_interval.sec);
    try std.testing.expectEqual(@as(i64, 0), timer.last_interval.?.it_interval.nsec);
    try std.testing.expectEqual(@as(u32, 1_000_000_000), app.frame_interval_ns);
}

test "armed frame interval failure preserves stored interval" {
    var app: App = undefined;
    app.timer_armed = true;
    app.tfd = 42;
    app.frame_interval_ns = 66_666_667;
    var timer = FakeTimer{ .fail = true };

    try std.testing.expectError(
        error.TimerFdSetTimeFailed,
        App.TestAdapter.applyFrameInterval(&app, 33_333_333, FakeTimer, &timer),
    );

    try std.testing.expectEqual(@as(usize, 1), timer.calls);
    try std.testing.expectEqual(@as(u32, 66_666_667), app.frame_interval_ns);
}

test "disarmed frame interval updates storage without timer syscall" {
    var app: App = undefined;
    app.timer_armed = false;
    app.tfd = 42;
    app.frame_interval_ns = 66_666_667;
    var timer = FakeTimer{ .fail = true };

    try App.TestAdapter.applyFrameInterval(&app, 33_333_333, FakeTimer, &timer);

    try std.testing.expectEqual(@as(usize, 0), timer.calls);
    try std.testing.expectEqual(@as(u32, 33_333_333), app.frame_interval_ns);
}

test "disarmed one fps interval arms successfully when an output appears" {
    const allocator = std.testing.allocator;
    const tfd = try createTimerFd();
    defer _ = std.os.linux.close(tfd);

    var surface: SurfaceState = undefined;
    var app: App = undefined;
    app.surfaces = .empty;
    defer app.surfaces.deinit(allocator);
    try app.surfaces.append(allocator, &surface);
    app.timer_armed = false;
    app.tfd = tfd;
    app.frame_interval_ns = 66_666_667;
    var timer = FakeTimer{ .fail = true };

    try App.TestAdapter.applyFrameInterval(&app, 1_000_000_000, FakeTimer, &timer);
    try std.testing.expectEqual(@as(usize, 0), timer.calls);
    try std.testing.expectEqual(@as(u32, 1_000_000_000), app.frame_interval_ns);

    App.TestAdapter.updateFrameTimer(&app);

    try std.testing.expect(app.timer_armed);
}

test "timer failure frees candidate and preserves every App field" {
    const allocator = std.testing.allocator;
    var surface: SurfaceState = undefined;
    surface.renderer_scale = 0.5;
    surface.upscale_filter = .nearest;
    var app = try reloadFixture(allocator, &surface);
    defer app.surfaces.deinit(allocator);
    defer allocator.free(app.palettes);
    app.animation.phase = 7.5;
    var candidate = try runtimeReloadCandidate(allocator);
    var timer = FakeTimer{ .fail = true };

    const interval_before = app.frame_interval_ns;
    const scale_before = app.renderer_scale;
    const filter_before = app.upscale_filter;
    const configured_effect_before = app.configured_effect_type;
    const running_effect_before = std.meta.activeTag(app.effect);
    const effect_palette_before = app.effect.paletteData().?.*;
    const effect_before = app.effect;
    const animation_before = app.animation;
    const upload_before = app.gpu_upload_state;
    const palette_before = app.current_palette;
    const fade_before = app.fade;
    const palettes_ptr_before = app.palettes.ptr;
    const palettes_before = app.palettes[0];
    const active_name_before = app.active_palette_name_buf;
    const active_name_len_before = app.active_palette_name_len;

    try std.testing.expectError(
        error.TimerFdSetTimeFailed,
        App.TestAdapter.applyReloadSnapshot(&app, &candidate, FakeTimer, &timer),
    );

    try std.testing.expectEqual(@as(usize, 1), timer.calls);
    try std.testing.expectEqual(interval_before, app.frame_interval_ns);
    try std.testing.expectEqual(scale_before, app.renderer_scale);
    try std.testing.expectEqual(filter_before, app.upscale_filter);
    try std.testing.expectEqual(@as(f32, 0.5), surface.renderer_scale);
    try std.testing.expectEqual(wayland.config.UpscaleFilter.nearest, surface.upscale_filter);
    try std.testing.expectEqual(configured_effect_before, app.configured_effect_type);
    try std.testing.expectEqual(running_effect_before, std.meta.activeTag(app.effect));
    try std.testing.expectEqual(effect_palette_before, app.effect.paletteData().?.*);
    try std.testing.expect(std.meta.eql(effect_before, app.effect));
    try std.testing.expectEqualDeep(animation_before, app.animation);
    try std.testing.expectEqualDeep(upload_before, app.gpu_upload_state);
    try std.testing.expectEqual(palette_before, app.current_palette);
    try std.testing.expectEqualDeep(fade_before, app.fade);
    try std.testing.expectEqual(palettes_ptr_before, app.palettes.ptr);
    try std.testing.expectEqualDeep(palettes_before, app.palettes[0]);
    try std.testing.expectEqualSlices(u8, &active_name_before, &app.active_palette_name_buf);
    try std.testing.expectEqual(active_name_len_before, app.active_palette_name_len);
}

test "reload success transfers candidate palettes exactly once" {
    const allocator = std.testing.allocator;
    var surface: SurfaceState = undefined;
    surface.renderer_scale = 0.5;
    surface.upscale_filter = .nearest;
    var app = try reloadFixture(allocator, &surface);
    defer app.surfaces.deinit(allocator);
    var candidate = try reloadCandidate(allocator);
    const candidate_palettes_ptr = candidate.palettes.ptr;
    var timer = FakeTimer{};

    try App.TestAdapter.applyReloadSnapshot(&app, &candidate, FakeTimer, &timer);
    defer allocator.free(app.palettes);

    try std.testing.expectEqual(@as(usize, 1), timer.calls);
    try std.testing.expectEqual(@as(u32, 33_333_333), app.frame_interval_ns);
    try std.testing.expectEqual(@as(f32, 0.75), app.renderer_scale);
    try std.testing.expectEqual(wayland.config.UpscaleFilter.linear, app.upscale_filter);
    try std.testing.expectEqual(@as(f32, 0.75), surface.renderer_scale);
    try std.testing.expectEqual(wayland.config.UpscaleFilter.linear, surface.upscale_filter);
    try std.testing.expectEqual(@as(f32, 2.0), app.animation.speed);
    try std.testing.expectEqual(new_colors, app.current_palette);
    try std.testing.expect(app.fade == null);
    try std.testing.expectEqual(candidate_palettes_ptr, app.palettes.ptr);
    try std.testing.expectEqualStrings("new", app.palettes[0].nameSlice());
    try std.testing.expectEqual(@as(usize, 0), app.active_palette_name_len);
}
