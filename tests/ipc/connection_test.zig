const std = @import("std");
const ipc = @import("ipc");
const connection = ipc.connection;
const posix = std.posix;
const linux = std.os.linux;
const sys = ipc.sys;

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

fn socketPair() ![2]posix.fd_t {
    var fds: [2]posix.fd_t = undefined;
    const rc = linux.socketpair(
        posix.AF.UNIX,
        posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
        0,
        &fds,
    );
    if (linux.errno(rc) != .SUCCESS) return error.TestSocketPairFailed;
    return fds;
}

fn sendExact(fd: posix.fd_t, bytes: []const u8) !void {
    const sent = try sys.sendNoSignal(fd, bytes);
    try std.testing.expectEqual(bytes.len, sent);
}

fn fillUntilWouldBlock(fd: posix.fd_t) !void {
    const filler = [_]u8{0xa5} ** 4096;
    for (0..4096) |_| {
        _ = sys.sendNoSignal(fd, &filler) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };
    }
    return error.TestSocketDidNotSaturate;
}

fn drainUntilWouldBlock(fd: posix.fd_t) !void {
    var buf: [8192]u8 = undefined;
    for (0..4096) |_| {
        const n = posix.read(fd, &buf) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };
        if (n == 0) return;
    }
    return error.TestSocketDidNotDrain;
}

test "connection reads fragmented request without resetting deadline" {
    const fds = try socketPair();
    var client = connection.IpcConnection.init(fds[0], 100);
    defer _ = client.close();
    defer sys.close(fds[1]);
    const request_deadline = 100 + connection.PHASE_TIMEOUT_NS;
    try std.testing.expectEqual(request_deadline, client.deadlineNs());

    try sendExact(fds[1], "que");
    try std.testing.expect(try client.readReady() == .incomplete);
    try std.testing.expectEqual(request_deadline, client.deadlineNs());
    try sendExact(fds[1], "ry\n");
    switch (try client.readReady()) {
        .complete => |line| try std.testing.expectEqualStrings("query", line),
        else => return error.TestExpectedComplete,
    }
}

test "connection never dispatches a partial request at EOF" {
    const fds = try socketPair();
    var client = connection.IpcConnection.init(fds[0], 100);
    defer _ = client.close();
    var peer_fd: ?posix.fd_t = fds[1];
    defer if (peer_fd) |fd| sys.close(fd);

    try sendExact(peer_fd.?, "que");
    try std.testing.expect(try client.readReady() == .incomplete);
    sys.close(peer_fd.?);
    peer_fd = null;
    try std.testing.expect(try client.readReady() == .peer_closed);
}

test "writing resets deadline and preserves stop through pending flush" {
    const fds = try socketPair();
    var client = connection.IpcConnection.init(fds[0], 100);
    defer _ = client.close();
    defer sys.close(fds[1]);
    try fillUntilWouldBlock(client.fd);

    client.response.appendLine("ok");
    client.beginWriting(500, true);
    const response_deadline = 500 + connection.PHASE_TIMEOUT_NS;
    try std.testing.expectEqual(response_deadline, client.deadlineNs());
    try std.testing.expect(!client.expired(response_deadline - 1));
    try std.testing.expect(client.expired(response_deadline));
    try std.testing.expect(try client.flushReady() == .pending);
    try std.testing.expectEqual(@as(usize, 0), client.response.sent_offset);
    try std.testing.expect(client.shutdown_after_flush);

    try drainUntilWouldBlock(fds[1]);
    try std.testing.expect(try client.flushReady() == .complete);
    var reply: [3]u8 = undefined;
    const n = try posix.read(fds[1], &reply);
    try std.testing.expectEqualStrings("ok\n", reply[0..n]);
    try std.testing.expect(client.close());
}

