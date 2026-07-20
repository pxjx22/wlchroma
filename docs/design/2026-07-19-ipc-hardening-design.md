# IPC Hardening Design

**Date:** 2026-07-19

**Status:** Implemented and verified

**Audit mapping:** `IPC-H1`, `IPC-H2`, `IPC-M1`, `IPC-L1`, `IPC-L2`, `IPC-L3`, `APP-L1`

**Implementation plan:** [`2026-07-19-phase-1-ipc-hardening.md`](../superpowers/plans/2026-07-19-phase-1-ipc-hardening.md)

## Goal

Make wlchroma IPC incapable of blocking or terminating the Wayland/render loop through normal client socket behavior, while preserving the existing one-command-per-connection protocol and command semantics.

## Scope

This phase includes:

- Nonblocking listener and client I/O.
- An absolute request deadline.
- SIGPIPE-safe, partial-write-aware responses.
- Single-daemon socket ownership.
- Exact request-size and command-arity enforcement.
- Signalfd read validation because the IPC poll-loop work touches the same event-loop boundary.
- Regression and integration tests that do not require a live Wayland compositor.

This phase does not change command names, successful response text, palette behavior, configuration semantics, rendering behavior, or authorization. IPC remains local to the user's XDG runtime directory.

## Architectural Decision

Use one active nonblocking client connection at a time, integrated into the existing poll loop. This is intentionally smaller than a multi-client reactor and sufficient for a one-command local control protocol.

An active client may delay other IPC clients until its 500 ms absolute deadline, but it cannot delay Wayland, timerfd, or signalfd processing. The listener is excluded from polling while a client is active so a queued backlog cannot create a listener-ready busy loop. Once the active connection closes, listener polling resumes.

Same-user connection flooding is not an authorization problem this phase attempts to solve. The security invariant is that no client can make the compositor/render loop perform a blocking socket operation.

## Components

### IPC server ownership

`IpcServer` owns:

- The listening Unix-domain socket.
- A lifetime advisory lock fd for `$XDG_RUNTIME_DIR/wlchroma.lock`.
- The bound socket path for cleanup.

Initialization acquires the lock nonblockingly before touching `wlchroma.sock`. Lock acquisition failure returns `error.AlreadyRunning`. After acquiring the lock, the server may unlink a stale socket, bind, and listen. Shutdown closes and unlinks the owned socket while the lock is still held, then releases the lock.

The lock file is opened with mode `0600` and `CLOEXEC`. `error.AlreadyRunning` is fatal to application startup rather than entering the ordinary "continue without IPC" degradation path; otherwise a second wallpaper daemon would still run even though it could not own the control socket. Other IPC initialization failures retain the existing graceful-degradation behavior.

The listener is created with `SOCK_NONBLOCK | SOCK_CLOEXEC`. Accepted clients use the same flags.

### Connection state

One `IpcConnection` value stores:

- Client fd.
- Request bytes and current length.
- Absolute request deadline in monotonic nanoseconds.
- Fixed response bytes, sent offset, and absolute response deadline.
- State: `reading`, `writing`, or `closed`.
- `shutdown_after_flush`, set only by a successful `stop` command.

The request buffer capacity is exactly 4096 bytes including the terminating newline. No heap allocation occurs per connection.

The response buffer is a fixed 1024 bytes, enough for the bounded query response plus terminal line. Response construction must fail closed with a short internal error if an invariant is violated; it must never truncate a successful response silently.

### Pure request accumulator

Request framing is separated from fd operations. Feeding a byte slice returns one of:

- `incomplete`
- `complete` with the line excluding `\n` and an optional preceding `\r`
- `line_too_long`
- `extra_data`, when bytes already retrieved from the socket follow the first newline

This pure boundary makes fragmentation and exact-limit behavior deterministic and unit-testable.

### Response queue

Command handlers append response lines to the connection's fixed response buffer instead of writing directly to an fd. Query appends all key/value lines followed by `ok`; errors append one `error:` line; mutating commands append `ok` only after their validation and state mutation succeed.

