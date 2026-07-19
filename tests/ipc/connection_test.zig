const std = @import("std");
const ipc = @import("ipc");
const connection = ipc.connection;

fn expectComplete(
    result: connection.FeedResult,
    expected: []const u8,
) !void {
    switch (result) {
        .complete => |line| try std.testing.expectEqualStrings(expected, line),
        else => return error.TestExpectedComplete,
    }
}

test "request accumulator completes at every split boundary" {
    const wire = "set-fps 60\n";
    for (0..wire.len + 1) |split| {
        var request = connection.RequestAccumulator{};
        const first = request.feed(wire[0..split]);
        if (split == wire.len) {
            try expectComplete(first, "set-fps 60");
        } else {
            try std.testing.expect(first == .incomplete);
            try expectComplete(request.feed(wire[split..]), "set-fps 60");
        }
    }
}

test "request accumulator accepts bytewise fragmentation" {
    const wire = "query\n";
    var request = connection.RequestAccumulator{};
    for (wire[0 .. wire.len - 1]) |byte| {
        const one = [1]u8{byte};
        try std.testing.expect(request.feed(&one) == .incomplete);
    }
    try expectComplete(request.feed(wire[wire.len - 1 ..]), "query");
}

test "request accumulator trims CRLF" {
    var request = connection.RequestAccumulator{};
    try expectComplete(request.feed("query\r\n"), "query");
}

test "request accumulator accepts the exact 4096 byte wire limit" {
    var wire: [connection.REQUEST_MAX]u8 = @splat('a');
    wire[wire.len - 1] = '\n';
    var request = connection.RequestAccumulator{};
    switch (request.feed(&wire)) {
        .complete => |line| try std.testing.expectEqual(wire.len - 1, line.len),
        else => return error.TestExpectedComplete,
    }
}

test "request accumulator rejects 4096 payload bytes without newline" {
    const wire = [_]u8{'a'} ** connection.REQUEST_MAX;
    var request = connection.RequestAccumulator{};
    try std.testing.expect(request.feed(&wire) == .line_too_long);
}

test "request accumulator rejects buffered bytes after newline" {
    var request = connection.RequestAccumulator{};
    try std.testing.expect(request.feed("query\nstop\n") == .extra_data);
}

test "request accumulator rejects a second command after completion" {
    var request = connection.RequestAccumulator{};
    try expectComplete(request.feed("query\n"), "query");
    try std.testing.expect(request.feed("stop\n") == .extra_data);
}

test "request accumulator keeps empty input incomplete" {
    var request = connection.RequestAccumulator{};
    try std.testing.expect(request.feed("") == .incomplete);
}

test "response queue preserves bytes across partial consumption" {
    var response = connection.ResponseQueue{};
    response.appendLine("effect=colormix");
    response.appendLine("fps=15");
    response.appendLine("ok");
    const expected = "effect=colormix\nfps=15\nok\n";
    var observed: [expected.len]u8 = undefined;
    var observed_len: usize = 0;
    const chunks = [_]usize{ 1, 2, 5, 3, 8 };
    var chunk_index: usize = 0;
    while (!response.isComplete()) : (chunk_index += 1) {
        const pending = response.pending();
        const count = @min(chunks[chunk_index % chunks.len], pending.len);
        @memcpy(observed[observed_len .. observed_len + count], pending[0..count]);
        observed_len += count;
        try response.consume(count);
    }
    try std.testing.expectEqualStrings(expected, observed[0..observed_len]);
}

test "response queue rejects invalid write progress" {
    var response = connection.ResponseQueue{};
    response.appendLine("ok");
    try std.testing.expectError(
        error.InvalidWriteCount,
        response.consume(response.pending().len + 1),
    );
}

test "response queue fails closed on overflow" {
    var response = connection.ResponseQueue{};
    const oversized = [_]u8{'x'} ** connection.RESPONSE_MAX;
    response.appendLine(&oversized);
    response.appendLine("ok");
    try std.testing.expectEqualStrings("error: internal\n", response.pending());
}

test "response queue never rewinds after partial transmission" {
    var response = connection.ResponseQueue{};
    response.appendLine("ok");
    try response.consume(1);
    const oversized = [_]u8{'x'} ** connection.RESPONSE_MAX;
    response.appendLine(&oversized);
    try std.testing.expect(response.failed_closed);
    try std.testing.expect(response.isComplete());
}

test "deadline arithmetic is saturating and expires at equality" {
    const start: u64 = 123;
    const deadline = connection.deadlineAfter(start);
    try std.testing.expectEqual(start + connection.PHASE_TIMEOUT_NS, deadline);
    try std.testing.expect(!connection.deadlineExpired(deadline - 1, deadline));
    try std.testing.expect(connection.deadlineExpired(deadline, deadline));
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        connection.deadlineAfter(std.math.maxInt(u64)),
    );
}

test "poll timeout rounds up without extending exact milliseconds" {
    const deadline = 10 * std.time.ns_per_ms;
    try std.testing.expectEqual(@as(i32, 0), connection.pollTimeoutMs(deadline, deadline));
    try std.testing.expectEqual(@as(i32, 1), connection.pollTimeoutMs(deadline - 1, deadline));
    try std.testing.expectEqual(@as(i32, 5), connection.pollTimeoutMs(5 * std.time.ns_per_ms, deadline));
}
