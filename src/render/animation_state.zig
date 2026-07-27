const std = @import("std");
const builtin = @import("builtin");
const defaults = @import("../config/defaults.zig");

pub const PHASE_LIMIT: f64 = 16_384.0;
const CYCLE_LENGTH: f64 = PHASE_LIMIT * 2.0;

// Keep accumulation at the mathematical 0.01; widening the f32 config
// constant would introduce up to about 5.59e-10 error at speed 2.5.
const time_scale: f64 = 0.01;
const fold_time_scale: f128 = 0.01;
comptime {
    std.debug.assert(@as(f32, @floatCast(time_scale)) == defaults.TIME_SCALE);
}

pub const Direction = enum { forward, backward };

pub const AnimationState = struct {
    phase: f64 = 0.0,
    speed: f32,
    direction: Direction = .forward,

    pub fn init(speed: f32) AnimationState {
        return .{ .speed = speed };
    }

    pub fn reset(self: *AnimationState, speed: f32) void {
        self.* = init(speed);
    }

    pub fn setSpeed(self: *AnimationState, speed: f32) void {
        self.speed = speed;
    }

    pub fn time(self: *const AnimationState) f32 {
        return @floatCast(self.phase);
    }

    pub fn advance(self: *AnimationState, expirations: u64) void {
        self.assertValid();
        if (expirations == 0) return;

        const step = time_scale * @as(f64, self.speed) *
            @as(f64, @floatFromInt(expirations));
        const distance = switch (self.direction) {
            .forward => PHASE_LIMIT - self.phase,
            .backward => self.phase,
        };

        // This is the common path and deliberately avoids modulo/division.
        if (step <= distance) {
            self.phase += switch (self.direction) {
                .forward => step,
                .backward => -step,
            };
            self.normalizeEndpoint();
            self.assertValid();
            return;
        }

        // Handle one reflection directly so small overshoots do not lose
        // sub-ulp detail by being added near CYCLE_LENGTH.
        const overshoot = step - distance;
        if (overshoot <= PHASE_LIMIT) {
            switch (self.direction) {
                .forward => {
                    self.phase = PHASE_LIMIT - overshoot;
                    self.direction = .backward;
                },
                .backward => {
                    self.phase = overshoot;
                    self.direction = .forward;
                },
            }
            self.normalizeEndpoint();
            self.assertValid();
            return;
        }

        switch (self.direction) {
            .forward => {
                self.phase = PHASE_LIMIT;
                self.direction = .backward;
            },
            .backward => {
                self.phase = 0.0;
                self.direction = .forward;
            },
        }
        self.fold(expirations, distance);
        self.assertValid();
    }

    fn fold(self: *AnimationState, expirations: u64, first_distance: f64) void {
        const step: f128 = fold_time_scale * @as(f128, self.speed) *
            @as(f128, @floatFromInt(expirations)) - @as(f128, first_distance);
        const position: f128 = switch (self.direction) {
            .forward => self.phase,
            .backward => CYCLE_LENGTH - self.phase,
        };
        const folded = @mod(position + step, @as(f128, CYCLE_LENGTH));

        if (folded < @as(f128, PHASE_LIMIT)) {
            self.phase = @floatCast(folded);
            self.direction = .forward;
        } else if (folded == @as(f128, PHASE_LIMIT)) {
            self.phase = PHASE_LIMIT;
            self.direction = .backward;
        } else {
            self.phase = @floatCast(@as(f128, CYCLE_LENGTH) - folded);
            self.direction = .backward;
        }
    }

    fn normalizeEndpoint(self: *AnimationState) void {
        if (self.phase == 0.0) self.direction = .forward;
        if (self.phase == PHASE_LIMIT) self.direction = .backward;
    }

    fn assertValid(self: *const AnimationState) void {
        if (builtin.mode == .Debug) {
            std.debug.assert(std.math.isFinite(self.phase));
            std.debug.assert(self.phase >= 0.0 and self.phase <= PHASE_LIMIT);
            if (self.phase == 0.0) std.debug.assert(self.direction == .forward);
            if (self.phase == PHASE_LIMIT) std.debug.assert(self.direction == .backward);
        }
    }
};
