const std = @import("std");

pub const Error = error{InvalidInterval};

pub const FrameSchedule = struct {
    next_logical_deadline_ns: ?u64 = null,

    pub const Due = struct {
        elapsed_ticks: u64,
        next: FrameSchedule,
        resynchronized: bool,
    };

    pub const Plan = union(enum) {
        paused,
        wait: u64,
        due: Due,
    };

    pub fn inactive() FrameSchedule {
        return .{};
    }

    pub fn begin(now_ns: u64, interval_ns: u32) Error!FrameSchedule {
        if (interval_ns == 0) return error.InvalidInterval;

        return .{
            .next_logical_deadline_ns = std.math.add(
                u64,
                now_ns,
                @as(u64, interval_ns),
            ) catch std.math.maxInt(u64),
        };
    }

    pub fn rebase(_: FrameSchedule, now_ns: u64, interval_ns: u32) Error!FrameSchedule {
        return begin(now_ns, interval_ns);
    }

    pub fn plan(self: FrameSchedule, now_ns: u64, interval_ns: u32) Error!Plan {
        if (interval_ns == 0) return error.InvalidInterval;

        const deadline_ns = self.next_logical_deadline_ns orelse return .paused;
        if (now_ns < deadline_ns) return .{ .wait = deadline_ns };

        const interval: u64 = interval_ns;
        const elapsed_ticks = std.math.add(u64, (now_ns - deadline_ns) / interval, 1) catch
            std.math.maxInt(u64);
        const advance_ns = std.math.mul(u64, elapsed_ticks, interval) catch {
            return .{ .due = .{
                .elapsed_ticks = elapsed_ticks,
                .next = try begin(now_ns, interval_ns),
                .resynchronized = true,
            } };
        };
        const next_deadline_ns = std.math.add(u64, deadline_ns, advance_ns) catch {
            return .{ .due = .{
                .elapsed_ticks = elapsed_ticks,
                .next = try begin(now_ns, interval_ns),
                .resynchronized = true,
            } };
        };

        return .{ .due = .{
            .elapsed_ticks = elapsed_ticks,
            .next = .{ .next_logical_deadline_ns = next_deadline_ns },
            .resynchronized = false,
        } };
    }
};
