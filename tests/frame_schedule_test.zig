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
