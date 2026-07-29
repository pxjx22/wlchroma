# Phase 3C Configuration, Reload, and Build Closeout Design

Date: 2026-07-29

## Scope

Phase 3C closes the four findings that remain Open in the July 2026 security
and performance audit:

- `APP-L2`: reload discards `timerfd_settime` failure, then reports the new FPS
  even though the kernel timer may still use the old cadence.
- `PERF-L1`: reload performs blocking file I/O and two parser scans on the
  Wayland/render thread.
- `CONF-L1`: the custom parser is described as TOML without defining or
  consistently rejecting unsupported string escapes.
- `BUILD-L1`: `build.zig.zon` claims Zig 0.15.2 even though the project and
  source require Zig 0.16.0.

The phase also repairs the adjacent CI policy defect exposed when Phase 3B was
pushed: the benchmark-only commit type `bench(renderer): ...` is intentional,
but the commit-message lint accepts `perf` and not `bench`.

The separate efficiency audits do not add a higher-severity prerequisite.
Their Phase 3B timing/layout findings are superseded, and their remaining
renderer ideas require a later measured Phase 4. They are not mixed into this
config/reload correctness phase.

Out of scope:

- new config keys, IPC commands, or CLI flags;
- full TOML compatibility or a third-party parser dependency;
- changing effect, palette, scale, filter, or fallback semantics;
- general multi-client subscriptions or a worker pool;
- viewporter, refresh-aware pacing, partial damage, shader rewrites, or other
  renderer efficiency proposals;
- rewriting already-pushed Git history to rename the Phase 3B benchmark
  commit.

## Goals and invariants

1. A reload never blocks Wayland dispatch, timer rendering, signal handling,
   or unrelated IPC while the file is read and parsed.
2. At most one reload job exists. It owns every fd, thread handle, connection,
   result, and allocation until ownership is explicitly transferred or freed.
3. All runtime mutation remains on the main thread. The worker performs only
   bounded file I/O and pure parsing; non-I/O path resolution happens before
   spawn.
4. `ok` is sent only after a valid snapshot has been applied. A parse, read,
   timer, allocation, notification, or thread-spawn failure rejects
   application and preserves prior runtime state; it queues `error:` when the
   requesting connection still exists and otherwise logs the orphaned result.
5. Once a complete reload request is accepted, client disconnect does not
   cancel it. This matches current behavior, where application precedes reply.
6. Other IPC commands remain serviceable while a reload job is loading or
   writing its response. A second concurrent reload is rejected explicitly.
7. A timer interval is committed to App state only after the armed timerfd has
   accepted the same interval. The disarmed zero-output path updates the stored
   interval without issuing an unnecessary syscall.
8. Recognized config strings either satisfy the documented strict subset or
   fail closed. Unsupported escapes are never partially decoded, silently
   preserved, or allowed to corrupt comment/quote tracking.
9. The base config and all `[[palettes]]` entries are parsed in one scan.
10. The Zig 0.16.0 minimum/pin is consistent across package metadata,
    version-manager input, documentation, and CI.
11. The steady state with no reload in progress gains no fd, thread, heap
    allocation, poll wake-up, clock read, or rendering work.

## Chosen architecture

### 1. CI and toolchain preflight

The first atomic task restores a green repository policy before larger work:

- add `bench` to the allowed commit types in `.github/workflows/lint.yml`;
- update the matching CI design/plan and contributor/agent guidance so the
  policy is documented rather than a workflow-only exception;
- change `.minimum_zig_version` in `build.zig.zon` from `0.15.2` to `0.16.0`;
- add a lint check that the manifest minimum and workflow Zig pins match
  `.zig-version`.

`bench` is reserved for benchmark harness/evidence commits. `perf` remains the
type for retained production performance changes. A forward policy fix is
chosen over a destructive force-push of `main`.

The already-failed GitHub Lint run and a local policy probe are the RED
evidence. The corrected probe, workflow syntax/static checks, and a new GitHub
Lint run provide GREEN evidence. No persistent application unit test is added
for a YAML regular expression; the workflow's own metadata check is the
regression guard.

### 2. One checked frame-interval transaction

`set-fps` and reload share one App helper that applies a requested frame
interval:

```zig
fn applyFrameInterval(self: *App, interval_ns: u32) FrameIntervalError!void;
```

Behavior:

- when the frame timer is armed, construct the exact `itimerspec`, call
  `timerfdSettime`, and assign `self.frame_interval_ns` only after success;
- when no output exists and the timer is disarmed, update the stored interval
  directly so the next arm uses it;
