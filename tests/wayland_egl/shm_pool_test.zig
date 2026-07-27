const std = @import("std");
const ShmPool = @import("wayland_test").shm_pool.ShmPool;

test "released SHM buffer can be acquired again" {
    var pool: ShmPool = undefined;
    pool.busy = .{ false, true };

    const first = pool.acquireBuffer().?;
    try std.testing.expectEqual(@as(u1, 0), first);
    try std.testing.expect(pool.busy[first]);

    pool.releaseBuffer(first);
    try std.testing.expect(!pool.busy[first]);
    try std.testing.expectEqual(first, pool.acquireBuffer().?);
}
