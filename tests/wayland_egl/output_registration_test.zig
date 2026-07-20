const std = @import("std");
const wayland = @import("wayland_test");
const registry = wayland.registry;
const OutputInfo = wayland.output.OutputInfo;
const c = wayland.c;

const FakeState = struct {
    outputs: *std.ArrayList(*OutputInfo),
    bind_succeeds: bool = true,
    listener_result: c_int = 0,
    bind_calls: usize = 0,
    listener_calls: usize = 0,
    release_calls: usize = 0,
    listener_userdata: ?*OutputInfo = null,
};

fn fakeProxy() *c.wl_output {
    return @ptrFromInt(0x1000);
}

fn fakeBind(context: ?*anyopaque, _: ?*c.wl_registry, _: u32, _: u32) ?*c.wl_output {
    const state: *FakeState = @ptrCast(@alignCast(context));
    state.bind_calls += 1;
    return if (state.bind_succeeds) fakeProxy() else null;
}

fn fakeAddListener(context: ?*anyopaque, _: *c.wl_output, info: *OutputInfo) c_int {
    const state: *FakeState = @ptrCast(@alignCast(context));
    state.listener_calls += 1;
    state.listener_userdata = info;
    std.debug.assert(state.outputs.items.len == 1);
    std.debug.assert(state.outputs.items[0] == info);
    return state.listener_result;
}

fn fakeRelease(context: ?*anyopaque, _: *c.wl_output) void {
    const state: *FakeState = @ptrCast(@alignCast(context));
    state.release_calls += 1;
}

fn fakeOps(state: *FakeState) registry.OutputRegistrationOps {
    return .{
        .context = state,
        .bind = fakeBind,
        .add_listener = fakeAddListener,
        .release = fakeRelease,
    };
}

test "allocation failure binds no output proxy" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const allocator = failing.allocator();
    var outputs: std.ArrayList(*OutputInfo) = .empty;
    defer outputs.deinit(allocator);
    var state = FakeState{ .outputs = &outputs };
    try std.testing.expectError(
        error.OutOfMemory,
        registry.registerOutputWithOps(allocator, &outputs, null, 7, 3, fakeOps(&state)),
    );
    try std.testing.expectEqual(@as(usize, 0), state.bind_calls);
    try std.testing.expectEqual(@as(usize, 0), state.listener_calls);
    try std.testing.expectEqual(@as(usize, 0), state.release_calls);
    try std.testing.expectEqual(@as(usize, 0), outputs.items.len);
}

test "bind failure destroys the uninitialized allocation" {
    var outputs: std.ArrayList(*OutputInfo) = .empty;
    defer outputs.deinit(std.testing.allocator);
    var state = FakeState{ .outputs = &outputs, .bind_succeeds = false };
    try std.testing.expectError(
        error.OutputBindFailed,
        registry.registerOutputWithOps(std.testing.allocator, &outputs, null, 7, 3, fakeOps(&state)),
    );
    try std.testing.expectEqual(@as(usize, 1), state.bind_calls);
    try std.testing.expectEqual(@as(usize, 0), state.listener_calls);
    try std.testing.expectEqual(@as(usize, 0), state.release_calls);
    try std.testing.expectEqual(@as(usize, 0), outputs.items.len);
}

test "append failure releases the proxy exactly once" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const allocator = failing.allocator();
    var outputs: std.ArrayList(*OutputInfo) = .empty;
    defer outputs.deinit(allocator);
    var state = FakeState{ .outputs = &outputs };
    try std.testing.expectError(
        error.OutOfMemory,
        registry.registerOutputWithOps(allocator, &outputs, null, 7, 3, fakeOps(&state)),
    );
    try std.testing.expectEqual(@as(usize, 1), state.bind_calls);
    try std.testing.expectEqual(@as(usize, 0), state.listener_calls);
    try std.testing.expectEqual(@as(usize, 1), state.release_calls);
    try std.testing.expectEqual(@as(usize, 0), outputs.items.len);
}

test "listener failure removes the appended userdata before release" {
    var outputs: std.ArrayList(*OutputInfo) = .empty;
    defer outputs.deinit(std.testing.allocator);
    var state = FakeState{ .outputs = &outputs, .listener_result = -1 };
    try std.testing.expectError(
        error.OutputListenerFailed,
        registry.registerOutputWithOps(std.testing.allocator, &outputs, null, 7, 3, fakeOps(&state)),
    );
    try std.testing.expectEqual(@as(usize, 1), state.listener_calls);
    try std.testing.expectEqual(@as(usize, 1), state.release_calls);
    try std.testing.expectEqual(@as(usize, 0), outputs.items.len);
}

test "successful registration transfers one heap-stable userdata pointer" {
    var outputs: std.ArrayList(*OutputInfo) = .empty;
    defer outputs.deinit(std.testing.allocator);
    var state = FakeState{ .outputs = &outputs };
    try registry.registerOutputWithOps(std.testing.allocator, &outputs, null, 7, 3, fakeOps(&state));
    try std.testing.expectEqual(@as(usize, 1), outputs.items.len);
    try std.testing.expect(outputs.items[0] == state.listener_userdata.?);
    try std.testing.expectEqual(@as(usize, 0), state.release_calls);

    const info = outputs.pop().?;
    fakeRelease(&state, info.wl_output.?);
    info.wl_output = null;
    info.deinit();
    std.testing.allocator.destroy(info);
    try std.testing.expectEqual(@as(usize, 1), state.release_calls);
}
