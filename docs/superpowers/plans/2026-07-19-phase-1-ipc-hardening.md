# Phase 1 IPC Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close `IPC-H1`, `IPC-H2`, `IPC-M1`, `IPC-L1`, `IPC-L2`, `IPC-L3`, and `APP-L1` without changing successful command semantics or blocking the Wayland/render loop on client socket behavior.

**Architecture:** Keep one active IPC client in a fixed-size `IpcConnection` state machine. Poll either the nonblocking listener or that client, enforce independent 500 ms absolute request and response deadlines, build replies in a fixed 1024-byte queue, and flush with nonblocking `MSG_NOSIGNAL` sends. Hold a persistent advisory lock before touching the socket path. Isolate signalfd decoding behind an exact-record reader.

**Tech Stack:** Zig 0.16.0, Linux raw syscalls through `src/sys.zig`, `std.posix.poll`, Unix-domain sockets, `flock(2)`, `signalfd(2)`, Wayland client APIs, and the existing Zig build/test graph.

## Global Constraints

- Work from the approved design at `docs/design/2026-07-19-ipc-hardening-design.md` and update the master ledger at `docs/security/2026-07-19-security-performance-audit.md` only after verification.
- Use test-first red/green cycles. Do not commit a state in which `zig build test --summary all` fails.
- Preserve the one-command-per-connection protocol and all successful response text.
- Do not allocate per connection or per event-loop iteration.
- Never retry a socket read or write after `WouldBlock` without returning to `poll`.
- Use checked or saturating arithmetic for lengths and deadlines.
- Treat failure to read `CLOCK_MONOTONIC` as a reason to close the active client; a silent zero timestamp must not disable the deadline.
- Do not run `wlchroma-ctl stop`, disable an output, or replace a live daemon without explicit user coordination. Any later output-off test requires a recovery watchdog.
- Keep unrelated user changes untouched.

---

## Completion Contract

Phase 1 is complete only when all of the following are true:

- A fragmented or slow client never executes a blocking socket operation on the render thread.
- The request limit is exactly 4096 bytes including newline.
- A response is either fully flushed, remains queued for `POLLOUT`, or is terminated safely; it is never silently truncated.
- Closing the peer before a response cannot deliver `SIGPIPE` to wlchroma.
- A second daemon receives `error.AlreadyRunning` before the live socket pathname is touched.
- `stop` exits only after full response flush or a terminal response failure/deadline.
- Short/error signalfd reads never expose undefined bytes.
- Debug, ReleaseSafe, and ReleaseFast builds and tests pass.
- Each mapped audit row records its fixing commit and verification evidence.

## Intended File Map

| File | Action |
|---|---|
| `src/ipc/connection.zig` | Create bounded request, response, deadline, and client-I/O state. |
| `src/ipc/server.zig` | Refocus on singleton lock, listener ownership, and nonblocking accept. |
| `src/ipc/dispatch.zig` | Enforce arity and append responses to a queue instead of writing fds. |
| `src/signal_fd.zig` | Create exact-size signalfd record reader. |
| `src/sys.zig` | Add errno-preserving lock, send, mode, and checked-clock wrappers. |
| `src/app.zig` | Integrate the active client into poll and convert handlers to queued replies. |
| `src/test_ipc_exports.zig` | Export Phase 1 internals through the existing source-root test shim. |
| `tests/ipc/protocol_test.zig` | Add no-argument command arity regressions. |
| `tests/ipc/connection_test.zig` | Add framing, queue, deadlines, and socket-state tests. |
| `tests/ipc/server_test.zig` | Add lock ownership, stale socket, and fd-flag tests. |
| `tests/ipc/signal_fd_test.zig` | Add exact, short, EOF, and would-block read tests. |
| `build.zig` | Add a focused `test-ipc` step and new test artifacts. |
| `docs/design/2026-07-19-ipc-hardening-design.md` | Mark implemented after final verification. |
| `docs/security/2026-07-19-security-performance-audit.md` | Close the seven Phase 1 ledger rows with evidence. |

## Task 0: Establish the implementation baseline

**Files:** None.

**Interfaces:**

- Consumes: the committed audit, approved design, Zig 0.16.0 toolchain, and current Debug test graph.
- Produces: an isolated branch/worktree whose base commit contains all three planning documents and passes the 54-test baseline.

- [ ] Create an isolated worktree/branch using `superpowers:using-git-worktrees` before changing production code.
- [ ] Confirm the worktree begins at a commit containing this plan file, the approved audit, and the approved design. `c67a0c9` alone is insufficient because it predates this plan.
- [ ] Run the exact baseline checks:

```sh
git status --short --branch
git log -1 --oneline -- docs/superpowers/plans/2026-07-19-phase-1-ipc-hardening.md
zig version
zig fmt --check build.zig src tests
zig build --summary all
zig build test --summary all
```

Expected: the log command resolves a commit for this plan; Zig reports `0.16.0`; formatting passes; Debug build passes; the unmodified baseline reports `54/54 tests passed`; no unrelated paths are modified.

- [ ] If the baseline differs, stop and diagnose it with `superpowers:systematic-debugging` before continuing.

## Task 1: Reject arguments to no-argument commands

**Audit row:** `IPC-L3`

**Files:**

- Modify: `tests/ipc/protocol_test.zig`
- Modify: `src/ipc/dispatch.zig`
- Modify: `src/app.zig`
- Modify: `build.zig`

**Interfaces:**

- Consumes: `dispatch.parseLine(line: []const u8)` and the existing synchronous `App.handleIpcEvent` compatibility path.
- Produces: `ParseError.UnexpectedArgument`, strict `reload`/`query`/`stop` arity, and a `test-ipc` build step used by every later task.

- [ ] Add a focused build step next to the existing IPC test artifact:

```zig
const ipc_test_step = b.step("test-ipc", "Run IPC hardening tests");
ipc_test_step.dependOn(&run_ipc_tests.step);
```

Keep the existing global `test_step.dependOn(&run_ipc_tests.step)` dependency.

- [ ] Add these failing parser tests:

```zig
test "parseLine: reload rejects trailing argument" {
    try std.testing.expectError(error.UnexpectedArgument, parseLine("reload now"));
}

test "parseLine: query rejects trailing argument" {
    try std.testing.expectError(error.UnexpectedArgument, parseLine("query verbose"));
}

test "parseLine: stop rejects trailing argument" {
    try std.testing.expectError(error.UnexpectedArgument, parseLine("stop now"));
}
```

- [ ] Run the red test:

```sh
zig build test-ipc --summary all
```

Expected: the three named tests fail because the parser currently ignores `rest`.

- [ ] Add `UnexpectedArgument` to `ParseError`, then change the three branches exactly as follows:

```zig
if (std.mem.eql(u8, verb, "reload")) {
    if (rest.len != 0) return error.UnexpectedArgument;
    return .reload;
} else if (std.mem.eql(u8, verb, "query")) {
    if (rest.len != 0) return error.UnexpectedArgument;
    return .query;
} else if (std.mem.eql(u8, verb, "stop")) {
    if (rest.len != 0) return error.UnexpectedArgument;
    return .stop;
}
```

Trailing whitespace still succeeds because `parseLine` trims the whole input before deriving `rest`.

- [ ] Until Task 6 removes direct writes, add this temporary exhaustive branch to the current parse-error switch in `App.handleIpcEvent`. Do not classify it as a numeric error:

```zig
error.UnexpectedArgument => {
    const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
    const space = std.mem.indexOfScalar(u8, trimmed, ' ');
    const verb = if (space) |index| trimmed[0..index] else trimmed;
    var buf: [96]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "{s} does not accept arguments",
        .{verb},
    ) catch "command does not accept arguments";
    dispatch.writeError(client_fd, msg);
    return;
},
```
- [ ] Run green and regression checks:

```sh
zig build test-ipc --summary all
zig build test --summary all
```

Expected: all IPC and project tests pass.

- [ ] Commit:

```sh
git add build.zig src/ipc/dispatch.zig src/app.zig tests/ipc/protocol_test.zig
git commit -m "fix(ipc): reject arguments to no-arg commands"
```

## Task 2: Add bounded framing, response, and deadline primitives

**Audit rows:** Foundation for `IPC-H2`, `IPC-L1`, and `IPC-L2`

**Files:**

- Create: `src/ipc/connection.zig`
- Create: `tests/ipc/connection_test.zig`
- Modify: `src/test_ipc_exports.zig`
- Modify: `build.zig`

**Interfaces:**

