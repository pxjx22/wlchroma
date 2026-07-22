const std = @import("std");
const src = @import("wlchroma_src");
const gpu_fallback = src.gpu_fallback;
const Rgb = src.defaults.Rgb;

const Event = enum {
    close_epoch,
    replace_colormix,
    invalidate_standins,
    configure_cpu,
    mark_applied,
};

const FakeOps = struct {
    permanent_failure: bool = false,
    applied: bool = false,
    gpu_only: bool = false,
    authoritative_palette: [3]Rgb = .{
        .{ .r = 0x11, .g = 0x22, .b = 0x33 },
        .{ .r = 0x44, .g = 0x55, .b = 0x66 },
        .{ .r = 0x77, .g = 0x88, .b = 0x99 },
    },
    embedded_palette: [3]Rgb = .{
        .{ .r = 0xaa, .g = 0xbb, .b = 0xcc },
        .{ .r = 0xdd, .g = 0xee, .b = 0xff },
        .{ .r = 0x01, .g = 0x02, .b = 0x03 },
    },
    replacement_palette: ?[3]Rgb = null,
    events: [8]Event = undefined,
    len: usize = 0,
    close_count: usize = 0,
    replace_count: usize = 0,
    invalidate_count: usize = 0,
    configure_count: usize = 0,
    mark_count: usize = 0,

    fn push(self: *FakeOps, event: Event) void {
        self.events[self.len] = event;
        self.len += 1;
    }

    pub fn permanentFailure(self: *FakeOps) bool {
        return self.permanent_failure;
    }

    pub fn fallbackApplied(self: *FakeOps) bool {
        return self.applied;
    }

    pub fn closeGpuEpoch(self: *FakeOps) void {
        self.close_count += 1;
        self.push(.close_epoch);
    }

    pub fn effectIsGpuOnly(self: *FakeOps) bool {
        return self.gpu_only;
    }

    pub fn currentPalette(self: *FakeOps) [3]Rgb {
        return self.authoritative_palette;
    }

    pub fn replaceWithColormix(self: *FakeOps, colors: [3]Rgb) void {
        self.replace_count += 1;
        self.replacement_palette = colors;
        self.push(.replace_colormix);
    }

    pub fn invalidateCpuStandins(self: *FakeOps) void {
        self.invalidate_count += 1;
        self.push(.invalidate_standins);
    }

    pub fn configureCpuSurfaces(self: *FakeOps) void {
        self.configure_count += 1;
        self.push(.configure_cpu);
    }

    pub fn markFallbackApplied(self: *FakeOps) void {
        self.mark_count += 1;
        self.applied = true;
        self.push(.mark_applied);
    }
};

fn expectEvents(ops: *const FakeOps, expected: []const Event) !void {
    try std.testing.expectEqual(expected.len, ops.len);
    try std.testing.expectEqualSlices(Event, expected, ops.events[0..ops.len]);
}

test "recoverable failure performs no fallback work" {
    var ops = FakeOps{};

    try std.testing.expect(!gpu_fallback.apply(FakeOps, &ops));
    try expectEvents(&ops, &.{});
}

test "permanent colormix failure closes GPU before configuring CPU surfaces" {
    var ops = FakeOps{ .permanent_failure = true };

    try std.testing.expect(gpu_fallback.apply(FakeOps, &ops));
    try expectEvents(&ops, &.{
        .close_epoch,
        .invalidate_standins,
        .configure_cpu,
        .mark_applied,
    });
    try std.testing.expectEqual(@as(usize, 0), ops.replace_count);
}

test "permanent GPU-only failure converts from the authoritative palette" {
    var ops = FakeOps{
        .permanent_failure = true,
        .gpu_only = true,
    };

    try std.testing.expect(!std.meta.eql(ops.authoritative_palette, ops.embedded_palette));
    try std.testing.expect(gpu_fallback.apply(FakeOps, &ops));
    try expectEvents(&ops, &.{
        .close_epoch,
        .replace_colormix,
        .invalidate_standins,
        .configure_cpu,
        .mark_applied,
    });
    try std.testing.expectEqual(ops.authoritative_palette, ops.replacement_palette.?);
}

test "permanent fallback is idempotent" {
    var ops = FakeOps{
        .permanent_failure = true,
        .gpu_only = true,
    };

    try std.testing.expect(gpu_fallback.apply(FakeOps, &ops));
    try std.testing.expect(!gpu_fallback.apply(FakeOps, &ops));
    try std.testing.expectEqual(@as(usize, 1), ops.close_count);
    try std.testing.expectEqual(@as(usize, 1), ops.replace_count);
    try std.testing.expectEqual(@as(usize, 1), ops.invalidate_count);
    try std.testing.expectEqual(@as(usize, 1), ops.configure_count);
    try std.testing.expectEqual(@as(usize, 1), ops.mark_count);
}