Writing uses nonblocking `send` with `MSG_NOSIGNAL`. Each successful short write advances `sent_offset`; `EAGAIN` leaves the connection in `writing` and requests `POLLOUT`. `EPIPE`, reset, deadline expiry, and other terminal errors close the client without affecting the daemon.

## Event Flow

1. The poll set contains Wayland, timerfd, signalfd, and either the IPC listener or the active IPC client.
2. Listener readiness accepts one client nonblockingly and records `request_deadline = now + 500 ms`.
3. Client `POLLIN` drains available bytes until `EAGAIN`, EOF, or a framing result.
4. A complete request is parsed and dispatched exactly once.
5. Dispatch builds a fixed response and changes the connection to `writing` with a fresh 500 ms response deadline.
6. Client `POLLOUT` flushes as much as possible without blocking.
7. A fully sent response closes the client. If `shutdown_after_flush` is set, the application then exits cleanly. A terminal peer/write failure or response deadline also closes the client and completes the requested shutdown.
8. The poll timeout is the time remaining until the active request/response deadline, or infinite when no IPC client is active. Deadline expiry closes only that client.

Wayland dispatch, surface reconciliation, rendering, and signal handling retain their current ordering. IPC servicing is bounded nonblocking work at the end of each event-loop iteration.

## Protocol Rules

- A connection carries exactly one newline-terminated command.
- The 4096-byte maximum includes the newline.
- EOF before newline is `ConnectionClosed` and causes no command dispatch.
- Bytes already buffered after the first newline are rejected as `extra_data`; later bytes cannot trigger a second dispatch because command pipelining is unsupported and the server closes after one response.
- `query`, `reload`, and `stop` reject non-whitespace trailing arguments.
- Existing numeric, scale, palette, and color validation remains unchanged.
- Unknown commands and malformed arguments retain deterministic `error:` responses.

## Error Handling

- IPC initialization failures retain the existing graceful-degradation policy except `AlreadyRunning`, which is logged distinctly and propagated as a fatal application-startup error.
- Accept, read, parse, and write failures affect only the current client.
- No socket error may bubble out of the main event loop or terminate the process.
- No read/write loop may retry without first returning control to poll after `EAGAIN`.
- Signalfd processing verifies an exact `signalfd_siginfo` read before accessing the signal number. Short/error reads are logged and ignored without consuming undefined bytes.
- `stop` changes application shutdown state after its response is flushed, or after a terminal peer/write failure or response deadline makes flushing impossible.

## Testing Strategy

### Pure unit tests

- Request split at every possible byte boundary.
- CRLF trimming.
- 4095 payload bytes plus newline succeeds.
- 4096 payload bytes without newline is too long.
- Data after a complete line is rejected.
- Response queue consumes simulated partial writes without duplication or omission.
- Request and response deadline comparisons use injected monotonic timestamps and require no sleeps.
- `query`, `reload`, and `stop` reject trailing arguments.

### Socket-level tests

- A closed peer produces `EPIPE` without terminating the test process, proving `MSG_NOSIGNAL` use.
- A nonblocking partial request returns control without waiting for more bytes.
- A saturated nonblocking response leaves unsent data queued for `POLLOUT`.
- A temporary XDG runtime directory permits one server, rejects a second with `AlreadyRunning`, and permits clean restart after the first releases its lock.
- A stale socket left without a held lock is removed by the next lock owner.

### Project verification

- `zig fmt --check build.zig src tests`
- `zig build test --summary all`
- Debug build
- ReleaseSafe build and tests
- ReleaseFast build and tests
- Worktree remains free of unrelated changes

A live `wlchroma-ctl query` smoke test may be performed against an already-running session daemon. No process is stopped and no output is disabled without explicit coordination and a recovery plan.

## Success Criteria

- A client sending bytes indefinitely cannot block Wayland or rendering work.
- Closing before a response cannot terminate wlchroma.
- No successful response can be silently truncated.
- A second daemon cannot unlink or replace the first daemon's socket.
- Exact size and arity rules are covered by regression tests.
- Signalfd parsing never reads undefined bytes.
- Every mapped audit row is updated with its commit and verification evidence before Phase 1 closes.