- Consumes: the `ipc` source-root test shim and the focused `test-ipc` step from Task 1.
- Produces: `RequestAccumulator.feed([]const u8) FeedResult`, `ResponseQueue.appendLine/pending/consume/isComplete/failInternal`, and `deadlineAfter`, `deadlineExpired`, and `pollTimeoutMs` with fixed capacities and saturating deadlines.

- [ ] In `src/test_ipc_exports.zig`, replace the stale server-specific header comment, change the existing private `const dispatch` declaration to the public declaration below, and add `connection`. Leave the existing top-level `IpcCommand`, `ParseError`, `parseLine`, and `PALETTE_NAME_MAX` exports unchanged:

```zig
//! Source-root shim for out-of-tree IPC tests under tests/ipc/. Keeping the
//! module root at src/ allows IPC modules to use their production relative
//! imports while tests consume both the public parser and hardening internals.

pub const dispatch = @import("ipc/dispatch.zig");
pub const connection = @import("ipc/connection.zig");
```

- [ ] In the IPC-test section of `build.zig`, replace its stale comment with this durable description before adding the new artifact:

```zig
// IPC tests. The source-root shim keeps production-relative imports under
// src/ and receives the same "sys" module as the executable.
```

- [ ] Add `tests/ipc/connection_test.zig` as a separate test artifact importing the shim as `ipc`. Insert this complete build block after the existing protocol artifact so both test steps own it:

```zig
const ipc_connection_test_mod = b.createModule(.{
    .root_source_file = b.path("tests/ipc/connection_test.zig"),
    .target = target,
    .optimize = optimize,
});
ipc_connection_test_mod.addImport("ipc", ipc_dispatch_mod);
const ipc_connection_tests = b.addTest(.{
    .root_module = ipc_connection_test_mod,
});
const run_ipc_connection_tests = b.addRunArtifact(ipc_connection_tests);
test_step.dependOn(&run_ipc_connection_tests.step);
ipc_test_step.dependOn(&run_ipc_connection_tests.step);
```

- [ ] Create the test file with this complete initial content:

```zig
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
```

- [ ] Run the red test:

```sh
zig build test-ipc --summary all
```

Expected: compilation fails because `ipc/connection.zig` and its API do not exist.

- [ ] Create `src/ipc/connection.zig` with this complete pure-state implementation:

```zig
const std = @import("std");

pub const REQUEST_MAX: usize = 4096;
pub const RESPONSE_MAX: usize = 1024;
pub const PHASE_TIMEOUT_NS: u64 = 500 * std.time.ns_per_ms;

pub const FeedResult = union(enum) {
    incomplete,
    complete: []const u8,
    line_too_long,
    extra_data,
};

pub const RequestAccumulator = struct {
    bytes: [REQUEST_MAX]u8 = undefined,
    len: usize = 0,
    status: enum { reading, complete, rejected } = .reading,
    line_len: usize = 0,

    pub fn feed(self: *RequestAccumulator, chunk: []const u8) FeedResult {
        if (self.status != .reading) return .extra_data;

        if (std.mem.indexOfScalar(u8, chunk, '\n')) |newline_index| {
            const wire_len = newline_index + 1;
            const remaining = self.bytes.len - self.len;
            if (wire_len > remaining) {
                self.status = .rejected;
                return .line_too_long;
            }
            if (wire_len != chunk.len) {
                self.status = .rejected;
                return .extra_data;
            }

            @memcpy(self.bytes[self.len .. self.len + wire_len], chunk);
            self.len += wire_len;
            var end = self.len - 1;
            if (end > 0 and self.bytes[end - 1] == '\r') end -= 1;
            self.line_len = end;
            self.status = .complete;
            return .{ .complete = self.bytes[0..end] };
        }

        const remaining = self.bytes.len - self.len;
        if (chunk.len >= remaining) {
            self.status = .rejected;
            return .line_too_long;
        }
        @memcpy(self.bytes[self.len .. self.len + chunk.len], chunk);
        self.len += chunk.len;
        return .incomplete;
    }

    pub fn line(self: *const RequestAccumulator) []const u8 {
        std.debug.assert(self.status == .complete);
        return self.bytes[0..self.line_len];
    }
};

pub const ResponseQueue = struct {
    bytes: [RESPONSE_MAX]u8 = undefined,
    len: usize = 0,
    sent_offset: usize = 0,
    failed_closed: bool = false,

    pub fn appendLine(self: *ResponseQueue, line: []const u8) void {
        if (self.failed_closed) return;
        const remaining = self.bytes.len - self.len;
        if (line.len >= remaining) {
            self.failInternal();
            return;
        }
        @memcpy(self.bytes[self.len .. self.len + line.len], line);
        self.bytes[self.len + line.len] = '\n';
        self.len += line.len + 1;
    }

    pub fn pending(self: *const ResponseQueue) []const u8 {
        return self.bytes[self.sent_offset..self.len];
    }

    pub fn consume(self: *ResponseQueue, written: usize) error{InvalidWriteCount}!void {
        if (written > self.pending().len) return error.InvalidWriteCount;
        self.sent_offset += written;
    }

    pub fn isComplete(self: *const ResponseQueue) bool {
        return self.sent_offset == self.len;
    }

    pub fn failInternal(self: *ResponseQueue) void {
        if (self.sent_offset != 0) {
            self.len = self.sent_offset;
            self.failed_closed = true;
            return;
        }
        const internal = "error: internal\n";
        @memcpy(self.bytes[0..internal.len], internal);
        self.len = internal.len;
        self.sent_offset = 0;
        self.failed_closed = true;
    }
};

pub fn deadlineAfter(now_ns: u64) u64 {
    return now_ns +| PHASE_TIMEOUT_NS;
}

pub fn deadlineExpired(now_ns: u64, deadline_ns: u64) bool {
    return now_ns >= deadline_ns;
}

pub fn pollTimeoutMs(now_ns: u64, deadline_ns: u64) i32 {
    if (deadlineExpired(now_ns, deadline_ns)) return 0;
    const remaining_ns = deadline_ns - now_ns;
    const milliseconds = 1 + (remaining_ns - 1) / std.time.ns_per_ms;
    const max_timeout_ms: u64 = @intCast(std.math.maxInt(i32));
    return @intCast(@min(milliseconds, max_timeout_ms));
}
```
- [ ] Run green and full checks:

```sh
zig fmt --check src/ipc/connection.zig tests/ipc/connection_test.zig build.zig src/test_ipc_exports.zig
zig build test-ipc --summary all
zig build test --summary all
```

Expected: framing, queue, and injected-time tests pass with no sleeps.

- [ ] Commit:

```sh
git add build.zig src/ipc/connection.zig src/test_ipc_exports.zig tests/ipc/connection_test.zig
git commit -m "feat(ipc): add bounded connection primitives"
```

## Task 3: Enforce singleton ownership and atomic nonblocking fd flags

**Audit row:** `IPC-M1`; listener half of `IPC-H2`

**Files:**

- Modify: `src/sys.zig`
- Modify: `src/ipc/server.zig`
- Create: `tests/ipc/server_test.zig`
- Modify: `src/test_ipc_exports.zig`
- Modify: `build.zig`

**Interfaces:**

- Consumes: existing raw Linux wrappers in `src/sys.zig` and the focused test graph.
- Produces: `IpcServer.initAtRuntimeDir([]const u8)`, `socketPath() [:0]const u8`, `accept() sys.AcceptError!posix.fd_t`, persistent `lock_fd`, `sys.tryLockExclusive`, `sys.setFileMode`, and `sys.monotonicNsChecked`.

- [ ] Export `server` and `sys` from `src/test_ipc_exports.zig`:

```zig
pub const server = @import("ipc/server.zig");
pub const sys = @import("sys");
```

- [ ] Add the server artifact to both test steps:

```zig
const ipc_server_test_mod = b.createModule(.{
    .root_source_file = b.path("tests/ipc/server_test.zig"),
    .target = target,
    .optimize = optimize,
});
ipc_server_test_mod.addImport("ipc", ipc_dispatch_mod);
const ipc_server_tests = b.addTest(.{
    .root_module = ipc_server_test_mod,
});
const run_ipc_server_tests = b.addRunArtifact(ipc_server_tests);
test_step.dependOn(&run_ipc_server_tests.step);
ipc_test_step.dependOn(&run_ipc_server_tests.step);
```

- [ ] Create `tests/ipc/server_test.zig` with complete cleanup on every red and green path:

```zig
const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const ipc = @import("ipc");
const IpcServer = ipc.server.IpcServer;
const sys = ipc.sys;

fn runtimeDir(tmp: *std.testing.TmpDir, path_buf: []u8) ![]const u8 {
    const path_len = try tmp.dir.realPath(std.testing.io, path_buf);
    return path_buf[0..path_len];
}

fn expectNonblocking(fd: posix.fd_t) !void {
    const rc = linux.fcntl(fd, linux.F.GETFL, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
    const flags: linux.O = @bitCast(@as(u32, @intCast(rc)));
    try std.testing.expect(flags.NONBLOCK);
}

fn expectCloseOnExec(fd: posix.fd_t) !void {
    const rc = linux.fcntl(fd, linux.F.GETFD, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
    try std.testing.expect(rc & linux.FD_CLOEXEC != 0);
}

fn connectTo(path: [:0]const u8) !posix.fd_t {
    const fd = try sys.socket(
        posix.AF.UNIX,
        posix.SOCK.STREAM | posix.SOCK.CLOEXEC,
        0,
    );
    errdefer sys.close(fd);
    var addr = std.mem.zeroes(posix.sockaddr.un);
    addr.family = posix.AF.UNIX;
    if (path.len >= addr.path.len) return error.TestPathTooLong;
    @memcpy(addr.path[0..path.len], path);
    const rc = linux.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
    if (linux.errno(rc) != .SUCCESS) return error.TestConnectFailed;
    return fd;
}

test "server listener and lock have atomic fd flags" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const runtime_dir = try runtimeDir(&tmp, &path_buf);
    var server = try IpcServer.initAtRuntimeDir(runtime_dir);
    defer server.deinit();

    try expectNonblocking(server.fd);
    try expectCloseOnExec(server.fd);
    try expectCloseOnExec(server.lock_fd);
    try std.testing.expectError(error.WouldBlock, server.accept());

    const stat = try tmp.dir.statFile(std.testing.io, "wlchroma.lock", .{});
    try std.testing.expectEqual(
        @as(posix.mode_t, 0o600),
        stat.permissions.toMode() & 0o777,
    );
}

test "second server cannot replace the first socket and clean restart works" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const runtime_dir = try runtimeDir(&tmp, &path_buf);

    {
        var first = try IpcServer.initAtRuntimeDir(runtime_dir);
        defer first.deinit();
        if (IpcServer.initAtRuntimeDir(runtime_dir)) |unexpected_value| {
            var unexpected = unexpected_value;
            unexpected.deinit();
            return error.TestExpectedAlreadyRunning;
        } else |err| {
            try std.testing.expect(err == error.AlreadyRunning);
        }
        const client_fd = try connectTo(first.socketPath());
        sys.close(client_fd);
    }

    var restarted = try IpcServer.initAtRuntimeDir(runtime_dir);
    defer restarted.deinit();
    const client_fd = try connectTo(restarted.socketPath());
    sys.close(client_fd);
}

test "server replaces a stale socket when no lock is held" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const runtime_dir = try runtimeDir(&tmp, &path_buf);

    const crashed = try IpcServer.initAtRuntimeDir(runtime_dir);
    sys.close(crashed.fd);
    sys.close(crashed.lock_fd);

    var recovered = try IpcServer.initAtRuntimeDir(runtime_dir);
    defer recovered.deinit();
    const client_fd = try connectTo(recovered.socketPath());
    sys.close(client_fd);
}
```

The first test checks `O_NONBLOCK` before empty accept, so the red run cannot block. The rejected second server is explicitly deinitialized if old behavior unexpectedly succeeds, so the red run does not leak or steal the fixture socket.

- [ ] Run the red test:

```sh
zig build test-ipc --summary all
```

Expected: compilation fails on the missing `initAtRuntimeDir`, lock ownership, and specific accept error behavior.

- [ ] Replace `accept4` and `monotonicNs` (including the old `monotonicNs` doc comment), and add the lock/mode helpers in `src/sys.zig`, using this complete code:

```zig
pub const AcceptError = error{
    WouldBlock,
    ConnectionAborted,
    AcceptFailed,
};

pub fn accept4(fd: fd_t, flags: u32) AcceptError!fd_t {
    while (true) {
        const rc = linux.accept4(fd, null, null, flags);
        switch (linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .CONNABORTED => return error.ConnectionAborted,
            else => return error.AcceptFailed,
        }
    }
}

pub fn tryLockExclusive(fd: fd_t) error{ AlreadyRunning, LockFailed }!void {
    while (true) {
        const rc = linux.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB);
        switch (linux.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            .AGAIN => return error.AlreadyRunning,
            else => return error.LockFailed,
        }
    }
}

pub fn setFileMode(fd: fd_t, mode: std.posix.mode_t) error{SetFileModeFailed}!void {
    while (true) {
        switch (linux.errno(linux.fchmod(fd, mode))) {
            .SUCCESS => return,
            .INTR => continue,
            else => return error.SetFileModeFailed,
        }
    }
}

/// Checked CLOCK_MONOTONIC nanoseconds for correctness-sensitive deadlines.
pub fn monotonicNsChecked() error{ClockGetTimeFailed}!u64 {
    var ts: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.MONOTONIC, &ts)) != .SUCCESS) {
        return error.ClockGetTimeFailed;
    }
    if (ts.sec < 0 or ts.nsec < 0 or ts.nsec >= std.time.ns_per_s) {
        return error.ClockGetTimeFailed;
    }
    const seconds: u64 = @intCast(ts.sec);
    const nanoseconds: u64 = @intCast(ts.nsec);
    const base = std.math.mul(u64, seconds, std.time.ns_per_s) catch
        return error.ClockGetTimeFailed;
    return std.math.add(u64, base, nanoseconds) catch
        return error.ClockGetTimeFailed;
}

/// Best-effort timestamp retained for performance logging and animation code.
pub fn monotonicNs() u64 {
    return monotonicNsChecked() catch 0;
}
```

- [ ] Replace the hand-written `SOCK_PATH_MAX` with the ABI-derived `SUN_PATH_BYTES`, add `lock_fd` to `IpcServer`, and replace its initialization, accept, path accessor, and teardown with this code. Keep the existing `readLine` and `writeLine` bodies only until Task 6:

```zig
const SUN_PATH_BYTES = @sizeOf(@FieldType(posix.sockaddr.un, "path"));

pub const IpcServer = struct {
    fd: posix.fd_t,
    lock_fd: posix.fd_t,
    path_buf: [SUN_PATH_BYTES]u8,
    path_len: usize,

    pub fn init(environ: std.process.Environ) !IpcServer {
        const runtime_dir = environ.getPosix("XDG_RUNTIME_DIR") orelse
            return error.NoRuntimeDir;
        return initAtRuntimeDir(runtime_dir);
    }

    pub fn initAtRuntimeDir(runtime_dir: []const u8) !IpcServer {
        if (runtime_dir.len == 0) return error.NoRuntimeDir;

        var server = IpcServer{
            .fd = undefined,
            .lock_fd = undefined,
            .path_buf = std.mem.zeroes([SUN_PATH_BYTES]u8),
            .path_len = 0,
        };
        const socket_path = std.fmt.bufPrintZ(
            &server.path_buf,
            "{s}/wlchroma.sock",
            .{runtime_dir},
        ) catch return error.PathTooLong;
        server.path_len = socket_path.len;

        var lock_path_buf = std.mem.zeroes([SUN_PATH_BYTES]u8);
        const lock_path = std.fmt.bufPrintZ(
            &lock_path_buf,
            "{s}/wlchroma.lock",
            .{runtime_dir},
        ) catch return error.PathTooLong;
        const lock_fd = try posix.openatZ(
            posix.AT.FDCWD,
            lock_path.ptr,
            .{
                .ACCMODE = .RDWR,
                .CREAT = true,
                .CLOEXEC = true,
                .NOFOLLOW = true,
            },
            @as(posix.mode_t, 0o600),
        );
        errdefer sys.close(lock_fd);
        try sys.setFileMode(lock_fd, 0o600);
        try sys.tryLockExclusive(lock_fd);

        sys.unlinkZ(socket_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        const fd = try sys.socket(
            posix.AF.UNIX,
            posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
            0,
        );
        var bound = false;
        errdefer {
            sys.close(fd);
            if (bound) sys.unlinkZ(socket_path) catch {};
        }

        var addr = std.mem.zeroes(posix.sockaddr.un);
        addr.family = posix.AF.UNIX;
        if (socket_path.len >= addr.path.len) return error.PathTooLong;
        @memcpy(addr.path[0..socket_path.len], socket_path);
        try sys.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
        bound = true;
        try sys.listen(fd, 8);

        server.fd = fd;
        server.lock_fd = lock_fd;
        return server;
    }

    pub fn socketPath(self: *const IpcServer) [:0]const u8 {
        return self.path_buf[0..self.path_len :0];
    }

    pub fn accept(self: *IpcServer) sys.AcceptError!posix.fd_t {
        const client_fd = try sys.accept4(self.fd, posix.SOCK.CLOEXEC);
        const timeout = posix.timeval{ .sec = 0, .usec = 200_000 };
        posix.setsockopt(
            client_fd,
            posix.SOL.SOCKET,
            posix.SO.RCVTIMEO,
            std.mem.asBytes(&timeout),
        ) catch {};
        return client_fd;
    }

    pub fn deinit(self: *IpcServer) void {
        sys.close(self.fd);
        sys.unlinkZ(self.socketPath()) catch {};
        sys.close(self.lock_fd);
    }

    pub fn readLine(fd: posix.fd_t, buf: []u8) ![]u8 {
        var filled: usize = 0;
        while (filled < buf.len) {
            const n = posix.read(fd, buf[filled..]) catch |err| switch (err) {
                error.WouldBlock => return error.ConnectionClosed,
                else => return err,
            };
            if (n == 0) return error.ConnectionClosed;
            filled += n;
            for (buf[filled - n .. filled], filled - n..) |ch, i| {
                if (ch == '\n') {
                    const end = if (i > 0 and buf[i - 1] == '\r') i - 1 else i;
                    return buf[0..end];
                }
            }
        }
        return error.LineTooLong;
    }

    pub fn writeLine(fd: posix.fd_t, line: []const u8) void {
        const iov = [2]posix.iovec_const{
            .{ .base = line.ptr, .len = line.len },
            .{ .base = "\n", .len = 1 },
        };
        _ = sys.writev(fd, &iov) catch {};
    }
};
```

