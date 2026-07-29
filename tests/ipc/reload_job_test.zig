const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const ipc = @import("ipc");
const config = ipc.config;
const reload = ipc.reload_job;
const IpcConnection = ipc.connection.IpcConnection;

fn expectNonblocking(fd: posix.fd_t) !void {
    const rc = linux.fcntl(fd, linux.F.GETFL, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
    const flags: linux.O = @bitCast(@as(u32, @intCast(rc)));
    try std.testing.expect(flags.NONBLOCK);
}

fn expectCloseOnExec(fd: posix.fd_t) !void {
    const rc = linux.fcntl(fd, linux.F.GETFD, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
    try std.testing.expect(rc & linux.FD_CLOEXEC != 0);
}

fn expectClosed(fd: posix.fd_t) !void {
    const rc = linux.fcntl(fd, linux.F.GETFD, 0);
    try std.testing.expectEqual(linux.E.BADF, linux.errno(rc));
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

const FakeState = struct {
    gate: u32 align(4) = 1,
    eventfd_create_error: ?anyerror = null,
    spawn_error: ?anyerror = null,
    load_error: ?anyerror = null,
    write_error: ?anyerror = null,
    palette_len: usize = 0,
    event_fd: posix.fd_t = -1,
    eventfd_create_calls: usize = 0,
    thread_start_calls: usize = 0,
    load_calls: usize = 0,
    write_calls: usize = 0,
    seen_path: [256]u8 = undefined,
    seen_path_len: usize = 0,

    fn release(self: *FakeState) void {
        @atomicStore(u32, &self.gate, 1, .release);
        std.Io.futexWake(std.testing.io, u32, &self.gate, 1);
    }
};

fn fakeLoad(
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    resolved_path: config.ResolvedConfigPath,
) !config.LoadResult {
    const state: *FakeState = @ptrCast(@alignCast(context.?));
    while (@atomicLoad(u32, &state.gate, .acquire) == 0) {
        std.Io.futexWaitUncancelable(io, u32, &state.gate, 0);
    }
    state.load_calls += 1;
    if (resolved_path.path.len > state.seen_path.len) return error.TestPathTooLong;
    @memcpy(state.seen_path[0..resolved_path.path.len], resolved_path.path);
    state.seen_path_len = resolved_path.path.len;
    if (state.load_error) |err| return err;
    return .{
        .config = config.defaultConfig(),
        .palettes = try allocator.alloc(config.NamedPalette, state.palette_len),
    };
}

fn successfulLoad(
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: std.Io,
    _: config.ResolvedConfigPath,
) !config.LoadResult {
    _ = context;
    return .{
        .config = config.defaultConfig(),
        .palettes = try allocator.alloc(config.NamedPalette, 0),
    };
}

fn fakeEventfdCreate(context: ?*anyopaque) !posix.fd_t {
    const state: *FakeState = @ptrCast(@alignCast(context.?));
    state.eventfd_create_calls += 1;
    if (state.eventfd_create_error) |err| return err;
    const fd = try ipc.sys.eventfdCreate();
    state.event_fd = fd;
    return fd;
}

fn fakeEventfdWrite(context: ?*anyopaque, fd: posix.fd_t, value: u64) !void {
    const state: *FakeState = @ptrCast(@alignCast(context.?));
    state.write_calls += 1;
    if (state.write_error) |err| return err;
    try ipc.sys.eventfdWrite(fd, value);
}

fn fakeThreadStart(context: ?*anyopaque, job: *reload.ReloadJob) !std.Thread {
    const state: *FakeState = @ptrCast(@alignCast(context.?));
    state.thread_start_calls += 1;
    if (state.spawn_error) |err| return err;
    return reload.production_ops.thread_start(null, job);
}

fn fakeOps(state: *FakeState) reload.ReloadOps {
    var ops = reload.production_ops;
    ops.context = state;
    ops.load = fakeLoad;
    ops.eventfd_create = fakeEventfdCreate;
    ops.eventfd_write = fakeEventfdWrite;
    ops.thread_start = fakeThreadStart;
    return ops;
}

fn newState() !*FakeState {
    const state = try std.testing.allocator.create(FakeState);
    state.* = .{};
    return state;
}

fn resolved(path: []const u8) config.ResolvedConfigPath {
    return .{ .path = path, .origin = .explicit };
}

test "eventfd is nonblocking close-on-exec and transfers one native token" {
    const fd = try ipc.sys.eventfdCreate();
    defer ipc.sys.close(fd);
    try expectNonblocking(fd);
    try expectCloseOnExec(fd);
    try std.testing.expectError(error.WouldBlock, ipc.sys.eventfdRead(fd));
    try ipc.sys.eventfdWrite(fd, 1);
    try std.testing.expectEqual(@as(u64, 1), try ipc.sys.eventfdRead(fd));
}

test "eventfd read rejects a short native token" {
    var fds: [2]posix.fd_t = undefined;
    const rc = linux.pipe2(&fds, .{ .NONBLOCK = true, .CLOEXEC = true });
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
    defer ipc.sys.close(fds[0]);
    defer ipc.sys.close(fds[1]);
    const half = [_]u8{0xa5} ** 4;
    try std.testing.expectEqual(@as(usize, half.len), linux.write(fds[1], &half, half.len));
    try std.testing.expectError(error.ShortRead, ipc.sys.eventfdRead(fds[0]));
}

test "reload path resolver returns caller-owned explicit and default paths" {
    const explicit = try config.resolveConfigPathForReload(
        std.testing.allocator,
        .empty,
        "relative/config.toml",
    );
    defer std.testing.allocator.free(explicit.path);
    try std.testing.expectEqual(config.ConfigPathOrigin.explicit, explicit.origin);
    try std.testing.expectEqualStrings("relative/config.toml", explicit.path);

    const env_entries: [:null]const ?[*:0]const u8 = &.{
        "XDG_CONFIG_HOME=/tmp/reload-job-xdg",
    };
    const environ = std.process.Environ{ .block = .{ .slice = env_entries } };
    const defaulted = try config.resolveConfigPathForReload(
        std.testing.allocator,
        environ,
        null,
    );
    defer std.testing.allocator.free(defaulted.path);
    try std.testing.expectEqual(config.ConfigPathOrigin.default, defaulted.origin);
    try std.testing.expectEqualStrings(
        "/tmp/reload-job-xdg/wlchroma/config.toml",
        defaulted.path,
    );
}

test "resolved loader preserves explicit and default missing-file errors" {
    const missing = "/tmp/wlchroma-reload-job-definitely-missing/config.toml";
    try std.testing.expectError(
        error.ConfigFileError,
        config.loadConfigFullResolved(
            std.testing.allocator,
            std.testing.io,
            .{ .path = missing, .origin = .explicit },
        ),
    );
    try std.testing.expectError(
        error.ConfigFileNotFound,
        config.loadConfigFullResolved(
            std.testing.allocator,
            std.testing.io,
            .{ .path = missing, .origin = .default },
        ),
    );
}

test "start rolls back both allocation boundaries before creating an eventfd" {
    inline for (0..2) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        const state = try newState();
        defer std.testing.allocator.destroy(state);
        try std.testing.expectError(
            error.OutOfMemory,
            reload.ReloadJob.start(
                failing.allocator(),
                std.testing.io,
                resolved("reload.toml"),
                fakeOps(state),
            ),
        );
        try std.testing.expectEqual(@as(usize, 0), state.eventfd_create_calls);
        try std.testing.expectEqual(failing.allocations, failing.deallocations);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "eventfd create failure frees the copied path and job" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const state = try newState();
    defer std.testing.allocator.destroy(state);
    state.eventfd_create_error = error.TestCreateFailed;
    try std.testing.expectError(
        error.TestCreateFailed,
        reload.ReloadJob.start(
            failing.allocator(),
            std.testing.io,
            resolved("reload.toml"),
            fakeOps(state),
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), state.eventfd_create_calls);
    try std.testing.expectEqual(@as(usize, 0), state.thread_start_calls);
    try std.testing.expectEqual(failing.allocations, failing.deallocations);
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "spawn failure closes the eventfd and leaves the caller connection untouched" {
    const state = try newState();
    defer std.testing.allocator.destroy(state);
    state.spawn_error = error.TestSpawnFailed;
    const fds = try socketPair();
    defer ipc.sys.close(fds[1]);
    var source: ?IpcConnection = IpcConnection.init(fds[0], 0);
    defer if (source) |*client| {
        _ = client.close();
    };

    try std.testing.expectError(
        error.TestSpawnFailed,
        reload.ReloadJob.start(
            std.testing.allocator,
            std.testing.io,
            resolved("reload.toml"),
            fakeOps(state),
        ),
    );
    try std.testing.expect(source != null);
    try expectCloseOnExec(source.?.fd);
    try std.testing.expectEqual(@as(usize, 1), state.thread_start_calls);
    try expectClosed(state.event_fd);
}

test "worker publishes one loaded result after release-acquire readiness" {
    const state = try newState();
    defer std.testing.allocator.destroy(state);
    var ops = fakeOps(state);
    ops.load = successfulLoad;
    const job = try reload.ReloadJob.start(
        std.testing.allocator,
        std.testing.io,
        resolved("reload.toml"),
        ops,
    );
    defer job.deinit();
    job.joinOnce();
    try std.testing.expect(job.readyAcquire());
    try std.testing.expectEqual(@as(u64, 1), try ipc.sys.eventfdRead(job.event_fd));
    var outcome = job.takeOutcomeAfterJoin();
    switch (outcome) {
        .loaded => |*loaded| loaded.deinit(std.testing.allocator),
        else => return error.TestExpectedLoadedOutcome,
    }
    try std.testing.expect(job.outcome == .pending);
    try std.testing.expectEqual(reload.Phase.responding, job.phase);
}

test "worker publishes the loader error and still notifies" {
    const state = try newState();
    defer std.testing.allocator.destroy(state);
    state.load_error = error.TestLoadFailed;
    const job = try reload.ReloadJob.start(
        std.testing.allocator,
        std.testing.io,
        resolved("broken.toml"),
        fakeOps(state),
    );
    defer job.deinit();
    job.joinOnce();
    try std.testing.expect(job.readyAcquire());
    try std.testing.expectEqual(@as(u64, 1), try ipc.sys.eventfdRead(job.event_fd));
    const outcome = job.takeOutcomeAfterJoin();
    switch (outcome) {
        .failed => |err| try std.testing.expectEqual(error.TestLoadFailed, err),
        else => return error.TestExpectedFailedOutcome,
    }
}

test "notification write failure remains readable after join without a false token" {
    const state = try newState();
    defer std.testing.allocator.destroy(state);
    state.write_error = error.TestNotifyFailed;
    const job = try reload.ReloadJob.start(
        std.testing.allocator,
        std.testing.io,
        resolved("reload.toml"),
        fakeOps(state),
    );
    defer job.deinit();
    job.joinOnce();
    try std.testing.expect(job.readyAcquire());
    try std.testing.expectEqual(error.TestNotifyFailed, job.notification_error.?);
    try std.testing.expectError(error.WouldBlock, ipc.sys.eventfdRead(job.event_fd));
    var outcome = job.takeOutcomeAfterJoin();
    switch (outcome) {
        .loaded => |*loaded| loaded.deinit(std.testing.allocator),
        else => return error.TestExpectedLoadedOutcome,
    }
}

test "job copies the resolved path before spawning and joinOnce consumes one handle" {
    const state = try newState();
    defer std.testing.allocator.destroy(state);
    @atomicStore(u32, &state.gate, 0, .release);
    var caller_path: ?[]u8 = try std.testing.allocator.dupe(u8, "owned/by/main.toml");
    defer if (caller_path) |path| {
        std.testing.allocator.free(path);
    };
    const caller_ptr = caller_path.?.ptr;
    const job = try reload.ReloadJob.start(
        std.testing.allocator,
        std.testing.io,
        resolved(caller_path.?),
        fakeOps(state),
    );
    defer {
        state.release();
        job.deinit();
    }
    std.testing.allocator.free(caller_path.?);
    caller_path = null;
    try std.testing.expect(job.path.ptr != caller_ptr);
    try std.testing.expect(!job.readyAcquire());
    state.release();
    job.joinOnce();
    job.joinOnce();
    try std.testing.expect(job.thread == null);
    try std.testing.expectEqualStrings("owned/by/main.toml", state.seen_path[0..state.seen_path_len]);
    var outcome = job.takeOutcomeAfterJoin();
    switch (outcome) {
        .loaded => |*loaded| loaded.deinit(std.testing.allocator),
        else => return error.TestExpectedLoadedOutcome,
    }
}

test "orphaning closes only the transferred client while loading continues" {
    const state = try newState();
    defer std.testing.allocator.destroy(state);
    @atomicStore(u32, &state.gate, 0, .release);
    const job = try reload.ReloadJob.start(
        std.testing.allocator,
        std.testing.io,
        resolved("reload.toml"),
        fakeOps(state),
    );
    defer {
        state.release();
        job.deinit();
    }
    const fds = try socketPair();
    defer ipc.sys.close(fds[1]);
    var source: ?IpcConnection = IpcConnection.init(fds[0], 0);
    job.takeClient(&source);
    try std.testing.expect(source == null);
    try std.testing.expect(job.client != null);
    job.orphanClient();
    try std.testing.expect(job.client == null);
    try std.testing.expectEqual(reload.Phase.orphaned, job.phase);
    try expectClosed(fds[0]);
    try expectCloseOnExec(fds[1]);
    state.release();
}

test "deinit joins and frees an unconsumed loaded result exactly once" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const state = try newState();
    defer std.testing.allocator.destroy(state);
    state.palette_len = 1;
    const job = try reload.ReloadJob.start(
        failing.allocator(),
        std.testing.io,
        resolved("reload.toml"),
        fakeOps(state),
    );
    job.deinit();
    try std.testing.expectEqual(@as(usize, 1), state.load_calls);
    try std.testing.expectEqual(@as(usize, 1), state.write_calls);
    try std.testing.expectEqual(failing.allocations, failing.deallocations);
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    try expectClosed(state.event_fd);
}
