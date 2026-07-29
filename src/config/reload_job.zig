const std = @import("std");
const posix = std.posix;
const config = @import("config.zig");
const IpcConnection = @import("../ipc/connection.zig").IpcConnection;
const sys = @import("sys");
const build_options = @import("build_options");

pub const Phase = enum { loading, responding, orphaned };

pub const LoadOutcome = union(enum) {
    pending,
    loaded: config.LoadResult,
    failed: anyerror,
};

/// Operations are stored by value, but context is borrowed. Its allocation and
/// every object it points to must remain valid until ReloadJob.deinit returns.
pub const ReloadOps = struct {
    context: ?*anyopaque = null,
    load: *const fn (
        ?*anyopaque,
        std.mem.Allocator,
        std.Io,
        config.ResolvedConfigPath,
    ) anyerror!config.LoadResult,
    eventfd_create: *const fn (?*anyopaque) anyerror!posix.fd_t,
    eventfd_read: *const fn (?*anyopaque, posix.fd_t) anyerror!u64,
    eventfd_write: *const fn (?*anyopaque, posix.fd_t, u64) anyerror!void,
    thread_start: *const fn (?*anyopaque, *ReloadJob) anyerror!std.Thread,
    monotonic_ns: *const fn (?*anyopaque) anyerror!u64,
};

pub const ReloadJob = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    ops: ReloadOps,
    path: []u8,
    path_origin: config.ConfigPathOrigin,
    event_fd: posix.fd_t,
    thread: ?std.Thread,
    ready: std.atomic.Value(bool),
    outcome: LoadOutcome,
    notification_error: ?anyerror,
    notification_fault: bool,
    client: ?IpcConnection,
    phase: Phase,

    pub fn start(
        allocator: std.mem.Allocator,
        io: std.Io,
        resolved: config.ResolvedConfigPath,
        ops: ReloadOps,
    ) !*ReloadJob {
        const job = try allocator.create(ReloadJob);
        errdefer allocator.destroy(job);

        const path = try allocator.dupe(u8, resolved.path);
        errdefer allocator.free(path);

        const event_fd = try ops.eventfd_create(ops.context);
        errdefer sys.close(event_fd);

        job.* = .{
            .allocator = allocator,
            .io = io,
            .ops = ops,
            .path = path,
            .path_origin = resolved.origin,
            .event_fd = event_fd,
            .thread = null,
            .ready = .init(false),
            .outcome = .pending,
            .notification_error = null,
            .notification_fault = false,
            .client = null,
            .phase = .loading,
        };
        job.thread = try ops.thread_start(ops.context, job);
        return job;
    }

    pub fn takeClient(self: *ReloadJob, source: *?IpcConnection) void {
        std.debug.assert(self.client == null);
        std.debug.assert(source.* != null);
        self.client = source.*;
        source.* = null;
    }

    pub fn readyAcquire(self: *const ReloadJob) bool {
        return self.ready.load(.acquire);
    }

    pub fn joinOnce(self: *ReloadJob) void {
        const thread = self.thread orelse return;
        self.thread = null;
        thread.join();
    }

    pub fn takeOutcomeAfterJoin(self: *ReloadJob) LoadOutcome {
        std.debug.assert(self.thread == null);
        const outcome = self.outcome;
        self.outcome = .pending;
        if (self.phase != .orphaned) self.phase = .responding;
        return outcome;
    }

    pub fn orphanClient(self: *ReloadJob) void {
        if (self.client) |*client| {
            _ = client.close();
            self.client = null;
        }
        self.phase = .orphaned;
    }

    pub fn deinit(self: *ReloadJob) void {
        const allocator = self.allocator;
        self.joinOnce();
        if (self.client) |*client| _ = client.close();
        switch (self.outcome) {
            .loaded => |loaded_value| {
                var loaded = loaded_value;
                loaded.deinit(allocator);
            },
            else => {},
        }
        sys.close(self.event_fd);
        allocator.free(self.path);
        allocator.destroy(self);
    }
};

fn workerMain(job: *ReloadJob) void {
    const resolved = config.ResolvedConfigPath{
        .path = job.path,
        .origin = job.path_origin,
    };
    const loaded = job.ops.load(
        job.ops.context,
        job.allocator,
        job.io,
        resolved,
    );
    job.outcome = if (loaded) |value|
        .{ .loaded = value }
    else |err|
        .{ .failed = err };
    job.ready.store(true, .release);
    job.ops.eventfd_write(job.ops.context, job.event_fd, 1) catch |err| {
        job.notification_error = err;
    };
}

fn productionLoad(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    resolved: config.ResolvedConfigPath,
) !config.LoadResult {
    if (build_options.phase3c_reload_delay_ms > 0) {
        try std.Io.sleep(
            io,
            .fromMilliseconds(build_options.phase3c_reload_delay_ms),
            .awake,
        );
    }
    return config.loadConfigFullResolved(allocator, io, resolved);
}

fn productionEventfdCreate(_: ?*anyopaque) !posix.fd_t {
    return sys.eventfdCreate();
}

fn productionEventfdRead(_: ?*anyopaque, fd: posix.fd_t) !u64 {
    return sys.eventfdRead(fd);
}

fn productionEventfdWrite(_: ?*anyopaque, fd: posix.fd_t, value: u64) !void {
    return sys.eventfdWrite(fd, value);
}

fn productionThreadStart(_: ?*anyopaque, job: *ReloadJob) !std.Thread {
    return std.Thread.spawn(.{}, workerMain, .{job});
}

fn productionMonotonicNs(_: ?*anyopaque) !u64 {
    return sys.monotonicNsChecked();
}

pub const production_ops = ReloadOps{
    .load = productionLoad,
    .eventfd_create = productionEventfdCreate,
    .eventfd_read = productionEventfdRead,
    .eventfd_write = productionEventfdWrite,
    .thread_start = productionThreadStart,
    .monotonic_ns = productionMonotonicNs,
};