- [ ] Review the completed initializer against four invariants visible in the replacement: lock before socket unlink, persistent lock inode, `NONBLOCK | CLOEXEC` on the listener, and bind/listen cleanup while the lock remains held. Keep accepted clients blocking with the legacy receive timeout until Task 6 so this commit remains protocol-compatible and bisectable.
- [ ] Keep the legacy `readLine` and `writeLine` methods temporarily so the project stays buildable until the poll-loop conversion in Task 6. Mark them for deletion in that task; do not add new call sites.
- [ ] Run green and regression checks:

```sh
zig fmt --check src/sys.zig src/ipc/server.zig tests/ipc/server_test.zig
zig build test-ipc --summary all
zig build test --summary all
```

Expected: singleton, restart, stale-socket, permissions, listener flags, and lock CLOEXEC tests pass.

- [ ] Commit:

```sh
git add build.zig src/sys.zig src/ipc/server.zig src/test_ipc_exports.zig tests/ipc/server_test.zig
git commit -m "fix(ipc): enforce singleton nonblocking server"
```

## Task 4: Add nonblocking, SIGPIPE-safe connection I/O

**Audit rows:** `IPC-H1`, `IPC-H2`, and `IPC-L1`

**Files:**

- Modify: `src/sys.zig`
- Modify: `src/ipc/connection.zig`
- Modify: `tests/ipc/connection_test.zig`

**Interfaces:**

- Consumes: Task 2's bounded request/response/deadline primitives and Task 3's `sys.monotonicNsChecked` convention.
- Produces: `sys.sendNoSignal`, `IpcConnection.init/pollEvents/deadlineNs/timeoutMs/expired/readReady/beginWriting/flushReady/close`, and SIGPIPE-isolated socket regressions.

- [ ] Extend the imports at the top of `tests/ipc/connection_test.zig` and append these complete helpers and tests:

```zig
const posix = std.posix;
const linux = std.os.linux;
const sys = ipc.sys;

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
```

The forked child is essential: Zig 0.16's test I/O runtime installs a no-op SIGPIPE handler. Without `MSG_NOSIGNAL`, only the child dies by SIGPIPE and the parent reports a controlled failure.

- [ ] Run the red test:

```sh
zig build test-ipc --summary all
```

Expected: compilation fails because the send wrapper and fd-backed `IpcConnection` API do not exist.

- [ ] Add this complete send wrapper to `src/sys.zig`:

```zig
pub const SendError = error{
    WouldBlock,
    BrokenPipe,
    ConnectionResetByPeer,
    SocketNotConnected,
    SendFailed,
};

pub fn sendNoSignal(fd: fd_t, data: []const u8) SendError!usize {
    if (data.len == 0) return 0;
    while (true) {
        const rc = linux.sendto(
            fd,
            data.ptr,
            data.len,
            linux.MSG.NOSIGNAL | linux.MSG.DONTWAIT,
            null,
            0,
        );
        switch (linux.errno(rc)) {
            .SUCCESS => return rc,
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .PIPE => return error.BrokenPipe,
            .CONNRESET => return error.ConnectionResetByPeer,
            .NOTCONN => return error.SocketNotConnected,
            else => return error.SendFailed,
        }
    }
}
```

- [ ] Extend `src/ipc/connection.zig` with this complete fd-backed state machine:

```zig
const posix = std.posix;
const linux = std.os.linux;
const sys = @import("sys");

pub const State = enum { reading, writing, closed };

pub const ReadOutcome = union(enum) {
    incomplete,
    complete: []const u8,
    line_too_long,
    extra_data,
    peer_closed,
};

pub const FlushOutcome = enum { pending, complete };

pub const IpcConnection = struct {
    fd: posix.fd_t,
    request: RequestAccumulator = .{},
    response: ResponseQueue = .{},
    request_deadline_ns: u64,
    response_deadline_ns: u64 = 0,
    state: State = .reading,
    shutdown_after_flush: bool = false,

    pub fn init(fd: posix.fd_t, now_ns: u64) IpcConnection {
        return .{
            .fd = fd,
            .request_deadline_ns = deadlineAfter(now_ns),
        };
    }

    pub fn pollEvents(self: *const IpcConnection) i16 {
        return switch (self.state) {
            .reading => linux.POLL.IN,
            .writing => linux.POLL.OUT,
            .closed => 0,
        };
    }

    pub fn deadlineNs(self: *const IpcConnection) u64 {
        return switch (self.state) {
            .reading => self.request_deadline_ns,
            .writing => self.response_deadline_ns,
            .closed => 0,
        };
    }

    pub fn timeoutMs(self: *const IpcConnection, now_ns: u64) i32 {
        return pollTimeoutMs(now_ns, self.deadlineNs());
    }

    pub fn expired(self: *const IpcConnection, now_ns: u64) bool {
        return deadlineExpired(now_ns, self.deadlineNs());
    }

    pub fn readReady(self: *IpcConnection) !ReadOutcome {
        std.debug.assert(self.state == .reading);
        var scratch: [REQUEST_MAX]u8 = undefined;
        while (true) {
            const remaining = REQUEST_MAX - self.request.len;
            std.debug.assert(remaining > 0);
            const n = posix.read(self.fd, scratch[0..remaining]) catch |err| switch (err) {
                error.WouldBlock => return .incomplete,
                error.ConnectionResetByPeer, error.SocketUnconnected => return .peer_closed,
                else => return err,
            };
            if (n == 0) return .peer_closed;
            switch (self.request.feed(scratch[0..n])) {
                .incomplete => continue,
                .complete => |line| return .{ .complete = line },
                .line_too_long => return .line_too_long,
                .extra_data => return .extra_data,
            }
        }
    }

    pub fn beginWriting(
        self: *IpcConnection,
        now_ns: u64,
        shutdown_after_flush: bool,
    ) void {
        std.debug.assert(self.state == .reading);
        std.debug.assert(self.response.len > 0);
        self.response_deadline_ns = deadlineAfter(now_ns);
        self.shutdown_after_flush = shutdown_after_flush;
        self.state = .writing;
    }

    pub fn flushReady(self: *IpcConnection) sys.SendError!FlushOutcome {
        std.debug.assert(self.state == .writing);
        while (!self.response.isComplete()) {
            const sent = sys.sendNoSignal(self.fd, self.response.pending()) catch |err| switch (err) {
                error.WouldBlock => return .pending,
                else => return err,
            };
            if (sent == 0) return error.SocketNotConnected;
            self.response.consume(sent) catch unreachable;
        }
        return .complete;
    }

    pub fn close(self: *IpcConnection) bool {
        const shutdown = self.shutdown_after_flush;
        if (self.state != .closed) {
            sys.close(self.fd);
            self.fd = -1;
            self.state = .closed;
        }
        return shutdown;
    }
};
```
- [ ] Run green and full checks:

```sh
zig fmt --check src/sys.zig src/ipc/connection.zig tests/ipc/connection_test.zig
zig build test-ipc --summary all
zig build test --summary all
```

Expected: the child exits normally under default SIGPIPE behavior; fragmented reads and saturated writes remain nonblocking; all tests pass.

- [ ] Commit:

```sh
git add src/sys.zig src/ipc/connection.zig tests/ipc/connection_test.zig
git commit -m "fix(ipc): add nonblocking SIGPIPE-safe client IO"
```

## Task 5: Validate complete signalfd records before field access

**Audit row:** `APP-L1`

**Files:**

- Create: `src/signal_fd.zig`
- Create: `tests/ipc/signal_fd_test.zig`
- Modify: `src/test_ipc_exports.zig`
- Modify: `build.zig`

**Interfaces:**

- Consumes: nonblocking `posix.read` behavior and the `ipc.sys` test export.
- Produces: `signal_fd.readOne(fd: posix.fd_t) !ReadResult`, which exposes a signal only after exactly one full `linux.signalfd_siginfo` record is read.

- [ ] Export `signal_fd` through the IPC test shim and add its artifact to both test steps:

```zig
pub const signal_fd = @import("signal_fd.zig");
```

```zig
const signal_fd_test_mod = b.createModule(.{
    .root_source_file = b.path("tests/ipc/signal_fd_test.zig"),
    .target = target,
    .optimize = optimize,
});
signal_fd_test_mod.addImport("ipc", ipc_dispatch_mod);
const signal_fd_tests = b.addTest(.{
    .root_module = signal_fd_test_mod,
});
const run_signal_fd_tests = b.addRunArtifact(signal_fd_tests);
test_step.dependOn(&run_signal_fd_tests.step);
ipc_test_step.dependOn(&run_signal_fd_tests.step);
```

- [ ] Create `tests/ipc/signal_fd_test.zig` with these complete socket-backed tests:

```zig
const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const ipc = @import("ipc");
const signal_fd = ipc.signal_fd;
const sys = ipc.sys;

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
    try std.testing.expectEqual(bytes.len, try sys.sendNoSignal(fd, bytes));
}

test "readOne decodes only a complete signalfd record" {
    const fds = try socketPair();
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);
    var info = std.mem.zeroes(linux.signalfd_siginfo);
    info.signo = @intFromEnum(posix.SIG.INT);
    try sendExact(fds[1], std.mem.asBytes(&info));
    switch (try signal_fd.readOne(fds[0])) {
        .signal => |actual| try std.testing.expectEqual(info.signo, actual.signo),
        else => return error.TestExpectedSignal,
    }
}

test "readOne rejects a short record before decoding" {
    const fds = try socketPair();
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);
    try sendExact(fds[1], &[_]u8{ 1, 2, 3, 4 });
    switch (try signal_fd.readOne(fds[0])) {
        .short_read => |n| try std.testing.expectEqual(@as(usize, 4), n),
        else => return error.TestExpectedShortRead,
    }
}

test "readOne reports EOF as a zero-byte short record" {
    const fds = try socketPair();
    defer sys.close(fds[0]);
    sys.close(fds[1]);
    switch (try signal_fd.readOne(fds[0])) {
        .short_read => |n| try std.testing.expectEqual(@as(usize, 0), n),
        else => return error.TestExpectedShortRead,
    }
}

test "readOne reports would-block without touching record bytes" {
    const fds = try socketPair();
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);
    try std.testing.expect(try signal_fd.readOne(fds[0]) == .would_block);
}
```

- [ ] Run the red test:

```sh
zig build test-ipc --summary all
```

Expected: compilation fails because `signal_fd.zig` does not exist.

- [ ] Create `src/signal_fd.zig` with this complete implementation:

```zig
const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub const ReadResult = union(enum) {
    signal: linux.signalfd_siginfo,
    would_block,
    short_read: usize,
};

pub fn readOne(fd: posix.fd_t) !ReadResult {
    var info: linux.signalfd_siginfo = undefined;
    const n = posix.read(fd, std.mem.asBytes(&info)) catch |err| switch (err) {
        error.WouldBlock => return .would_block,
        else => return err,
    };
    if (n != @sizeOf(linux.signalfd_siginfo)) {
        return .{ .short_read = n };
    }
    return .{ .signal = info };
}
```

- [ ] Run green and full checks:

```sh
zig fmt --check src/signal_fd.zig tests/ipc/signal_fd_test.zig build.zig src/test_ipc_exports.zig
zig build test-ipc --summary all
zig build test --summary all
```

Expected: exact, short, EOF, and would-block cases pass.

- [ ] Commit:

```sh
git add build.zig src/signal_fd.zig src/test_ipc_exports.zig tests/ipc/signal_fd_test.zig
git commit -m "fix(app): validate signalfd records"
```

## Task 6: Integrate the active client into the main poll loop

**Audit rows:** Completes `IPC-H1`, `IPC-H2`, `IPC-L1`, `IPC-L2`, and `APP-L1`; applies `IPC-M1` startup policy

**Files:**

- Modify: `src/ipc/dispatch.zig`
- Modify: `src/ipc/server.zig`
- Modify: `src/sys.zig`
- Modify: `src/app.zig`
- Modify: `tests/ipc/protocol_test.zig`
- Modify: `tests/ipc/connection_test.zig`
- Modify: `tests/ipc/server_test.zig`

**Interfaces:**

- Consumes: strict parser arity from Task 1, every `connection.zig` API from Tasks 2/4, singleton listener ownership from Task 3, and `signal_fd.readOne` from Task 5.
- Produces: queued dispatch helpers, one dynamic IPC poll slot, one nonblocking active client, exact request/response deadlines, stop-after-close semantics, and no remaining direct fd response path.

- [ ] Append this accepted-client regression to `tests/ipc/server_test.zig`. It belongs in this task because the App state machine replaces the legacy blocking reader in the same commit:

```zig
test "accepted clients are nonblocking and close-on-exec" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const runtime_dir = try runtimeDir(&tmp, &path_buf);
    var server = try IpcServer.initAtRuntimeDir(runtime_dir);
    defer server.deinit();
    const peer_fd = try connectTo(server.socketPath());
    defer sys.close(peer_fd);
    const client_fd = try server.accept();
    defer sys.close(client_fd);
    try expectNonblocking(client_fd);
    try expectCloseOnExec(client_fd);
}
```

- [ ] First append these response-helper tests to `tests/ipc/connection_test.zig`; the file already imports `ipc` from Task 2. They require these exact bytes:

```zig
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
```

- [ ] Run the red test:

```sh
zig build test-ipc --summary all
```

Expected: compilation fails because queued dispatch helpers do not exist.

- [ ] Remove `std.posix` and `server.zig` imports from `dispatch.zig`, import `connection.zig`, and replace the direct writers with this complete code:

```zig
const connection = @import("connection.zig");

pub fn appendOk(out: *connection.ResponseQueue) void {
    out.appendLine("ok");
}

pub fn appendError(out: *connection.ResponseQueue, msg: []const u8) void {
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "error: {s}", .{msg}) catch {
        out.failInternal();
        return;
    };
    out.appendLine(line);
}

pub fn appendKv(
    out: *connection.ResponseQueue,
    key: []const u8,
    value: []const u8,
) void {
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s}={s}", .{ key, value }) catch {
        out.failInternal();
        return;
    };
    out.appendLine(line);
}

pub fn appendUnknownCommand(
    out: *connection.ResponseQueue,
    verb: []const u8,
) void {
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "unknown command \"{s}\"", .{verb}) catch {
        appendError(out, "unknown command");
        return;
    };
    appendError(out, msg);
}

pub fn appendUnexpectedArgument(
    out: *connection.ResponseQueue,
    verb: []const u8,
) void {
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "{s} does not accept arguments",
        .{verb},
    ) catch {
        appendError(out, "command does not accept arguments");
        return;
    };
    appendError(out, msg);
}
```

- [ ] Add these imports, field, initializer entry, and first teardown lines in `src/app.zig`. This optional stores no self-pointers, so returning `App` by value remains address-safe:

```zig
const connection_mod = @import("ipc/connection.zig");
const IpcConnection = connection_mod.IpcConnection;
const ResponseQueue = connection_mod.ResponseQueue;
const signal_fd = @import("signal_fd.zig");
```