- on failure, retain the old stored interval and return an error;
- `set-fps` and reload format their existing command-specific response around
  the shared result.

Reload applies this transaction before every other runtime mutation. If it
fails, the newly parsed palette slice is freed and effect, animation, palette,
scale, filter, FPS, fade, and active-palette state remain unchanged.

Tests use a narrow timer-set seam rather than relying on a globally invalid fd
inside App. The production adapter calls `sys.timerfdSettime`; a deterministic
test adapter records calls and injects failure.

### 3. Explicit strict configuration subset

The public format remains TOML-shaped, but the supported grammar is stated
precisely. Recognized input supports:

- bare ASCII section/key names from the existing schema;
- decimal integers and floats already accepted by Zig parsing;
- double-quoted, single-line UTF-8 strings;
- inline arrays of double-quoted strings separated by commas;
- `#` comments outside quoted strings;
- the existing `[[palettes]]` array-of-tables form.

Recognized string values do not support TOML escapes. Any backslash in a
recognized quoted string or string-array element is rejected as an unsupported
escape. The entire document must be valid UTF-8. Raw C0 control bytes are
rejected except horizontal tab, line feed, and a carriage return used in a
line ending. A literal `#` inside quotes remains data. Fixed-buffer limits,
including palette-name limits, are byte limits over valid UTF-8 rather than
Unicode code-point counts. Unknown keys and sections preserve the current
forward-compatibility behavior and are ignored; their values are not promoted
to a new public grammar.

The byte/UTF-8/control checks are document-wide. After a structurally valid
`key = value` split, values for unknown keys/sections remain opaque: their
backslashes are neither decoded nor rejected, and their quote balance is not
schema-validated. The comment scanner treats a backslash plus following byte
inside quotes as one opaque pair only so a following quote or `#` cannot be
misclassified. The legacy top-level `version` key remains semantically
value-agnostic under the same rule; only document-wide byte hygiene and the
existing key/value line structure apply. This deliberately preserves the
forward-compatibility and spec-010 behavior while making every recognized
string fail closed.

The choice is deliberate:

- decoding full TOML basic strings would add allocation/lifetime complexity to
  every fixed-buffer consumer;
- accepting raw backslashes would keep the current ambiguous behavior;
- a maintained full-TOML dependency is disproportionate to the small fixed
  schema and would expand the build/supply surface.

README and the maintainer-local config contracts will say "supported TOML
subset" and list the string restriction. Malformed or unsupported recognized
values fail at startup and reload with no partial application.

### 4. One-pass document parser

One internal document parser owns section state, duplicate tracking, base
config construction, and the fixed 64-entry palette staging buffer. It scans
each line once and returns a stack-owned parsed document:

```zig
const ParsedDocument = struct {
    config: AppConfig,
    palettes: [MAX_PALETTES]NamedPalette,
    palette_count: usize,
};

fn parseDocument(content: []const u8) ParseError!ParsedDocument;
```

`parseAndValidate` returns only `ParsedDocument.config` for focused tests.
`parseAndValidateFull` duplicates the validated palette prefix into the caller
allocator exactly once. There is no second scan and no heap allocation during
lexing/validation.

Palette entries are finalized when the next section begins or at EOF. The
single state machine continues to reject incomplete entries, duplicate known
keys/sections/names, excessive entries, invalid colors, unsupported effects,
non-finite/range-invalid numbers, and oversized files exactly as today.

The lexer validates document UTF-8/control bytes and handles quote/comment
boundaries before schema parsing. It recognizes escape-shaped pairs only to
avoid mistaking a quote or `#` following a backslash for syntax; the
known-string parser then rejects the unsupported backslash explicitly. This
prevents a malformed recognized value from being truncated into a different
valid value while preserving ignored unknown-key behavior.

### 5. Poll-integrated reload job

`src/config/reload_job.zig` defines one heap-stable reload job. App stores an
optional pointer so the worker never borrows a movable App field.

The job owns:

- one transient `std.Thread` handle;
- one nonblocking, close-on-exec Linux `eventfd` used only for completion;
- an atomic completion flag with release/acquire ordering;
- the worker result: either a fully owned `LoadResult` or an error;
- the original reload `IpcConnection`, transferred by value after the complete
  command is accepted;
- a phase: `loading`, `responding`, or `orphaned`.

The production allocator passed to the job is `std.process.Init.gpa`, which Zig
0.16 documents as thread-safe. The main thread resolves the explicit/default
config path and duplicates that short path into the job before spawning; the
worker therefore never queries process environment state or borrows an
App-owned path slice. Path resolution contains no filesystem I/O. The worker
uses the App's process-lifetime `std.Io.Threaded` handle for the bounded file
read; no other runtime path uses that handle concurrently, and App deinit joins
the worker before process I/O teardown. The worker owns all allocations it
creates until it publishes completion. Tests use a thread-safe allocator and
an injected loader explicitly.

