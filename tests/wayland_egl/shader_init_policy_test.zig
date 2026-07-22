const std = @import("std");
const normal_policy = @import("normal_policy");
const forced_policy = @import("forced_policy");

test "normal build permits shader initialization" {
    try normal_policy.beforeInitialization();
}

test "fault build fails before shader initialization" {
    try std.testing.expectError(
        error.Phase3aForcedShaderInitFailure,
        forced_policy.beforeInitialization(),
    );
}
