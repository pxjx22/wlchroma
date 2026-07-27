const std = @import("std");
const animation_state = @import("wlchroma_src").animation_state;

const AnimationState = animation_state.AnimationState;
const Direction = animation_state.Direction;
const PHASE_LIMIT = animation_state.PHASE_LIMIT;

test "initialization starts at zero moving forward" {
    const animation = AnimationState.init(1.0);

    try std.testing.expectEqual(@as(f64, 0.0), animation.phase);
    try std.testing.expectEqual(@as(f32, 1.0), animation.speed);
    try std.testing.expectEqual(Direction.forward, animation.direction);
    try std.testing.expectEqual(@as(f32, 0.0), animation.time());
}

test "one expiration advances by the configured time scale" {
    var animation = AnimationState.init(1.0);

    animation.advance(1);

    try std.testing.expectApproxEqAbs(@as(f64, 0.01), animation.phase, 1e-12);
    try std.testing.expectEqual(Direction.forward, animation.direction);
}

test "multiple expirations advance in one step" {
    var animation = AnimationState.init(0.25);

    animation.advance(4);

    try std.testing.expectApproxEqAbs(@as(f64, 0.01), animation.phase, 1e-12);
    try std.testing.expectEqual(Direction.forward, animation.direction);
}

test "zero expirations preserve all state" {
    var animation = AnimationState{
        .phase = 123.5,
        .speed = 2.5,
        .direction = .backward,
    };
    const before = animation;

    animation.advance(0);

    try std.testing.expectEqualDeep(before, animation);
}

test "speed changes preserve phase and affect only future steps" {
    var animation = AnimationState.init(1.0);
    animation.advance(1);
    const before = animation.phase;
    animation.setSpeed(2.5);
    try std.testing.expectEqual(before, animation.phase);
    animation.advance(1);
    try std.testing.expectApproxEqAbs(
        before + 0.025,
        animation.phase,
        1e-12,
    );
}

test "reset restores zero and forward direction with the new speed" {
    var animation = AnimationState{
        .phase = 789.25,
        .speed = 2.5,
        .direction = .backward,
    };

    animation.reset(0.25);

    try std.testing.expectEqual(@as(f64, 0.0), animation.phase);
    try std.testing.expectEqual(@as(f32, 0.25), animation.speed);
    try std.testing.expectEqual(Direction.forward, animation.direction);
}

test "upper reflection preserves overshoot and reverses continuously" {
    var animation = AnimationState{
        .phase = PHASE_LIMIT - 0.001,
        .speed = 0.25,
        .direction = .forward,
    };
    animation.advance(1);
    try std.testing.expectEqual(Direction.backward, animation.direction);
    try std.testing.expectApproxEqAbs(
        PHASE_LIMIT - 0.0015,
        animation.phase,
        1e-12,
    );
}

test "lower reflection preserves overshoot and reverses continuously" {
    var animation = AnimationState{
        .phase = 0.001,
        .speed = 0.25,
        .direction = .backward,
    };

    animation.advance(1);

    try std.testing.expectEqual(Direction.forward, animation.direction);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0015), animation.phase, 1e-12);
}

test "exact endpoints normalize direction deterministically" {
    var upper = AnimationState{
        .phase = PHASE_LIMIT - 0.01,
        .speed = 1.0,
        .direction = .forward,
    };
    upper.advance(1);
    try std.testing.expectEqual(PHASE_LIMIT, upper.phase);
    try std.testing.expectEqual(Direction.backward, upper.direction);

    var lower = AnimationState{
        .phase = 0.01,
        .speed = 1.0,
        .direction = .backward,
    };
    lower.advance(1);
    try std.testing.expectEqual(@as(f64, 0.0), lower.phase);
    try std.testing.expectEqual(Direction.forward, lower.direction);
}

test "one advance can cross multiple endpoints" {
    var animation = AnimationState.init(1.0);

    animation.advance(6_553_700);

    try std.testing.expectApproxEqAbs(@as(f64, 1.0), animation.phase, 1e-12);
    try std.testing.expectEqual(Direction.forward, animation.direction);
}

test "maximum expiration count remains bounded" {
    var animation = AnimationState{
        .phase = PHASE_LIMIT - 7.0,
        .speed = 2.5,
        .direction = .backward,
    };

    animation.advance(std.math.maxInt(u64));

    try std.testing.expect(std.math.isFinite(animation.phase));
    try std.testing.expect(animation.phase >= 0.0);
    try std.testing.expect(animation.phase <= PHASE_LIMIT);
}

test "repeated advances remain bounded and endpoint directions stay canonical" {
    var animation = AnimationState.init(2.5);
    const expiration_counts = [_]u64{
        1,
        17,
        1_000,
        6_553_700,
        std.math.maxInt(u32),
        std.math.maxInt(u64),
    };

    for (0..1_000) |index| {
        animation.advance(expiration_counts[index % expiration_counts.len]);
        try std.testing.expect(std.math.isFinite(animation.phase));
        try std.testing.expect(animation.phase >= 0.0);
        try std.testing.expect(animation.phase <= PHASE_LIMIT);
        if (animation.phase == 0.0) {
            try std.testing.expectEqual(Direction.forward, animation.direction);
        } else if (animation.phase == PHASE_LIMIT) {
            try std.testing.expectEqual(Direction.backward, animation.direction);
        }
    }
}

test "minimum-speed f32 time changes near the upper endpoint" {
    var animation = AnimationState{
        .phase = PHASE_LIMIT - 0.01,
        .speed = 0.25,
        .direction = .forward,
    };
    const first = animation.time();
    animation.advance(1);
    const second = animation.time();
    try std.testing.expect(first != second);
}