A narrow `ReloadOps` table supplies loader execution, eventfd create/read/write,
thread start, and monotonic-clock operations to App/ReloadJob. Production uses
one immutable table of direct system/std adapters; tests substitute only the
operation under test. The table is consulted solely during reload/IPC work, so
it adds no per-frame call. A failing allocator covers path/job/result allocation
boundaries. This seam makes slow load, lost notification, notifier creation,
spawn, clock, and readiness-race tests deterministic without invalidating an
App-global fd or adding timing sleeps to unit tests.

Worker sequence:

1. read at most 64 KiB from the job-owned resolved path;
2. parse and validate the entire document;
3. store the success/error result;
4. publish readiness with a release atomic store;
5. write one native `u64` token to the eventfd, retrying interruption. A
   permanent write error is recorded for the main thread; `WouldBlock` is not
   spun on (one zero-based job notification cannot legitimately saturate the
   counter).

The worker never reads or mutates effect, Wayland, EGL, timer, IPC-server, or
surface state. The main thread reads the eventfd, joins the completed thread,
acquires the result, and performs the checked application transaction.

The current four-slot poll set grows to six fixed slots: Wayland, frame timer,
signal, normal IPC listener/client, reload notification, and reload client.
The two reload slots are `fd = -1` when unused. No reload therefore changes the
steady-state active poll count or wake-up behavior.

The aggregate poll timeout is computed from every live source: the normal IPC
deadline, the reload response deadline while writing, and a 500 ms
reload-completion fallback while loading. Before each poll, both connection
deadlines are expired independently; the minimum remaining timeout is used;
after pending events are dispatched, expiration is checked again to cover a
zero-timeout/readiness race. A monotonic-clock failure closes the affected
bounded-response connection and follows its ordinary cleanup/shutdown policy.

Every loading fallback wake acquire-loads the completion flag. This makes an
unexpected lost/broken eventfd notification bounded rather than capable of
hanging completion, even with zero outputs and no other IPC; it adds clock work
and wake-ups only while a reload is already in flight.

### 6. IPC ownership and responsiveness

The reload connection cannot remain in `App.ipc_client`, because that would
continue blocking every other command while file I/O runs. Once `reload` is
parsed successfully:

1. create the eventfd and spawn the worker transactionally;
2. move the active `IpcConnection` into `ReloadJob` without closing its fd;
3. clear `App.ipc_client`, exposing the listener for another connection;
4. poll Wayland, timer, signals, normal IPC, reload completion, and the reload
   client's terminal/write state together.

This requires an explicit deferred-dispatch result. The command service must
not call the ordinary `beginIpcResponse` after accepting reload. It creates the
job, moves `App.ipc_client` as a whole, and only then invalidates the normal
client slot; no pointer into that optional may survive the move. Start failure
keeps the client in place and queues the error through the ordinary bounded
response path.

Accepting `stop` sets an App-level `shutdown_pending` latch before its `ok`
response begins. The existing response still receives its bounded flush
opportunity, but no reload completion may mutate App state while the latch is
set. Closing or completing that stop response transitions `running` to false
as today. This makes shutdown precedence realizable rather than dependent on
which ready fd happens to be serviced first.

While loading, the reload socket requests no normal read/write event, but HUP,
ERR, or NVAL is observed. A disconnected client makes the job `orphaned`; the
accepted reload still completes and applies, then discards its response.

After completion and successful application, the job queues `ok` and begins a
fresh bounded response-write deadline. An error queues the existing
human-readable `error:` response and likewise uses the bounded write phase.
Partial writes remain SIGPIPE-safe through `IpcConnection`.

A second reload while one is loading/responding receives
`error: reload already in progress`. Query, set-fps, set-scale, palette/color
commands, and stop remain available. The reload linearization point is main
thread application: mutations accepted after reload starts but before it
completes may be overwritten by the later snapshot, exactly as if a slow
synchronous reload finished at that point.

This preserves the original IPC requirement that socket accept/read/write work
is integrated into the poll loop with no socket thread. The one transient
worker exists only for blocking config file I/O and pure parsing.

### 7. Shutdown and failure lifecycle

Signal or `stop` shutdown wins over applying a completion observed in the same
poll batch. Poll-batch service order is therefore signal, normal IPC (including
`stop`), then reload completion; reload completion is skipped once
`self.running` becomes false or `shutdown_pending` becomes true. A stop already
waiting for response writability has set the latch in its earlier batch.
Deinit then:

1. closes any active normal/reload response connection;
2. waits for and joins a running reload worker exactly once;
3. frees an unconsumed successful palette result;
4. closes the eventfd;
5. destroys the heap-stable job.

Linux offers no safe generic cancellation of an arbitrary blocking filesystem
read. Shutdown may therefore wait for an already-running read, but the live
Wayland/render loop remains responsive until shutdown begins. Detaching the
thread would permit use-after-free of allocator/environment/job state and is
rejected.

Transactional start rules:

- path-resolution, path-copy, or job-allocation failure leaves the active
  client/App unchanged and returns an error;
- eventfd creation failure leaves the active client/App unchanged and returns
  an error;
- thread-spawn failure closes the new eventfd, destroys the empty job, and
  returns an error;
- connection ownership transfers only after both resources exist;
- transient notification interruption/`WouldBlock` logs, checks the atomic
  completion state, and relies on the reload-only bounded fallback wake if
  publication has not happened; a permanent/short/terminal notification fault
  is latched and, after join, rejects rather than applies the loaded result;
  neither path reads unpublished result bytes;
- a recorded notification-write failure causes the main thread, after joining,
  to free any successful load result and return an IPC error without applying
  it;
- orphaning closes the reload connection immediately; response completion,
  timeout, or terminal error does the same in the writing phase. In either
  case the job is destroyed only after its worker has been joined, independently
  of any normal client;
- result ownership transfers to App only after frame-interval application
  succeeds;
- every error path has one owner for every fd, allocation, thread, and palette
  slice.

## Alternatives rejected

### Keep synchronous reload and accept risk

The 64 KiB size cap bounds memory and parser CPU, but cannot bound FUSE,
network-backed, removable, or otherwise stalled filesystem reads. Explicit
Accepted Risk would conflict with the requested all-findings-fixed outcome.

### Call `std.Io.async` and immediately await

`Future.await` is completion-blocking. Awaiting it in the handwritten poll loop
would preserve the audited stall. The loop needs a pollable completion source.

### Full TOML dependency

This offers standard escapes but adds a dependency, broader grammar, allocator
behavior, and upgrade surface for a small fixed schema. Strict fail-closed
subset semantics solve the ambiguity with less code and risk.

### Respond `ok` when reload is merely queued

This changes the protocol meaning: scripts could observe `ok` before parsing or
application later fails. The design retains completion-confirmed responses.

### Keep the reload socket in the single active-client slot

That would free rendering but still make `query`, `stop`, and other IPC
unavailable during slow I/O. Transferring the connection to the job preserves
the Phase 1 responsiveness goal.

### Rewrite the benchmark commit

Force-pushing public `main` to rename one valid benchmark-only commit is
destructive and unnecessary. Documenting `bench` as an intentional type is a
safe forward correction.

## Automated verification

### Repository policy and metadata

- reproduce the current commit-pattern failure for
  `bench(renderer): add CPU path baseline`;
- prove the corrected pattern accepts all documented types/scopes and rejects
  unknown type, unknown scope, empty description, and merge commits from the
  non-merge scan;
- prove `.zig-version`, `build.zig.zon`, and all workflow Zig pins agree on
  `0.16.0`;
- validate workflow YAML/static structure with available local tools and the
  GitHub Lint run.

### Default-off fault injection

Build options `-Dphase3c-reload-delay-ms=<u32>` (default `0`) and
`-Dphase3c-force-reload-timer-failure=true` (default `false`) provide a
reload-worker delay and a reload-only timer-set failure. Both are `comptime`
default-off, excluded from normal runtime work, and documented as
test/fault-injection controls rather than public daemon or IPC features. They
let deterministic tests and an isolated live daemon prove the two
failure/responsiveness contracts without introducing a FUSE/network mount or
corrupting the session daemon's timer fd.

### Config parser

- preserve every existing parser/default/range/duplicate/palette test;
- add single-pass parity for zero, one, and 64 palette entries;
- assert one scan through a test-only line-visit counter or parser adapter;
- reject escaped quote, backslash, `\n`, Unicode escape, trailing backslash,
  raw control byte, invalid UTF-8, and escape/comment interaction in every
  recognized string context;
- preserve literal `#` inside strings and comments outside strings;
- preserve opaque escaped/quoted values under unknown keys/sections and an
  arbitrary legacy `version` value, subject only to document byte hygiene and
  key/value structure;
- retain the 64 KiB file bound and no-allocation parser core.

### Frame interval

