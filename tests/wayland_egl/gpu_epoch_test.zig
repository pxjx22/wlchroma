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

    pub fn detachAll(self: *FakeOps) void {
        self.record(.detach_all);
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

    pub fn hasContext(self: *StartOps) bool {
        return self.context_live;
    }
    pub fn permanentFailure(self: *StartOps) bool {
        return self.failed;
    }
    pub fn readyOutputCount(self: *StartOps) usize {
        return self.ready_outputs;
    }
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