test "connection poll interest follows its state" {
    const fds = try socketPair();
    var client = connection.IpcConnection.init(fds[0], 100);
    defer _ = client.close();
    defer sys.close(fds[1]);

    try std.testing.expectEqual(linux.POLL.IN, client.pollEvents());
    client.response.appendLine("ok");
    client.beginWriting(500, false);
    try std.testing.expectEqual(linux.POLL.OUT, client.pollEvents());
    try std.testing.expect(!client.close());
    try std.testing.expectEqual(@as(i16, 0), client.pollEvents());
}

test "response deadline closure retains stop disposition" {
    const fds = try socketPair();
    var client = connection.IpcConnection.init(fds[0], 100);
    defer _ = client.close();
    defer sys.close(fds[1]);
    client.response.appendLine("ok");
    client.beginWriting(500, true);
    const deadline = client.deadlineNs();

    try std.testing.expect(client.expired(deadline));
    try std.testing.expect(client.close());
}

test "terminal response failure retains stop disposition" {
    const fds = try socketPair();
    var client = connection.IpcConnection.init(fds[0], 100);
    defer _ = client.close();
    var peer_fd: ?posix.fd_t = fds[1];
    defer if (peer_fd) |fd| sys.close(fd);
    client.response.appendLine("ok");
    client.beginWriting(500, true);
    sys.close(peer_fd.?);
    peer_fd = null;

    if (client.flushReady()) |_| {
        return error.TestExpectedTerminalWriteError;
    } else |err| switch (err) {
        error.BrokenPipe, error.ConnectionResetByPeer, error.SocketNotConnected => {},
        else => return err,
    }
    try std.testing.expect(client.close());
}

test "normal connection close does not request shutdown" {
    const fds = try socketPair();
    var client = connection.IpcConnection.init(fds[0], 100);
    defer _ = client.close();
    defer sys.close(fds[1]);
    try std.testing.expect(!client.close());
}

fn sigpipeChild() noreturn {
    const action: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.PIPE, &action, null);
    var mask = posix.sigemptyset();
    posix.sigaddset(&mask, .PIPE);
    posix.sigprocmask(posix.SIG.UNBLOCK, &mask, null);

    const fds = socketPair() catch linux.exit(10);
    sys.close(fds[1]);
    _ = sys.sendNoSignal(fds[0], "x") catch |err| {
        sys.close(fds[0]);
        linux.exit(if (err == error.BrokenPipe) 0 else 11);
    };
    sys.close(fds[0]);
    linux.exit(12);
}

test "sendNoSignal survives a closed peer with default SIGPIPE behavior" {
    const fork_rc = linux.fork();
    if (linux.errno(fork_rc) != .SUCCESS) return error.TestForkFailed;
    if (fork_rc == 0) sigpipeChild();

    var status: u32 = 0;
    while (true) {
        const wait_rc = linux.waitpid(@intCast(fork_rc), &status, 0);
        switch (linux.errno(wait_rc)) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.TestWaitFailed,
        }
    }
    try std.testing.expect(posix.W.IFEXITED(status));
    try std.testing.expectEqual(@as(u8, 0), posix.W.EXITSTATUS(status));
}

test "dispatch response helpers build the query wire format" {
    var out = ipc.connection.ResponseQueue{};
    ipc.dispatch.appendKv(&out, "effect", "colormix");
    ipc.dispatch.appendKv(&out, "fps", "15");
    ipc.dispatch.appendKv(&out, "scale", "0.50");
    ipc.dispatch.appendKv(&out, "palette", "custom");
    ipc.dispatch.appendOk(&out);
    try std.testing.expectEqualStrings(
        "effect=colormix\nfps=15\nscale=0.50\npalette=custom\nok\n",
        out.pending(),
    );
}

test "dispatch unexpected argument response is bounded" {
    var out = ipc.connection.ResponseQueue{};
    ipc.dispatch.appendUnexpectedArgument(&out, "query");
    try std.testing.expectEqualStrings(
        "error: query does not accept arguments\n",
        out.pending(),
    );
}