- armed success updates kernel adapter and stored interval together;
- armed failure changes neither;
- disarmed update performs no syscall;
- reload timer failure frees the candidate palettes and changes no runtime
  field;
- set-fps and reload share the same helper behavior.

### Reload job and IPC

- slow injected loader leaves timer, Wayland reconciliation, signal handling,
  query, and stop serviceable;
- successful completion applies once, then responds `ok`;
- read/parse failure responds with the existing error and applies nothing;
- second reload returns busy without spawning another thread;
- disconnect before completion still applies and frees the response path;
- intervening runtime mutation is overwritten only at reload completion;
- eventfd/thread/allocation start failures preserve connection and App state;
- notification readiness races and partial/invalid records do not expose
  unpublished result state; permanent notification faults reject application;
- notification-write failure with zero outputs and no other IPC reaches error
  cleanup through the 500 ms fallback rather than stranding the job;
- normal-client and reload-response deadlines use the aggregate minimum and
  expire independently under backpressure and clock failure;
- simultaneous stop-request/completion readiness and stop-write/completion
  readiness both suppress reload application through `shutdown_pending`;
- shutdown-before-completion joins once and frees every owned result;
- response partial-write, timeout, SIGPIPE, and closed-peer behavior remains
  bounded.

### Full matrices and static checks

- `zig fmt --check build.zig bench src tests`;
- `git diff --check` and whole-branch committed-range check;
- Debug, ReleaseSafe, and ReleaseFast builds/full test graphs;
- direct config tests and focused IPC/reload/Wayland tests;
- allocator leak checks in success, failure, disconnect, and shutdown paths;
- static scan proves synchronous config loading is absent from command
  dispatch and the parser has one content-iteration loop.

## Live acceptance

On Niri, capture and later restore the exact daemon executable, argv, cwd,
config hash, socket/query, output state, and `mpris-chroma` state. Never signal
by process name.

Use an isolated ReleaseSafe daemon/config to verify:

- normal reload applies FPS, palette, speed, scale, filter, and effect changes;
- the default-off delayed-loader build keeps animation and separate query/stop
  IPC responsive while reload waits;
- invalid escape, malformed config, missing file, and injected timer failure
  return errors with state unchanged;
- client disconnect and second-reload-busy paths leave the daemon healthy;
- zero-output reload records the interval without arming the timer and applies
  on output return, using a fail-safe recovery action before output-off;
- logs contain no ownership, allocator, eventfd, thread, timer, EGL, or stale
  completion warning.

No ad hoc network/FUSE mount or invalid live timer fd is introduced on the
user's machine. Visual phase/fallback behavior is unchanged and need only be
smoke-tested for regression.

## Documentation and audit closeout

Tracked documentation changes:

- README: supported TOML subset and asynchronous completion-confirmed reload;
- CONTRIBUTING/AI_CONTRIBUTING/AGENTS: `bench` type and Zig metadata
  consistency;
- `docs/superpowers/2026-07-24-ci-cd-design.md`, its implementation plan, and
  the workflow: corrected commit policy and pin check;
- audit ledger: only `APP-L2`, `PERF-L1`, `CONF-L1`, and `BUILD-L1` change to
  Fixed after independent approval.

Maintainer-local specs are amended in place:

- config schema: strict string subset and escape rejection;
- config-version consolidation: `version` remains semantically ignored while
  sharing the document-wide UTF-8/control-byte rules;
- IPC protocol/reload behavior: background execution, one in-flight reload,
  busy error, completion-confirmed response, and other-IPC responsiveness;
- the original "no second thread" statement is clarified to continue banning
  a socket thread while allowing one transient config-I/O worker.

The Phase 3C completion record includes exact commits, policy probes, operation
counts, test matrices, failure injection, live evidence, restoration, review,
and any explicitly unavailable visual/hardware claim. The four user-owned
efficiency audit/transcript files remain untracked and unchanged.

## Acceptance gate

Phase 3C is complete only when:

- GitHub Lint and Test are green at the branch head;
- all four remaining canonical audit rows have independent evidence and Fixed
  dispositions;
- slow reload cannot stall rendering, Wayland, signals, or unrelated IPC;
- success/error replies still describe completed application, not queueing;
- timer failure and every invalid config path preserve all prior state;
- parser escape behavior is explicit, fail-closed, one-pass, and documented;
- no reload path leaks a thread, fd, socket, palette slice, config buffer, or
  job allocation;
- Debug, ReleaseSafe, ReleaseFast, focused, live, and restoration checks pass;
- the tracked branch is clean and the maintainer-local specs match the shipped
  behavior.
