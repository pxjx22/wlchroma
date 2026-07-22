const std = @import("std");
const upload_mod = @import("wlchroma_src").gpu_upload_state;
const GpuUploadState = upload_mod.GpuUploadState;

const Event = enum {
    use_program,
    bind_geometry,
    upload_palette,
    upload_static,
};

const FakeOps = struct {
    events: [8]Event = undefined,
    len: usize = 0,

    fn push(self: *FakeOps, event: Event) void {
        self.events[self.len] = event;
        self.len += 1;
    }

    pub fn useProgram(self: *FakeOps) void {
        self.push(.use_program);
    }
    pub fn bindGeometry(self: *FakeOps) void {
        self.push(.bind_geometry);
    }
    pub fn uploadPalette(self: *FakeOps) void {
        self.push(.upload_palette);
    }
    pub fn uploadStatic(self: *FakeOps) void {
        self.push(.upload_static);
    }
};

fn expectEvents(ops: *const FakeOps, expected: []const Event) !void {
    try std.testing.expectEqual(expected.len, ops.len);
    try std.testing.expectEqualSlices(Event, expected, ops.events[0..ops.len]);
}

test "GPU upload state occupies one byte" {
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(GpuUploadState));
}

test "clean state performs no operation" {
    var state = GpuUploadState{};
    var ops = FakeOps{};
    state.flushIfCurrent(FakeOps, &ops, true);
    try std.testing.expect(state.isClean());
    try expectEvents(&ops, &.{});
}

test "palette mutation dirties only palette for a live shader" {
    var state = GpuUploadState{};
    state.markPaletteDirty(true);
    try std.testing.expect(!state.dirty.program_binding);
    try std.testing.expect(state.dirty.palette);
    try std.testing.expect(!state.dirty.static_uniforms);
}

test "palette mutation without a shader remains clean" {
    var state = GpuUploadState{};
    state.markPaletteDirty(false);
    try std.testing.expect(state.isClean());
}

test "new generation marks every program global field" {
    const state = GpuUploadState.newGeneration();
    try std.testing.expect(state.dirty.program_binding);
    try std.testing.expect(state.dirty.palette);
    try std.testing.expect(state.dirty.static_uniforms);
}

test "no current context preserves all dirty state" {
    var state = GpuUploadState.newGeneration();
    var ops = FakeOps{};
    state.flushIfCurrent(FakeOps, &ops, false);
    try std.testing.expect(!state.isClean());
    try expectEvents(&ops, &.{});
}

test "full flush is ordered and clears state" {
    var state = GpuUploadState.newGeneration();
    var ops = FakeOps{};
    state.flushIfCurrent(FakeOps, &ops, true);
    try expectEvents(&ops, &.{
        .use_program,
        .bind_geometry,
        .upload_palette,
        .upload_static,
    });
    try std.testing.expect(state.isClean());
}

test "palette only flush performs no geometry or static upload" {
    var state = GpuUploadState{};
    state.markPaletteDirty(true);
    var ops = FakeOps{};
    state.flushIfCurrent(FakeOps, &ops, true);
    try expectEvents(&ops, &.{ .use_program, .upload_palette });
    try std.testing.expect(state.isClean());
}

test "only first current surface consumes a palette mutation" {
    var state = GpuUploadState{};
    state.markPaletteDirty(true);
    var first = FakeOps{};
    var second = FakeOps{};
    state.flushIfCurrent(FakeOps, &first, true);
    state.flushIfCurrent(FakeOps, &second, true);
    try expectEvents(&first, &.{ .use_program, .upload_palette });
    try expectEvents(&second, &.{});
}