```zig
ipc_server: ?IpcServer,
ipc_client: ?IpcConnection,
```

```zig
.ipc_server = null,
.ipc_client = null,
```

```zig
pub fn deinit(self: *App) void {
    self.closeIpcClient();
    if (self.ipc_server) |*srv| srv.deinit();
    self.ipc_server = null;
    self.allocator.free(self.palettes);
    sys.close(self.tfd);
    sys.close(self.sig_fd);
```

Keep the existing EGL, surface, output, registry, and display teardown after the shown prefix.
- [ ] Change IPC setup error handling so only `error.AlreadyRunning` is fatal:

```zig
self.ipc_server = IpcServer.init(self.environ) catch |err| switch (err) {
    error.AlreadyRunning => {
        std.debug.print("ipc: another wlchroma instance owns the control socket\n", .{});
        return error.AlreadyRunning;
    },
    else => blk: {
        std.debug.print("ipc: failed to start IPC server: {} -- continuing without IPC\n", .{err});
        break :blk null;
    },
};
```

- [ ] Replace `IpcServer.accept` with the following and remove `SO_RCVTIMEO`:

```zig
pub fn accept(self: *IpcServer) sys.AcceptError!posix.fd_t {
    return sys.accept4(
        self.fd,
        posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
    );
}
```

- [ ] Replace the fixed IPC fd and fixed `nfds` setup in `App.run` with this dynamic slot. `IpcPollRole` is defined with the helper methods below:

```zig
const wl_fd: posix.fd_t = c.wl_display_get_fd(self.display);

// fds[0]=wayland  fds[1]=timerfd  fds[2]=signalfd
// fds[3]=IPC listener or the one active IPC client
var fds = [4]posix.pollfd{
    .{ .fd = wl_fd, .events = linux.POLL.IN, .revents = 0 },
    .{ .fd = tfd, .events = linux.POLL.IN, .revents = 0 },
    .{ .fd = self.sig_fd, .events = linux.POLL.IN, .revents = 0 },
    .{ .fd = -1, .events = 0, .revents = 0 },
};
```

- [ ] In the `wl_display_prepare_read != 0` branch, replace the final `continue` with this deadline reconciliation. This closes a timed-out client even if pending Wayland events keep bypassing `poll`:

```zig
self.syncSurfaces();
self.expireIpcClient();
if (!self.running) break;
continue;
```

- [ ] Immediately after the successful `wl_display_prepare_read`, replace the old revent reset and `poll` call with this exact block. The role is saved before `poll`; it must not be inferred from `ipc_client` after a listener event accepts a client:

```zig
const poll_timeout = self.ipcPollTimeout();
if (!self.running) {
    c.wl_display_cancel_read(self.display);
    break;
}
const ipc_role = self.configureIpcPollSlot(&fds[3]);
const nfds: usize = if (ipc_role == .none) 3 else 4;

for (fds[0..nfds]) |*poll_fd| poll_fd.revents = 0;
_ = posix.poll(fds[0..nfds], poll_timeout) catch |err| {
    c.wl_display_cancel_read(self.display);
    std.debug.print("poll error: {}\n", .{err});
    break;
};
```

- [ ] Change both existing Wayland/timer terminal masks to include `POLL.NVAL` and update their diagnostics:

```zig
const poll_terminal = linux.POLL.HUP | linux.POLL.ERR | linux.POLL.NVAL;
if (fds[0].revents & poll_terminal != 0) {
    c.wl_display_cancel_read(self.display);
    std.debug.print("Wayland socket HUP/ERR/NVAL, compositor disconnected\n", .{});
    break;
}

if (fds[1].revents & poll_terminal != 0) {
    c.wl_display_cancel_read(self.display);
    std.debug.print("timerfd HUP/ERR/NVAL, exiting\n", .{});
    break;
}
```

- [ ] After the unchanged timer/render block, replace the raw signalfd and synchronous IPC blocks with this exact ordering. A client role is serviced even when `revents == 0`, because a rounded-up poll timeout may be the only event and the fresh post-render clock must enforce the absolute deadline:

```zig
if (fds[2].revents & linux.POLL.IN != 0) {
    self.handleSignalEvent();
}
if (fds[2].revents & poll_terminal != 0) {
    std.debug.print("signalfd HUP/ERR/NVAL, shutting down\n", .{});
    self.running = false;
}

// Signal shutdown wins over accepting or mutating IPC state. Otherwise use
// the role captured before poll, even if accepting changes ipc_client.
if (self.running and ipc_role != .none) {
    self.serviceIpcSlot(ipc_role, fds[3].revents);
}
```

This preserves the required order: Wayland read/dispatch, surface reconciliation, timer/render, signalfd, then IPC. `serviceIpcSlot` takes a fresh checked timestamp after render work to enforce the current deadline; `beginIpcResponse` below samples again after response construction so synchronous dispatch time cannot consume the independent response window.
- [ ] Delete the old synchronous `handleIpcEvent` and insert these complete private types and helpers. They encode the one-client policy, checked absolute deadlines, saved poll-slot role, expected-read/write-before-terminal ordering, and stop-after-flush semantics:

```zig
const CommandOutcome = enum { keep_running, shutdown_after_flush };
const IpcPollRole = enum { none, listener, client };

fn configureIpcPollSlot(self: *App, slot: *posix.pollfd) IpcPollRole {
    slot.revents = 0;
    if (self.ipc_client) |*client| {
        slot.fd = client.fd;
        slot.events = client.pollEvents();
        return .client;
    }
    if (self.ipc_server) |*server| {
        slot.fd = server.fd;
        slot.events = linux.POLL.IN;
        return .listener;
    }
    slot.fd = -1;
    slot.events = 0;
    return .none;
}

fn expireIpcClient(self: *App) void {
    if (self.ipc_client == null) return;
    const now_ns = sys.monotonicNsChecked() catch |err| {
        std.debug.print("ipc: monotonic clock failed: {}; closing client\n", .{err});
        self.closeIpcClient();
        return;
    };
    var expired = false;
    if (self.ipc_client) |*client| expired = client.expired(now_ns);
    if (expired) self.closeIpcClient();
}

fn ipcPollTimeout(self: *App) i32 {
    if (self.ipc_client == null) return -1;
    const now_ns = sys.monotonicNsChecked() catch |err| {
        std.debug.print("ipc: monotonic clock failed: {}; closing client\n", .{err});
        self.closeIpcClient();
        return -1;
    };
    var expired = false;
    var timeout_ms: i32 = -1;
    if (self.ipc_client) |*client| {
        expired = client.expired(now_ns);
        if (!expired) timeout_ms = client.timeoutMs(now_ns);
    }
    if (expired) {
        self.closeIpcClient();
        return -1;
    }
    return timeout_ms;
}

fn acceptIpcClient(self: *App) void {
    const server = if (self.ipc_server) |*value| value else return;
    const client_fd = server.accept() catch |err| switch (err) {
        error.WouldBlock, error.ConnectionAborted => return,
        else => {
            std.debug.print("ipc: accept failed: {}\n", .{err});
            return;
        },
    };
    const now_ns = sys.monotonicNsChecked() catch |err| {
        std.debug.print("ipc: monotonic clock failed after accept: {}\n", .{err});
        sys.close(client_fd);
        return;
    };
    std.debug.assert(self.ipc_client == null);
    self.ipc_client = IpcConnection.init(client_fd, now_ns);
}

fn disableIpcServer(self: *App) void {
    if (self.ipc_server) |*server| server.deinit();
    self.ipc_server = null;
}

fn serviceIpcSlot(self: *App, role: IpcPollRole, revents: i16) void {
    const terminal = linux.POLL.HUP | linux.POLL.ERR | linux.POLL.NVAL;
    switch (role) {
        .none => {},
        .listener => {
            if (revents & linux.POLL.IN != 0) self.acceptIpcClient();
            if (revents & terminal != 0) {
                std.debug.print("ipc: listener HUP/ERR/NVAL; disabling IPC\n", .{});
                self.disableIpcServer();
            }
        },
        .client => {
            const now_ns = sys.monotonicNsChecked() catch |err| {
                std.debug.print("ipc: monotonic clock failed: {}; closing client\n", .{err});
                self.closeIpcClient();
                return;
            };
            self.serviceActiveIpcClient(revents, now_ns);
        },
    }
}

fn serviceActiveIpcClient(self: *App, revents: i16, now_ns: u64) void {
    if (self.ipc_client == null) return;
    var expired = false;
    if (self.ipc_client) |*client| expired = client.expired(now_ns);
    if (expired) {
        self.closeIpcClient();
        return;
    }

    var should_close = false;
    if (self.ipc_client) |*client| {
        switch (client.state) {
            .reading => reading: {
                if (revents & linux.POLL.IN == 0) break :reading;
                const outcome = client.readReady() catch |err| {
                    std.debug.print("ipc: client read failed: {}\n", .{err});
                    should_close = true;
                    break :reading;
                };
                switch (outcome) {
                    .incomplete => {},
                    .complete => |line| {
                        if (!self.queueCommandResponse(client, line)) {
                            should_close = true;
                        }
                    },
                    .line_too_long => {
                        dispatch.appendError(&client.response, "command too long");
                        if (!self.beginIpcResponse(client, false)) {
                            should_close = true;
                        }
                    },
                    .extra_data => {
                        dispatch.appendError(
                            &client.response,
                            "multiple commands are not supported",
                        );
                        if (!self.beginIpcResponse(client, false)) {
                            should_close = true;
                        }
                    },
                    .peer_closed => should_close = true,
                }
            },
            .writing => writing: {
                if (revents & linux.POLL.OUT == 0) break :writing;
                const outcome = client.flushReady() catch |err| {
                    std.debug.print("ipc: client write failed: {}\n", .{err});
                    should_close = true;
                    break :writing;
                };
                if (outcome == .complete) should_close = true;
            },
            .closed => should_close = true,
        }

        // HUP may accompany the last readable request bytes, so expected IO
        // is serviced first. A terminal revent then closes this connection.
        const terminal = linux.POLL.HUP | linux.POLL.ERR | linux.POLL.NVAL;
        if (!should_close and revents & terminal != 0) should_close = true;
    }
    if (should_close) self.closeIpcClient();
}

fn queueCommandResponse(
    self: *App,
    client: *IpcConnection,
    line: []const u8,
) bool {
    const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
    const space = std.mem.indexOfScalar(u8, trimmed, ' ');
    const verb = if (space) |index| trimmed[0..index] else trimmed;

    const cmd = dispatch.parseLine(line) catch |err| {
        switch (err) {
            error.UnknownCommand => {
                dispatch.appendUnknownCommand(&client.response, verb);
            },
            error.UnexpectedArgument => {
                dispatch.appendUnexpectedArgument(&client.response, verb);
            },
            error.MissingArgument, error.BadArgument => {
                const fallback = if (err == error.MissingArgument)
                    "missing argument"
                else
                    "invalid argument";
                const kind: []const u8 = if (std.mem.eql(u8, verb, "set-palette"))
                    "name"
                else if (std.mem.eql(u8, verb, "set-colors"))
                    "color"
                else
                    "numeric";
                var buf: [96]u8 = undefined;
                const msg = std.fmt.bufPrint(
                    &buf,
                    "{s} requires a {s} argument",
                    .{ verb, kind },
                ) catch fallback;
                dispatch.appendError(&client.response, msg);
            },
        }
        return self.beginIpcResponse(client, false);
    };

    const outcome = self.dispatchCommand(&client.response, cmd);
    return self.beginIpcResponse(
        client,
        outcome == .shutdown_after_flush,
    );
}

fn beginIpcResponse(
    _: *App,
    client: *IpcConnection,
    shutdown_after_flush: bool,
) bool {
    const response_now_ns = sys.monotonicNsChecked() catch |err| {
        std.debug.print(
            "ipc: monotonic clock failed before response: {}; closing client\n",
            .{err},
        );
        // A successfully dispatched stop must still shut down when the clock
        // failure makes a bounded response phase impossible.
        client.shutdown_after_flush = shutdown_after_flush;
        return false;
    };
    client.beginWriting(response_now_ns, shutdown_after_flush);
    return true;
}

fn closeIpcClient(self: *App) void {
    var shutdown_after_close = false;
    if (self.ipc_client) |*client| {
        shutdown_after_close = client.close();
    }
    self.ipc_client = null;
    if (shutdown_after_close) self.running = false;
}

fn handleSignalEvent(self: *App) void {
    while (true) {
        const result = signal_fd.readOne(self.sig_fd) catch |err| {
            std.debug.print("signalfd read failed: {}; ignoring\n", .{err});
            return;
        };
        switch (result) {
            .signal => |info| switch (info.signo) {
                @intFromEnum(posix.SIG.INT),
                @intFromEnum(posix.SIG.TERM),
                => {
                    const name = if (info.signo == @intFromEnum(posix.SIG.INT))
                        "SIGINT"
                    else
                        "SIGTERM";
                    std.debug.print("received {s}, shutting down\n", .{name});
                    self.running = false;
                    return;
                },
                else => {
                    std.debug.print("unexpected signalfd signal {}; ignoring\n", .{info.signo});
                },
            },
            .would_block => {
                std.debug.print("signalfd readiness race; ignoring\n", .{});
                return;
            },
            .short_read => |n| {
                std.debug.print("short signalfd record ({} bytes); ignoring\n", .{n});
                return;
            },
        }
    }
}
```

The optional captures in `closeIpcClient` and `disableIpcServer` end before their optionals are assigned `null`. A stop request sets only `shutdown_after_flush`; this single close path performs shutdown after a full response, terminal write failure, disconnect, or response deadline. The run-loop block above treats signalfd `HUP | ERR | NVAL` as fatal to clean-shutdown guarantees and lets normal `deinit` release every resource.

- [ ] Replace `dispatchCommand`, change the stale handler-section comment to `// --- IPC command handlers ---`, and replace every fd-writing handler with these complete queue-writing versions. Keep the existing `applyScaleNow` unchanged between `handleSetScale` and `handleSetPalette`:

```zig
fn dispatchCommand(
    self: *App,
    out: *ResponseQueue,
    cmd: dispatch.IpcCommand,
) CommandOutcome {
    switch (cmd) {
        .query => self.handleQuery(out),
        .stop => {
            self.handleStop(out);
            return .shutdown_after_flush;
        },
        .set_fps => |fps| self.handleSetFps(out, fps),
        .set_scale => |scale| self.handleSetScale(out, scale),
        .set_palette => |args| self.handleSetPalette(out, args.nameSlice()),
        .set_colors => |set_colors| {
            self.handleSetColors(out, set_colors.colors, set_colors.fade_ms);
        },
        .reload => self.handleReload(out),
    }
    return .keep_running;
}

fn handleQuery(self: *App, out: *ResponseQueue) void {
    dispatch.appendKv(out, "effect", @tagName(self.effect));

    const fps = 1_000_000_000 / @as(u64, self.frame_interval_ns);
    var fps_buf: [16]u8 = undefined;
    const fps_str = std.fmt.bufPrint(&fps_buf, "{}", .{fps}) catch "?";
    dispatch.appendKv(out, "fps", fps_str);

    var scale_buf: [16]u8 = undefined;
    const scale_str = std.fmt.bufPrint(
        &scale_buf,
        "{d:.2}",
        .{self.renderer_scale},
    ) catch "?";
    dispatch.appendKv(out, "scale", scale_str);

    const palette_name: []const u8 = if (self.active_palette_name_len > 0)
        self.active_palette_name_buf[0..self.active_palette_name_len]
    else
        "custom";
    dispatch.appendKv(out, "palette", palette_name);
    dispatch.appendOk(out);
}

fn handleStop(_: *App, out: *ResponseQueue) void {
    dispatch.appendOk(out);
}

fn handleSetFps(self: *App, out: *ResponseQueue, fps: u32) void {
    if (fps < 1 or fps > 240) {
        dispatch.appendError(out, "fps must be between 1 and 240");
        return;
    }
    const interval_ns: u32 = @intCast(1_000_000_000 / @as(u64, fps));
    if (self.timer_armed) {
        const interval = linux.itimerspec{
            .it_value = .{ .sec = 0, .nsec = interval_ns },
            .it_interval = .{ .sec = 0, .nsec = interval_ns },
        };
        sys.timerfdSettime(self.tfd, &interval) catch |err| {
            var buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &buf,
                "timerfd_settime failed: {}",
                .{err},
            ) catch "timerfd_settime failed";
            dispatch.appendError(out, msg);
            return;
        };
    }
    self.frame_interval_ns = interval_ns;
    dispatch.appendOk(out);
}

fn handleSetScale(self: *App, out: *ResponseQueue, scale: f32) void {
    if (!std.math.isFinite(scale) or scale < 0.1 or scale > 1.0) {
        dispatch.appendError(out, "scale must be between 0.1 and 1.0");
        return;
    }
    if (scale < 1.0 and scale >= config_mod.RENDERER_SCALE_NEAR_NATIVE_MIN) {
        dispatch.appendError(
            out,
            "scale values from 0.95 up to but not including 1.0 are too close to native; use a lower value or exactly 1.0",
        );
        return;
    }
    self.applyScaleNow(scale);
    dispatch.appendOk(out);
}

fn handleSetPalette(
    self: *App,
    out: *ResponseQueue,
    name: []const u8,
) void {
    var found: ?[3]defaults.Rgb = null;
    for (self.palettes) |*palette| {
        if (std.mem.eql(u8, palette.nameSlice(), name)) {
            found = palette.colors;
            break;
        }
    }
    const colors = found orelse {
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &buf,
            "unknown palette \"{s}\"",
            .{name},
        ) catch "unknown palette";
        dispatch.appendError(out, msg);
        return;
    };
    self.fade = null;
    self.effect.updatePalette(colors);
    if (self.effect_shader) |*shader| shader.bind(&self.effect);
    self.current_palette = colors;
    const copy_len = @min(name.len, self.active_palette_name_buf.len);
    @memcpy(self.active_palette_name_buf[0..copy_len], name[0..copy_len]);
    self.active_palette_name_len = copy_len;
    dispatch.appendOk(out);
}

fn handleSetColors(
    self: *App,
    out: *ResponseQueue,
    colors: [3]defaults.Rgb,
    fade_ms: u32,
) void {
    self.active_palette_name_len = 0;

    if (fade_ms == 0) {
        self.fade = null;
        self.effect.updatePalette(colors);
        if (self.effect_shader) |*shader| shader.bind(&self.effect);
        self.current_palette = colors;
        dispatch.appendOk(out);
        return;
    }

    const now = sys.monotonicNs();
    const start = if (self.fade) |fade|
        color_fade.sample(fade, now).colors
    else
        self.current_palette;
    self.fade = .{
        .start = start,
        .target = colors,
        .start_ns = now,
        .dur_ns = @as(u64, fade_ms) * std.time.ns_per_ms,
    };
    dispatch.appendOk(out);
}

fn handleReload(self: *App, out: *ResponseQueue) void {
    const load_result = config_mod.loadConfigFullRequireFile(
        self.allocator,
        self.io,
        self.environ,
        self.config_path,
    ) catch |err| {
        if (err == error.ConfigFileNotFound) {
            dispatch.appendError(out, "config file not found");
            return;
        }
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &buf,
            "config parse failed: {}",
            .{err},
        ) catch "config parse failed";
        dispatch.appendError(out, msg);
        return;
    };
    const cfg = &load_result.config;

    const new_interval_ns = cfg.frame_interval_ns;
    if (self.timer_armed) {
        const new_interval = linux.itimerspec{
            .it_value = .{ .sec = 0, .nsec = new_interval_ns },
            .it_interval = .{ .sec = 0, .nsec = new_interval_ns },
        };
        sys.timerfdSettime(self.tfd, &new_interval) catch {};
    }
    self.frame_interval_ns = new_interval_ns;

    if (cfg.upscale_filter != self.upscale_filter) {
        self.upscale_filter = cfg.upscale_filter;
        for (self.surfaces.items) |surface| {
            surface.upscale_filter = cfg.upscale_filter;
            if (self.egl_ctx) |*ctx| surface.dropOffscreenForFilterChange(ctx);
        }
    }

    self.applyScaleNow(cfg.renderer_scale);
    self.fade = null;
    if (@as(config_mod.EffectType, self.effect) != cfg.effect_type) {
        self.switchEffect(cfg);
    } else {
        self.effect.setSpeed(cfg.speed);
        self.effect.updatePalette(cfg.palette);
        if (self.effect_shader) |*shader| shader.bind(&self.effect);
    }
    self.current_palette = cfg.palette;

    self.allocator.free(self.palettes);
    self.palettes = load_result.palettes;
    self.active_palette_name_len = 0;
    dispatch.appendOk(out);
}
```
- [ ] Delete `IpcServer.readLine`, `IpcServer.writeLine`, the server's now-redundant `LINE_MAX`, the receive-timeout code, and now-unused `sys.writev`. Verify `rg` finds no legacy direct response writes or duplicate request-limit constant:

```sh
rg -n "readLine|writeLine|writev|LINE_MAX|SO_RCVTIMEO|dispatch\\.write|fn handle[A-Za-z]+\\([^)]*client_fd" src/ipc src/app.zig src/sys.zig
```

Expected: no legacy IPC read/write path, direct dispatch writer, or handler fd parameter remains. The local accepted-descriptor name `client_fd` in `acceptIpcClient` is legitimate and intentionally not forbidden.

- [ ] Run the focused and full green checks:

```sh
zig fmt --check build.zig src tests
zig build test-ipc --summary all
zig build --summary all
zig build test --summary all
```

Expected: all tests and the Debug executable build pass; no Wayland compositor is needed for the regression suite.

- [ ] Commit:

```sh
git add src/app.zig src/ipc/dispatch.zig src/ipc/server.zig src/sys.zig tests/ipc/protocol_test.zig tests/ipc/connection_test.zig tests/ipc/server_test.zig
git commit -m "fix(ipc): move clients into the main poll loop"
```

## Task 7: Verify all build modes and close the Phase 1 ledger

**Audit rows:** `IPC-H1`, `IPC-H2`, `IPC-M1`, `IPC-L1`, `IPC-L2`, `IPC-L3`, `APP-L1`

**Files:**

- Modify: `docs/design/2026-07-19-ipc-hardening-design.md`
- Modify: `docs/security/2026-07-19-security-performance-audit.md`

**Interfaces:**

- Consumes: the complete Phase 1 implementation history and its focused tests.
- Produces: independent review evidence, Debug/ReleaseSafe/ReleaseFast verification, seven ledger rows with fixing commits, and an implemented design status.

- [ ] Use `superpowers:requesting-code-review` for an independent review against the approved design and all seven finding IDs. Resolve confirmed findings before proceeding.
- [ ] Run the complete non-live verification matrix from a clean command environment:

```sh
zig fmt --check build.zig src tests
zig build --summary all
zig build test --summary all
zig build -Doptimize=ReleaseSafe --summary all
zig build test -Doptimize=ReleaseSafe --summary all
zig build -Doptimize=ReleaseFast --summary all
zig build test -Doptimize=ReleaseFast --summary all
git diff --check
git status --short
```

Expected: every command exits zero; Debug, ReleaseSafe, and ReleaseFast tests all pass; only intentional Phase 1 files are modified.

- [ ] Run a safe client compatibility smoke test only if a session daemon is already running:

```sh
zig-out/bin/wlchroma-ctl query
```

Expected: effect, fps, scale, and palette lines followed by successful client exit. This confirms client/protocol compatibility; it does not replace a coordinated restart test of the newly built daemon.

- [ ] Do not stop or replace the running wallpaper process automatically. If the user explicitly coordinates a live restart and confirms the new binary is running, repeat `zig-out/bin/wlchroma-ctl query` and confirm the wallpaper remains live. Fragmentation, stalled-client deadline, and closed-peer behavior stay in the deterministic socket tests from Tasks 4 and 6; do not improvise extra live probes or disable any display for Phase 1.
- [ ] In the master audit table, mark all seven rows `Fixed` and record the actual implementation commit hashes. Append a Phase 1 verification record with test totals and build modes. Do not rewrite the original finding descriptions.
- [ ] Change the design status from `Approved design; implementation plan ready` to `Implemented and verified`; retain the link to this plan.
- [ ] Re-run Markdown link/path checks with:

```sh
test -f docs/design/2026-07-19-ipc-hardening-design.md
test -f docs/security/2026-07-19-security-performance-audit.md
test -f docs/superpowers/plans/2026-07-19-phase-1-ipc-hardening.md
git diff --check
```

- [ ] Commit the evidence:

```sh
git add docs/design/2026-07-19-ipc-hardening-design.md docs/security/2026-07-19-security-performance-audit.md
git commit -m "docs(security): close phase one audit findings"
```

- [ ] Invoke `superpowers:verification-before-completion`, rerun any evidence it requires, and report exact commands/results rather than claiming success from prior output.

## Post-Phase Checkpoint

After Phase 1 is merged or otherwise accepted, return to the master ledger and begin the design checkpoint for Phase 2 (`WL-H1`, `WL-H2`, `GPU-M1`, `GPU-M2`, `GPU-M3`, `WL-L1`). Phase 2 starts only after Phase 1 evidence is durable; no finding from later phases is dropped.
