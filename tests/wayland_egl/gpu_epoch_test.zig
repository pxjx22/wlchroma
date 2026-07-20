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
    detached: [4]bool = @splat(false),
    app_wrapper_present: bool = true,
    surface_wrapper_present: [4]bool = @splat(true),
    context_destroy_saw_app_wrapper: bool = false,
    context_destroy_saw_surface_wrappers: [4]bool = @splat(false),
    events: [64]Event = undefined,
    events_len: usize = 0,

    fn record(self: *FakeOps, event: Event) void {
        self.events[self.events_len] = event;
        self.events_len += 1;
    }

    pub fn detachAll(self: *FakeOps) void {
        self.record(.detach_all);
        for (0..self.count) |index| self.detached[index] = true;
    }
    pub fn candidateCount(self: *FakeOps) usize {
        return self.count;
    }
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
    pub fn clearCurrent(self: *FakeOps) void {
        self.record(.clear_current);
    }
    pub fn destroySurface(self: *FakeOps, index: usize) void {
        self.record(.{ .destroy_surface = index });
    }
    pub fn destroyContext(self: *FakeOps) void {
        self.record(.destroy_context);
        self.context_destroy_saw_app_wrapper = self.app_wrapper_present;
        for (0..self.count) |index| {
            self.context_destroy_saw_surface_wrappers[index] =
                self.surface_wrapper_present[index];
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
    create_succeeds: bool = true,
    create_attempts: usize = 0,
    generations_created: usize = 0,
    ready_output_queries: usize = 0,

    pub fn hasContext(self: *StartOps) bool {
        return self.context_live;
    }
    pub fn permanentFailure(self: *StartOps) bool {
        return self.failed;
    }
    pub fn readyOutputCount(self: *StartOps) usize {
        self.ready_output_queries += 1;
        return self.ready_outputs;
    }
    pub fn createContext(self: *StartOps) bool {
        self.create_attempts += 1;
        if (!self.create_succeeds) {
            self.failed = true;
            return false;
        }
        self.generations_created += 1;
        self.context_live = true;
        return true;
    }
};

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

fn eventTag(event: Event) std.meta.Tag(Event) {
    return std.meta.activeTag(event);
}

fn firstTag(ops: *const FakeOps, tag: std.meta.Tag(Event)) ?usize {
    for (ops.events[0..ops.events_len], 0..) |event, index| {
        if (eventTag(event) == tag) return index;
    }
    return null;
}

fn expectEvents(ops: *const FakeOps, expected: []const Event) !void {
    try std.testing.expectEqual(expected.len, ops.events_len);
    for (expected, ops.events[0..ops.events_len]) |expected_event, actual_event| {
        try std.testing.expectEqualDeep(expected_event, actual_event);
    }
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

test "close follows the exact successful lifecycle" {
    var ops = FakeOps{ .successes = .{ false, true, false, false }, .count = 3 };
    gpu_epoch.close(FakeOps, &ops);
    try expectEvents(&ops, &.{
        .detach_all,
        .{ .try_current = 0 },
        .{ .try_current = 1 },
        .delete_app_gl,
        .{ .delete_surface_gl = 0 },
        .{ .delete_surface_gl = 1 },
        .{ .delete_surface_gl = 2 },
        .clear_current,
        .{ .destroy_surface = 0 },
        .{ .destroy_surface = 1 },
        .{ .destroy_surface = 2 },
        .destroy_context,
        .clear_handles,
    });
    try std.testing.expect(!ops.context_destroy_saw_app_wrapper);
    for (0..ops.count) |index| {
        try std.testing.expect(!ops.context_destroy_saw_surface_wrappers[index]);
    }
}

test "close follows the exact all-candidate-failure lifecycle" {
    var ops = FakeOps{ .count = 3 };
    gpu_epoch.close(FakeOps, &ops);
    try expectEvents(&ops, &.{
        .detach_all,
        .{ .try_current = 0 },
        .{ .try_current = 1 },
        .{ .try_current = 2 },
        .clear_current,
        .{ .destroy_surface = 0 },
        .{ .destroy_surface = 1 },
        .{ .destroy_surface = 2 },
        .destroy_context,
        .clear_handles,
    });
    try std.testing.expect(ops.context_destroy_saw_app_wrapper);
    for (0..ops.count) |index| {
        try std.testing.expect(ops.context_destroy_saw_surface_wrappers[index]);
    }
    try std.testing.expect(!ops.app_wrapper_present);
    try std.testing.expect(!ops.surface_wrapper_present[0]);
    try std.testing.expect(!ops.surface_wrapper_present[1]);
    try std.testing.expect(!ops.surface_wrapper_present[2]);
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

test "active context returns without querying ready outputs" {
    var ops = StartOps{ .context_live = true, .ready_outputs = 1 };
    try std.testing.expect(gpu_epoch.start(StartOps, &ops));
    try std.testing.expectEqual(@as(usize, 0), ops.ready_output_queries);
    try std.testing.expectEqual(@as(usize, 0), ops.create_attempts);
}

test "permanent failure returns without querying ready outputs" {
    var ops = StartOps{ .failed = true, .ready_outputs = 1 };
    try std.testing.expect(!gpu_epoch.start(StartOps, &ops));
    try std.testing.expectEqual(@as(usize, 0), ops.ready_output_queries);
    try std.testing.expectEqual(@as(usize, 0), ops.create_attempts);
}

test "permanent failure with ready outputs never attempts context creation" {
    var ops = StartOps{ .failed = true, .ready_outputs = 1 };
    try std.testing.expect(!gpu_epoch.start(StartOps, &ops));
    try std.testing.expectEqual(@as(usize, 0), ops.create_attempts);
    try std.testing.expectEqual(@as(usize, 0), ops.generations_created);
}

test "context creation failure latches and is never retried" {
    var ops = StartOps{ .ready_outputs = 1, .create_succeeds = false };
    try std.testing.expect(!gpu_epoch.start(StartOps, &ops));
    try std.testing.expectEqual(@as(usize, 1), ops.create_attempts);
    try std.testing.expectEqual(@as(usize, 0), ops.generations_created);
    try std.testing.expect(ops.failed);

    try std.testing.expect(!gpu_epoch.start(StartOps, &ops));
    try std.testing.expectEqual(@as(usize, 1), ops.create_attempts);
    try std.testing.expectEqual(@as(usize, 0), ops.generations_created);
}

test "only permanent GPU failure forces a GPU-only effect to CPU" {
    try std.testing.expect(!gpu_epoch.requiresCpuFallback(false, true));
    try std.testing.expect(!gpu_epoch.requiresCpuFallback(true, false));
    try std.testing.expect(gpu_epoch.requiresCpuFallback(true, true));
}

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
