# Phase 3C Configuration, Reload, and Build Closeout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close `APP-L2`, `PERF-L1`, `CONF-L1`, and `BUILD-L1` by making frame-rate updates transactional, defining a strict one-pass configuration parser, moving reload file work off the Wayland/render thread, and aligning the Zig/commit-policy metadata.

**Architecture:** Configuration parsing produces one fixed-buffer `ParsedDocument`; only the full wrapper duplicates its palette prefix. A heap-stable `ReloadJob` owns a transient worker, eventfd, path, result, and transferred IPC connection while App keeps every Wayland/EGL/timer mutation on the main poll thread. Checked frame-interval application, aggregate IPC deadlines, `shutdown_pending`, and deterministic operations seams make failure and shutdown behavior explicit.

**Tech Stack:** Zig 0.16.0, Linux `eventfd`/timerfd/poll/Unix sockets, `std.Thread`, `std.Io.Threaded`, Wayland/EGL/GLESv2, GitHub Actions, `std.testing`, Niri live acceptance.

## Global Constraints

- Close all four remaining canonical audit rows; no Accepted Risk disposition substitutes for implementation.
- Also fix the pushed `bench(renderer): add CPU path baseline` commit-policy mismatch without rewriting public Git history.
- Zig remains pinned to exactly `0.16.0`; add no dependency and do not upgrade the toolchain.
- The config file remains a documented strict TOML subset, not full TOML.
- Recognized double-quoted strings reject every backslash; unknown values and legacy `version` remain opaque after document-wide UTF-8/control validation.
- The base config and all `[[palettes]]` entries share one line-iteration loop and a fixed 64-entry staging buffer.
- Reload file I/O and parsing never run on the Wayland/render thread.
- At most one reload job exists; every fd, thread, connection, path, result, and palette slice has exactly one owner.
- All effect, animation, palette, scale, filter, timer, EGL, Wayland, and App mutations remain on the main thread.
- `ok` means the snapshot was applied, never merely queued.
- A disconnected reload client does not cancel an accepted job; a second reload receives `error: reload already in progress`.
- Timer state changes only after `timerfd_settime` succeeds; a disarmed zero-output timer needs no syscall.
- `stop` acceptance latches `shutdown_pending`; no later reload completion may mutate App state.
- Normal builds add no active fd, thread, allocation, poll wake, clock read, or render work when no reload is in progress.
- Fault controls are compile-time, default-off, and have no public config/CLI/IPC surface.
- Tests under `tests/` use the existing source-root shims; do not import `src/` by relative path.
- Maintainer-local `specs/` files exist only in `/home/px/wlchroma`, are gitignored, and must be updated separately without staging the four user-owned audit/transcript files.
- Never stop a daemon by name. Live work records the exact PID/executable/argv/cwd/config/socket first and restores the prior session state.
- Never disable an output without an already-armed, tested recovery action and explicit user coordination.

---


## File and interface map

**Create:**

- `src/config/reload_job.zig` — heap-stable job, worker publication, notifier operations, connection/result ownership.
- `tests/ipc/reload_job_test.zig` — thread/eventfd/result/path/connection lifecycle tests without Wayland.
- `tests/wayland_egl/app_reload_test.zig` — checked timer, aggregate deadline, deferred dispatch, application atomicity, stop precedence.

**Modify:**

- `src/config/config.zig` — strict lexical contract, one-pass `ParsedDocument`, public path loader/resolver used by the worker.
- `src/sys.zig` — checked nonblocking/close-on-exec eventfd create/read/write wrappers.
- `src/app.zig` — timer transaction, reload job pointer, six-slot poll integration, deferred command outcome, `shutdown_pending`, completion application/cleanup.
- `src/test_ipc_exports.zig`, `src/test_wayland_exports.zig` — export the new internals to the correct out-of-tree tests.
- `build.zig` — Phase 3C build options and new focused test artifacts.
- `build.zig.zon`, `.github/workflows/lint.yml` — Zig metadata and policy checks.
- `README.md`, `CONTRIBUTING.md`, `AI_CONTRIBUTING.md`, `AGENTS.md` — shipped config/reload/build contracts.
- `docs/superpowers/2026-07-24-ci-cd-design.md`, `docs/superpowers/plans/2026-07-24-ci-cd-pipeline.md` — keep committed CI policy sources aligned.
- `docs/security/2026-07-19-security-performance-audit.md` — final evidence and dispositions only after independent approval.

**Maintainer-local, ignored:**

- `specs/001-effect-system/contracts/config-schema.md`
- `specs/004-runtime-ipc-ctl/data-model.md`
- `specs/004-runtime-ipc-ctl/contracts/ipc-protocol.md`
- `specs/007-runtime-effect-switching/contracts/reload-behavior.md`
- `specs/010-config-version-consolidation/spec.md`

---

### Task 1: Repair repository policy and Zig metadata

**Files:**

- Modify: `.github/workflows/lint.yml:12-70`
- Modify: `build.zig.zon:5`
- Modify: `CONTRIBUTING.md:65-82`
- Modify: `AI_CONTRIBUTING.md:80-90`
- Modify: `AGENTS.md:8-20,48-52`
- Modify: `docs/superpowers/2026-07-24-ci-cd-design.md:14-29`
- Modify: `docs/superpowers/plans/2026-07-24-ci-cd-pipeline.md:22-115`

**Interfaces:**

- Consumes: `.zig-version` containing `0.16.0` and the existing Conventional-Commit-like regex.
- Produces: documented `bench` commit type and a CI metadata check requiring every Zig-using workflow plus `build.zig.zon` to agree with `.zig-version`.

- [ ] **Step 1: Capture the two RED policy probes**

Run:

```sh
PATTERN='^(feat|fix|test|docs|refactor|perf)\((ipc|ctl|config|renderer|build|repo|app|security)\): .+'
printf '%s\n' 'bench(renderer): add CPU path baseline' | grep -Eq "$PATTERN"
grep -F '.minimum_zig_version = "0.16.0"' build.zig.zon
```

Expected: both commands exit nonzero. Record the already-failed GitHub Lint run `30424702070` as external RED evidence; do not rewrite its commit.

- [ ] **Step 2: Add `bench` to the workflow and documented policy**

Change the lint pattern and diagnostic to:

```yaml
PATTERN='^(feat|fix|test|docs|refactor|perf|bench)\((ipc|ctl|config|renderer|build|repo|app|security)\): .+'
echo "  types:  feat, fix, test, docs, refactor, perf, bench"
```

Document the exact type split in every committed policy source listed above:

```markdown
Types: `feat`, `fix`, `test`, `docs`, `refactor`, `perf`, `bench`.
Use `bench` for benchmark harness/evidence commits and `perf` for retained
production performance changes.
```

Keep the scope set unchanged.

- [ ] **Step 3: Align the package minimum and add the CI pin check**

Set:

```zig
.minimum_zig_version = "0.16.0",
```

Add this custom-check step after checkout and before commit-message validation:

```yaml
- name: Zig pin consistency
  run: |
    set -euo pipefail
    PIN=$(tr -d '[:space:]' < .zig-version)
    test "$PIN" = "0.16.0"
    grep -Fq ".minimum_zig_version = \"$PIN\"" build.zig.zon
    for workflow in .github/workflows/*.yml; do
      if grep -q 'mlugg/setup-zig' "$workflow"; then
        grep -Fq "version: $PIN" "$workflow"
      fi
    done
```

Also expand the formatting command to include the retained benchmark tree:

```yaml
run: zig fmt --check build.zig bench src tests
```

- [ ] **Step 4: Run positive and negative policy probes**

Run:

```sh
PATTERN='^(feat|fix|test|docs|refactor|perf|bench)\((ipc|ctl|config|renderer|build|repo|app|security)\): .+'
for subject in \
  'feat(ipc): x' \
  'fix(config): x' \
  'test(app): x' \
  'docs(repo): x' \
  'refactor(build): x' \
  'perf(renderer): x' \
  'bench(renderer): x'; do
  printf '%s\n' "$subject" | grep -Eq "$PATTERN"
done
for subject in 'chore(repo): x' 'fix(other): x' 'fix(app):'; do
  if printf '%s\n' "$subject" | grep -Eq "$PATTERN"; then exit 1; fi
done
PIN=$(tr -d '[:space:]' < .zig-version)
test "$PIN" = '0.16.0'
grep -Fq ".minimum_zig_version = \"$PIN\"" build.zig.zon
for workflow in .github/workflows/*.yml; do
  if grep -q 'mlugg/setup-zig' "$workflow"; then
    grep -Fq "version: $PIN" "$workflow"
  fi
done
```

Expected: exit zero with no output.

- [ ] **Step 5: Verify and commit the preflight**

```sh
zig fmt --check build.zig bench src tests
git diff --check
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-p3c-t1 zig build test --summary all
git add .github/workflows/lint.yml build.zig.zon CONTRIBUTING.md \
  AI_CONTRIBUTING.md AGENTS.md docs/superpowers/2026-07-24-ci-cd-design.md \
  docs/superpowers/plans/2026-07-24-ci-cd-pipeline.md
git commit -m "fix(build): align repository policy and Zig pin"
```

Expected: the full suite passes and the commit itself matches the repaired policy.

---

### Task 2: Define and enforce the strict configuration string subset

**Files:**

- Modify: `src/config/config.zig:229-416,626-707,733-1075`

**Interfaces:**

- Consumes: existing `error.InvalidValue` behavior, unknown-key compatibility, value-agnostic `version`, and fixed-buffer strings.
- Produces: `validateDocumentBytes`, backslash-aware comment boundaries, and strict recognized scalar/array string parsing with no allocation.

- [ ] **Step 1: Add RED document-hygiene tests**

Add inline tests with exact byte cases:

```zig
test "parseAndValidate rejects invalid UTF-8 and disallowed controls" {
    const invalid_utf8 = [_]u8{ 'f', 'p', 's', ' ', '=', ' ', '1', '5', '\n', 0xff };
    try std.testing.expectError(error.MalformedConfig, parseAndValidate(&invalid_utf8));

    const nul = [_]u8{ 'f', 'p', 's', ' ', '=', ' ', '1', '5', 0, '\n' };
    try std.testing.expectError(error.MalformedConfig, parseAndValidate(&nul));

    try std.testing.expectError(
        error.MalformedConfig,
        parseAndValidate("fps = 15\rscale = 1.0\n"),
    );
}

test "parseAndValidate accepts horizontal tabs and CRLF" {
    const cfg = try parseAndValidate("fps\t=\t30\r\n");
    try std.testing.expectEqual(@as(u32, 30), cfg.fps);
}
```

Include ASCII DEL (`0x7f`) in the rejected table. Validation occurs before trim/comment removal.

- [ ] **Step 2: Add RED compatibility tests for ignored values**

```zig
test "parseAndValidate preserves opaque unknown and version values" {
    const toml =
        "version = \"future\\q#value\" # ignored\n" ++
        "future = \"opaque\\\"#pair\" # ignored\n" ++
        "fps = 30\n";
    const cfg = try parseAndValidate(toml);
    try std.testing.expectEqual(@as(u32, 30), cfg.fps);
}
```

Retain duplicate tracking for `version`; the test proves only that its value is semantically opaque.

- [ ] **Step 3: Add table-driven RED tests for every recognized string context**

Use this helper and case table:

```zig
fn expectRecognizedEscapeRejected(prefix: []const u8, suffix: []const u8) !void {
    const escapes = [_][]const u8{ "\\q", "\\n", "\\u1234", "\\\"", "\\" };
    for (escapes) |escape| {
        const toml = try std.fmt.allocPrint(
            std.testing.allocator,
            "{s}{s}{s}",
            .{ prefix, escape, suffix },
        );
        defer std.testing.allocator.free(toml);
        if (parseAndValidateFull(std.testing.allocator, toml)) |loaded_value| {
            std.testing.allocator.free(loaded_value.palettes);
            return error.TestExpectedError;
        } else |err| {
            try std.testing.expect(err == error.InvalidValue);
        }
    }
}
```

Exercise `[outputs].policy`, `[effect].name`, `[renderer].upscale_filter`, `[effect.settings].palette`, `[[palettes]].name`, and `[[palettes]].colors`. For calls to `parseAndValidateFull`, free a returned palette slice if a case unexpectedly succeeds before failing the assertion helper; do not leak in a RED test.

Add positive cases proving `#` remains data inside quoted palette names and colors while comments outside quotes are removed.

- [ ] **Step 4: Run focused RED tests**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-p3c-t2-red \
  zig test src/config/config.zig --test-filter 'rejects invalid UTF-8'
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-p3c-t2-red \
  zig test src/config/config.zig --test-filter 'recognized string'
```

Expected: the new hygiene and escape tests fail against the permissive lexer.

- [ ] **Step 5: Implement document validation and lexical comment tracking**

Add:

```zig
fn validateDocumentBytes(content: []const u8) error{MalformedConfig}!void {
    if (!std.unicode.utf8ValidateSlice(content)) return error.MalformedConfig;
    for (content, 0..) |byte, i| {
        if (byte == '\t' or byte == '\n') continue;
        if (byte == '\r') {
            if (i + 1 < content.len and content[i + 1] == '\n') continue;
            return error.MalformedConfig;
        }
        if (byte < 0x20 or byte == 0x7f) return error.MalformedConfig;
    }
}
```

Call it once at the beginning of the document parser. Replace `stripComment` with an index loop that, only while inside a quote, skips a backslash and its following byte for boundary detection:

```zig
fn stripComment(line: []const u8) []const u8 {
    var in_quote = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (in_quote and line[i] == '\\' and i + 1 < line.len) {
            i += 1;
            continue;
        }
        if (line[i] == '"') in_quote = !in_quote;
        if (line[i] == '#' and !in_quote) {
            return std.mem.trimEnd(u8, line[0..i], &std.ascii.whitespace);
        }
    }
    return line;
}
```

- [ ] **Step 6: Make recognized string readers reject every backslash**

In `parseQuotedString`, scan from byte 1 and return `null` immediately on `\\`; accept the first closing quote only when all trailing bytes are whitespace. In `parseStringArray`, return `null` if the element loop encounters `\\` before its closing quote:

```zig
while (pos < inner.len and inner[pos] != '"') : (pos += 1) {
    if (inner[pos] == '\\') return null;
}
```

Do not decode, normalize, or allocate recognized strings. Existing callers continue mapping `null` to `error.InvalidValue` or their established field-specific validation error.

- [ ] **Step 7: Run GREEN and commit**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-p3c-t2 zig test src/config/config.zig
zig fmt --check src/config/config.zig
git diff --check
git add src/config/config.zig
git commit -m "fix(config): reject unsupported string escapes"
```

Expected: every existing config test and every new lexical/compatibility test passes without allocation leaks.

---

### Task 3: Consolidate base config and named palettes into one parser pass

**Files:**

- Modify: `src/config/config.zig:180-542,800-831`

**Interfaces:**

- Consumes: strict lexical helpers from Task 2 and existing `AppConfig`, `NamedPalette`, duplicate/range semantics.
- Produces: private `ParsedDocument`, `parseDocument`, and one wrapper allocation in `parseAndValidateFull`.

- [ ] **Step 1: Add RED boundary/finalization tests**

Add private test helpers that generate entries with `std.ArrayList(u8)` and cover zero, one, 64, and 65 palettes. Add exact transition tests:

```zig
test "parseDocument finalizes palettes at section transition and EOF" {
    const toml =
        "[[palettes]]\n" ++
        "name = \"one\"\n" ++
        "colors = [\"#010203\", \"#040506\", \"#070809\"]\n" ++
        "[renderer]\n" ++
        "scale = 0.5\n" ++
        "[[palettes]]\n" ++
        "name = \"two\"\n" ++
        "colors = [\"#111213\", \"#141516\", \"#171819\"]\n";
    const document = try parseDocument(toml);
    try std.testing.expectEqual(@as(usize, 2), document.palette_count);
    try std.testing.expectEqualStrings("one", document.palettes[0].nameSlice());
    try std.testing.expectEqualStrings("two", document.palettes[1].nameSlice());
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), document.config.renderer_scale, 0.001);
}
```

Add separate failures for an incomplete palette before the next section and at EOF. Repeated `[[palettes]]` remains legal; duplicate `name`/`colors` inside one entry remains illegal.

- [ ] **Step 2: Add the RED one-visit assertion**

Use a private optional counter in the parser core; production passes `null`,
so the normal path performs only the predictable null check:

```zig
test "parseDocument visits each input line once" {
    const toml = "fps = 30\n[effect]\nname = \"colormix\"\n[[palettes]]\nname = \"one\"\ncolors = [\"#010203\", \"#040506\", \"#070809\"]";
    var line_visits: usize = 0;
    _ = try parseDocumentObserved(toml, &line_visits);
    try std.testing.expectEqual(@as(usize, 6), line_visits);
}
```

`parseDocument` calls the same implementation with `null`; no test-global state
or pointer with a shorter lifetime is introduced.

- [ ] **Step 3: Run RED**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-p3c-t3-red \
  zig test src/config/config.zig --test-filter 'parseDocument'
```

Expected: fail because `ParsedDocument`, `parseDocument`, and observed one-pass parsing do not exist.

- [ ] **Step 4: Introduce the fixed document type and palette finalizer**

Add near the parser limits:

```zig
const MAX_PALETTES = 64;

const ParseError = error{
    MalformedConfig,
    DuplicateConfigEntry,
    InvalidValue,
    UnsupportedPolicy,
    UnsupportedEffect,
};

const ParsedDocument = struct {
    config: AppConfig,
    palettes: [MAX_PALETTES]NamedPalette,
    palette_count: usize,
};

fn finalizePalette(
    document: *ParsedDocument,
    current: *const NamedPalette,
    has_name: bool,
    has_colors: bool,
) !void {
    if (!has_name or !has_colors) return error.MalformedConfig;
    if (document.palette_count >= document.palettes.len) return error.MalformedConfig;
    document.palettes[document.palette_count] = current.*;
    document.palette_count += 1;
}
```

Keep palette-name duplicate slices only for the duration of parsing; `NamedPalette` continues copying names into `[64:0]u8`.

- [ ] **Step 5: Merge the two state machines into one line loop**

Implement:

```zig
fn parseDocument(content: []const u8) ParseError!ParsedDocument {
    return parseDocumentObserved(content, null);
}

fn parseDocumentObserved(
    content: []const u8,
    line_visits: ?*usize,
) ParseError!ParsedDocument {
    try validateDocumentBytes(content);
    var document = ParsedDocument{
        .config = defaultConfig(),
        .palettes = undefined,
        .palette_count = 0,
    };
    var section: Section = .top;
    var section_name: []const u8 = "";
    var seen_sections = SeenNames{ .buf = undefined, .len = 0 };
    var seen_keys = SeenKeys{ .buf = undefined, .len = 0 };
    var seen_palette_names = SeenNames{ .buf = undefined, .len = 0 };
    var current_palette = std.mem.zeroes(NamedPalette);
    var palette_active = false;
    var palette_has_name = false;
    var palette_has_colors = false;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        if (line_visits) |visits| visits.* += 1;
        const line = stripComment(std.mem.trim(u8, raw_line, &std.ascii.whitespace));
        if (line.len == 0) continue;
        // Section transitions finalize an active palette before updating
        // section state. The existing base-key switch and palette-key switch
        // execute here, never in a second content iterator.
    }
    if (palette_active) {
        try finalizePalette(
            &document,
            &current_palette,
            palette_has_name,
            palette_has_colors,
        );
    }
    return document;
}
```

Move the existing base-key branches unchanged into this loop. Move palette `name`/`colors` handling into `.palettes_entry`. On each new section, finalize the previous palette first; initialize per-entry duplicate flags only for a new `[[palettes]]`. Preserve strict malformed-section rejection from the original first pass.

- [ ] **Step 6: Replace both wrappers with the single document result**

```zig
fn parseAndValidate(content: []const u8) ParseError!AppConfig {
    return (try parseDocument(content)).config;
}

fn parseAndValidateFull(
    allocator: std.mem.Allocator,
    content: []const u8,
) (ParseError || std.mem.Allocator.Error)!LoadResult {
    const document = try parseDocument(content);
    const palettes = try allocator.dupe(
        NamedPalette,
        document.palettes[0..document.palette_count],
    );
    return .{ .config = document.config, .palettes = palettes };
}
```

Delete the old second iterator and its duplicate palette state. `parseAndValidate` now also validates palette entries; this intentional convergence is covered by parity tests.

- [ ] **Step 7: Prove parity, one loop, and one wrapper allocation**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-p3c-t3 zig test src/config/config.zig
test "$(rg -n "splitScalar\(u8, content, '\\n'\)" src/config/config.zig | wc -l)" -eq 1
rg -n 'allocator\.(alloc|dupe|create)' src/config/config.zig
zig fmt --check src/config/config.zig
git diff --check
```

Expected: one content line iterator; allocation matches remain in loaders/path resolution and the final palette duplication, never in lexical/document parsing.

- [ ] **Step 8: Commit the one-pass parser**

```sh
git add src/config/config.zig
git commit -m "refactor(config): parse config document in one pass"
```

---

### Task 4: Make frame-interval application transactional

**Files:**

- Modify: `src/app.zig:34-90,1214-1237,1346-1393`
- Modify: `src/config/config.zig:22-28`
- Create: `tests/wayland_egl/app_reload_test.zig`
- Modify: `build.zig`

**Interfaces:**

- Consumes: `sys.timerfdSettime`, `App.timer_armed`, `App.tfd`, and validated nanosecond intervals.
- Produces: `App.applyFrameIntervalWith`, production `App.applyFrameInterval`, `App.applyReloadSnapshotWith`, and `TestAdapter` entries for deterministic fake timer/application operations.

- [ ] **Step 1: Add the test artifact and RED timer tests**

Wire `tests/wayland_egl/app_reload_test.zig` through `wayland_test`; add its run artifact to both `test-wayland-egl` and `test`.

Create a minimal App fixture that initializes only `timer_armed`, `tfd`, and `frame_interval_ns`, plus:

```zig
const FakeTimer = struct {
    calls: usize = 0,
    last_fd: ?std.posix.fd_t = null,
    last_interval: ?std.os.linux.itimerspec = null,
    fail: bool = false,

    fn set(self: *@This(), fd: std.posix.fd_t, value: *const std.os.linux.itimerspec) !void {
        self.calls += 1;
        self.last_fd = fd;
        self.last_interval = value.*;
        if (self.fail) return error.TimerFdSetTimeFailed;
    }
};
```

Add tests for armed success, armed failure, and disarmed no-syscall:

```zig
test "armed frame interval commits only after timer success" {
    var app: App = undefined;
    app.timer_armed = true;
    app.tfd = 42;
    app.frame_interval_ns = 66_666_667;
    var timer = FakeTimer{};
    try App.TestAdapter.applyFrameInterval(&app, 33_333_333, FakeTimer, &timer);
    try std.testing.expectEqual(@as(usize, 1), timer.calls);
    try std.testing.expectEqual(@as(u32, 33_333_333), app.frame_interval_ns);
}

test "armed frame interval failure preserves stored interval" {
    var app: App = undefined;
    app.timer_armed = true;
    app.tfd = 42;
    app.frame_interval_ns = 66_666_667;
    var timer = FakeTimer{ .fail = true };
    try std.testing.expectError(
        error.TimerFdSetTimeFailed,
        App.TestAdapter.applyFrameInterval(&app, 33_333_333, FakeTimer, &timer),
    );
    try std.testing.expectEqual(@as(u32, 66_666_667), app.frame_interval_ns);
}
```

The disarmed test expects `calls == 0` and the new stored interval.

- [ ] **Step 2: Run RED**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-p3c-t4-red \
  zig build test-wayland-egl --summary all
```

Expected: fail because the TestAdapter API and shared helper do not exist.

- [ ] **Step 3: Implement the generic test seam and production adapter**

Add a private generic helper:

```zig
fn applyFrameIntervalWith(
    self: *App,
    interval_ns: u32,
    comptime Timer: type,
    timer: *Timer,
) !void {
    if (self.timer_armed) {
        const interval = linux.itimerspec{
            .it_value = .{ .sec = 0, .nsec = interval_ns },
            .it_interval = .{ .sec = 0, .nsec = interval_ns },
        };
        try timer.set(self.tfd, &interval);
    }
    self.frame_interval_ns = interval_ns;
}
```

The production adapter's `set` calls `sys.timerfdSettime`. `App.applyFrameInterval` delegates to it. Expose the generic call through `App.TestAdapter` under `builtin.is_test` with this exact signature:

```zig
pub fn applyFrameInterval(
    app: *App,
    interval_ns: u32,
    comptime Timer: type,
    timer: *Timer,
) !void {
    return app.applyFrameIntervalWith(interval_ns, Timer, timer);
}
```

- [ ] **Step 4: Replace `set-fps` duplication and prepare reload rollback**

`handleSetFps` computes the same checked `u32` interval, calls `applyFrameInterval`, formats the existing `timerfd_settime failed` error, and queues `ok` only on success. Remove its inline `itimerspec`/assignment duplication.

Add the owned-result cleanup method inside the existing `LoadResult` declaration now so timer rollback and every later job path share it:

```zig
pub fn deinit(result: *LoadResult, allocator: std.mem.Allocator) void {
    allocator.free(result.palettes);
    result.* = undefined;
}
```

Add an App-level helper with exact ownership:

```zig
fn applyReloadSnapshotWith(
    self: *App,
    candidate: *config_mod.LoadResult,
    comptime Timer: type,
    timer: *Timer,
) !void;
```

It calls the supplied timer operation before any filter/scale/effect/palette mutation. On error it calls `candidate.deinit(self.allocator)` and leaves every App field unchanged. On success it consumes `candidate.palettes` into App after all non-failing runtime mutations and invalidates the candidate. Keep asynchronous job integration for Task 6; this task tests the helper directly with a full fixture and a failing timer.

- [ ] **Step 5: Run focused GREEN and commit**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-p3c-t4 \
  zig build test-wayland-egl --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-p3c-t4 \
  zig build test-ipc --summary all
zig fmt --check build.zig src tests
git diff --check
git add src/app.zig src/config/config.zig \
  tests/wayland_egl/app_reload_test.zig build.zig
git commit -m "fix(app): apply frame intervals transactionally"
```

Expected: set-fps and reload-snapshot timer tests pass; existing GPU fallback/reload-effect tests remain green.

---
### Task 5: Add the heap-stable pollable ReloadJob

**Files:**

- Create: `src/config/reload_job.zig`
- Create: `tests/ipc/reload_job_test.zig`
- Modify: `src/config/config.zig:22-28,73-178`
- Modify: `src/sys.zig:1-128`
- Modify: `src/test_ipc_exports.zig`
- Modify: `src/test_wayland_exports.zig`
- Modify: `build.zig:6-16,105-164,206-378`

**Interfaces:**

- Consumes: Task 3 one-pass parser, Task 4 `LoadResult.deinit`, thread-safe allocator, App's process-lifetime `std.Io`, existing `IpcConnection`.
- Produces: `ResolvedConfigPath`, `loadConfigFullResolved`, eventfd wrappers, `ReloadJob`, `ReloadOps`, and `zig build test-reload`.

- [ ] **Step 1: Add Phase 3C options and focused test wiring**

At the top of `build.zig`, add:

```zig
const reload_delay_ms = b.option(
    u32,
    "phase3c-reload-delay-ms",
    "Delay reload worker file loading for live responsiveness testing",
) orelse 0;
const force_reload_timer_failure = b.option(
    bool,
    "phase3c-force-reload-timer-failure",
    "Force only reload frame-interval application to fail",
) orelse false;
daemon_options.addOption(u32, "phase3c_reload_delay_ms", reload_delay_ms);
daemon_options.addOption(
    bool,
    "phase3c_force_reload_timer_failure",
    force_reload_timer_failure,
);
```

Attach `daemon_options` to `ipc_dispatch_mod`, export `reload_job` from both test shims, and add `tests/ipc/reload_job_test.zig` to `test-ipc`, aggregate `test`, and a new `test-reload` step. Task 6 will add its App artifact to the same step.

- [ ] **Step 2: Add RED syscall and ownership tests**

In `tests/ipc/reload_job_test.zig`, add:

```zig
test "eventfd is nonblocking close-on-exec and transfers one native token" {
    const fd = try ipc.sys.eventfdCreate();
    defer ipc.sys.close(fd);
    try expectNonblocking(fd);
    try expectCloseOnExec(fd);
    try std.testing.expectError(error.WouldBlock, ipc.sys.eventfdRead(fd));
    try ipc.sys.eventfdWrite(fd, 1);
    try std.testing.expectEqual(@as(u64, 1), try ipc.sys.eventfdRead(fd));
}
```

Reuse the `fcntl` flag assertions from `tests/ipc/server_test.zig` without changing that file. Add RED tests for create failure, spawn failure, loaded result publication, loader error publication, notification write failure, `joinOnce`, client orphaning, and deinit of an unconsumed palette result.

Use a fake loader returning a fully owned result:

```zig
fn successfulLoad(
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: std.Io,
    _: config.ResolvedConfigPath,
) !config.LoadResult {
    _ = context;
    return .{
        .config = config.defaultConfig(),
        .palettes = try allocator.alloc(config.NamedPalette, 0),
    };
}
```

- [ ] **Step 3: Run RED**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-p3c-t5-red \
  zig build test-reload --summary all
```

Expected: fail because eventfd, resolver, operations, and job APIs do not exist.

- [ ] **Step 4: Add dedicated eventfd wrappers**

In `src/sys.zig`, define exact checked operations:

```zig
pub fn eventfdCreate() error{EventFdCreateFailed}!fd_t;
pub fn eventfdRead(fd: fd_t) error{ WouldBlock, ShortRead, EventFdReadFailed }!u64;
pub fn eventfdWrite(
    fd: fd_t,
    value: u64,
) error{ WouldBlock, ShortWrite, EventFdWriteFailed }!void;
```

Use `linux.eventfd(0, linux.EFD.NONBLOCK | linux.EFD.CLOEXEC)`. Read/write exactly `@sizeOf(u64)` native-endian bytes with `linux.read`/`linux.write`; retry `.INTR`, map `.AGAIN` to `WouldBlock`, reject zero/short records, and never spin on `WouldBlock`.

- [ ] **Step 5: Split reload path resolution from worker file I/O**

Add to `src/config/config.zig`:

```zig
pub const ConfigPathOrigin = enum { explicit, default };

pub const ResolvedConfigPath = struct {
    path: []const u8,
    origin: ConfigPathOrigin,
};

pub fn resolveConfigPathForReload(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    explicit_path: ?[]const u8,
) !ResolvedConfigPath;

pub fn loadConfigFullResolved(
    allocator: std.mem.Allocator,
    io: std.Io,
    resolved: ResolvedConfigPath,
) !LoadResult;
```

The resolver performs only environment lookup/path allocation and always returns an allocator-owned `path` that its caller must free. `ReloadJob.start` duplicates `resolved.path`, so the resolver's allocation is freed by the main thread immediately after start returns. `origin` preserves current missing-file mapping: default missing is `ConfigFileNotFound`; explicit read failure remains `ConfigFileError`.

Use Task 4's `LoadResult.deinit` on every post-load rejection and unconsumed-job path.

- [ ] **Step 6: Define exact ReloadJob state and operations**

Create `src/config/reload_job.zig` with:

```zig
pub const Phase = enum { loading, responding, orphaned };

pub const LoadOutcome = union(enum) {
    pending,
    loaded: config.LoadResult,
    failed: anyerror,
};

pub const ReloadOps = struct {
    context: ?*anyopaque = null,
    load: *const fn (
        ?*anyopaque,
        std.mem.Allocator,
        std.Io,
        config.ResolvedConfigPath,
    ) anyerror!config.LoadResult,
    eventfd_create: *const fn (?*anyopaque) anyerror!posix.fd_t,
    eventfd_read: *const fn (?*anyopaque, posix.fd_t) anyerror!u64,
    eventfd_write: *const fn (?*anyopaque, posix.fd_t, u64) anyerror!void,
    thread_start: *const fn (?*anyopaque, *ReloadJob) anyerror!std.Thread,
    monotonic_ns: *const fn (?*anyopaque) anyerror!u64,
};

pub const ReloadJob = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    ops: ReloadOps,
    path: []u8,
    path_origin: config.ConfigPathOrigin,
    event_fd: posix.fd_t,
    thread: ?std.Thread,
    ready: std.atomic.Value(bool),
    outcome: LoadOutcome,
    notification_error: ?anyerror,
    notification_fault: bool,
    client: ?IpcConnection,
    phase: Phase,

    pub fn start(
        allocator: std.mem.Allocator,
        io: std.Io,
        resolved: config.ResolvedConfigPath,
        ops: ReloadOps,
    ) !*ReloadJob;
    pub fn takeClient(self: *ReloadJob, source: *?IpcConnection) void;
    pub fn readyAcquire(self: *const ReloadJob) bool;
    pub fn joinOnce(self: *ReloadJob) void;
    pub fn takeOutcomeAfterJoin(self: *ReloadJob) LoadOutcome;
    pub fn orphanClient(self: *ReloadJob) void;
    pub fn deinit(self: *ReloadJob) void;
};

pub const production_ops = ReloadOps{
    .load = productionLoad,
    .eventfd_create = productionEventfdCreate,
    .eventfd_read = productionEventfdRead,
    .eventfd_write = productionEventfdWrite,
    .thread_start = productionThreadStart,
    .monotonic_ns = productionMonotonicNs,
};
```

`start` allocates/copies the job/path, creates eventfd, and spawns in that order. On any error it frees/closes everything it acquired and leaves the caller's connection untouched. Store `ReloadOps` by value; its context must outlive the job.

The production adapters directly call `config.loadConfigFullResolved`, the Task 5 `sys.eventfd*` wrappers, `std.Thread.spawn(.{}, workerMain, .{job})`, and `sys.monotonicNsChecked`. They do not capture App or environment state.

- [ ] **Step 7: Implement worker publication and teardown**

The worker implementation is:

```zig
fn workerMain(job: *ReloadJob) void {
    const resolved = config.ResolvedConfigPath{
        .path = job.path,
        .origin = job.path_origin,
    };
    const loaded = job.ops.load(
        job.ops.context,
        job.allocator,
        job.io,
        resolved,
    );
    job.outcome = if (loaded) |value|
        .{ .loaded = value }
    else |err|
        .{ .failed = err };
    job.ready.store(true, .release);
    job.ops.eventfd_write(job.ops.context, job.event_fd, 1) catch |err| {
        job.notification_error = err;
    };
}
```

The main thread calls `joinOnce` before reading `outcome` or `notification_error`; `joinOnce` clears the optional handle before calling `join`. `takeOutcomeAfterJoin` asserts `thread == null` and replaces the stored outcome with `.pending`, so App and job can never both own the loaded palette slice. `deinit` joins if needed, closes the client/eventfd, calls `LoadResult.deinit` for an unconsumed `.loaded` outcome, frees the path, and destroys the job.

The production loader executes the default-off delay with Zig 0.16 I/O:

```zig
if (build_options.phase3c_reload_delay_ms > 0) {
    try std.Io.sleep(
        io,
        .fromMilliseconds(build_options.phase3c_reload_delay_ms),
        .awake,
    );
}
return config.loadConfigFullResolved(allocator, io, resolved);
```

- [ ] **Step 8: Prove start rollback, publication, and one-owner teardown**

Use injected `ReloadOps` to fail each start operation before connection transfer. Use `std.testing.FailingAllocator` for allocation boundaries. Use an atomic/futex gate for delayed worker tests rather than sleeps:

```zig
// Field in the fake loader state:
gate: u32 align(4) = 0,

while (@atomicLoad(u32, &state.gate, .acquire) == 0) {
    std.Io.futexWaitUncancelable(io, u32, &state.gate, 0);
}
```

The releasing test stores `1` and calls `std.Io.futexWake`. Assert every successful result is freed once, every fd is closed once, the job joins once, and orphaning closes only its transferred client.

- [ ] **Step 9: Run GREEN and commit**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-p3c-t5 \
  zig build test-reload --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-p3c-t5 \
  zig build test-ipc --summary all
zig fmt --check build.zig src tests
git diff --check
git add build.zig src/sys.zig src/config/config.zig src/config/reload_job.zig \
  src/test_ipc_exports.zig src/test_wayland_exports.zig \
  tests/ipc/reload_job_test.zig
git commit -m "feat(config): add pollable reload jobs"
```

---

### Task 6: Integrate deferred reload into App's poll and IPC lifecycle

**Files:**

- Modify: `src/app.zig:34-95,735-1182,1346-1431`
- Modify: `tests/wayland_egl/app_reload_test.zig`
- Modify: `build.zig`

**Interfaces:**

- Consumes: Task 4 timer transaction and Task 5 `ReloadJob`/`ReloadOps`/resolved path APIs.
- Produces: six-slot polling, deferred connection transfer, aggregate deadlines, background completion/application, `shutdown_pending`, full cleanup, and narrow `TestAdapter.serviceIpc`/`pollTimeoutAt`/`serviceReloadReady` hooks.

- [ ] **Step 1: Add RED deferred-dispatch and busy tests**

Extend the App fixture with a fake `ReloadOps`, normal `IpcConnection`, owned empty palette slice, and these assertions:

```zig
const FakeReloadOps = struct {
    thread_starts: usize = 0,
    loads: usize = 0,
    gate: u32 align(4) = 0,

    fn table(self: *@This()) reload_job.ReloadOps;
};

const AppReloadFixture = struct {
    allocator: std.mem.Allocator,
    app: App,
    ops_state: *FakeReloadOps,
    peer_fd: std.posix.fd_t,

    fn init(allocator: std.mem.Allocator) !@This();
    fn deinit(self: *@This()) void;
    fn acceptReload(self: *@This()) !void;
    fn issueSecondReload(self: *@This()) !void;
    fn expectNormalResponse(self: *@This(), expected: []const u8) !void;
};
```

`FakeReloadOps.table` returns the Task 5 operations table whose callbacks cast `context` back to this heap object and increment the named counters; its loader waits on `gate` only in tests that request blocking. `init` heap-allocates `ops_state` before installing its pointer, creates one nonblocking Unix socketpair, builds the existing minimal manual App fixture pattern, and puts one endpoint in `app.ipc_client`. This avoids storing a context pointer into a fixture that could move when returned by value. `deinit` closes the peer, calls the exact App/job/palette cleanup paths initialized by the fixture, then destroys `ops_state`. `acceptReload` writes `reload\n` to the peer and calls `App.TestAdapter.serviceIpc`; the other two helpers create/service a separate normal client and compare its queued response bytes.

```zig
test "accepted reload transfers the whole connection and defers response" {
    var fixture = try AppReloadFixture.init(std.testing.allocator);
    defer fixture.deinit();
    try fixture.acceptReload();
    try std.testing.expect(fixture.app.ipc_client == null);
    try std.testing.expect(fixture.app.reload_job != null);
    try std.testing.expect(fixture.app.reload_job.?.client != null);
    try std.testing.expectEqual(reload_job.Phase.loading, fixture.app.reload_job.?.phase);
    try std.testing.expectEqual(connection.State.reading, fixture.app.reload_job.?.client.?.state);
    try std.testing.expectEqual(@as(usize, 0), fixture.app.reload_job.?.client.?.response.len);
}

test "second reload reports busy without starting another worker" {
    var fixture = try AppReloadFixture.init(std.testing.allocator);
    defer fixture.deinit();
    try fixture.acceptReload();
    const starts_before = fixture.ops_state.thread_starts;
    try fixture.issueSecondReload();
    try std.testing.expectEqual(starts_before, fixture.ops_state.thread_starts);
    try fixture.expectNormalResponse("error: reload already in progress\n");
}
```

Also add start-failure tests proving the original client stays in `App.ipc_client` and enters the ordinary bounded writing state.

- [ ] **Step 2: Add RED aggregate timeout and notification-fallback tests**

Add tests for:

```zig
test "poll timeout is the minimum of normal and reload response deadlines";
test "loading reload caps an otherwise infinite poll at 500 milliseconds";
test "normal and reload clients expire independently";
test "notification write failure completes through fallback with zero outputs";
test "permanent notification read fault rejects application";
test "notification WouldBlock never reads unpublished outcome";
```

Use fake monotonic timestamps and call TestAdapter helpers directly; do not wait 500 real milliseconds. A clock failure closes the affected response connection and follows its shutdown flag.

- [ ] **Step 3: Add RED application, orphan, and stop-order tests**

Create a candidate snapshot that differs in every runtime field. Test:

```zig
test "completed reload applies once then starts a fresh response deadline";
test "timer failure frees candidate and preserves every App field";
test "client HUP while loading still applies then discards response";
test "stop request readiness suppresses simultaneous reload completion";
test "pending stop response suppresses simultaneous reload completion";
test "shutdown joins worker and frees an unconsumed result exactly once";
```

For preservation, copy and compare FPS, configured/running effect tags, animation phase/speed, palette data/slice pointer, current palette, renderer scale, filter, fade, active-name bytes/length, and GPU upload state.

- [ ] **Step 4: Run RED**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-p3c-t6-red \
  zig build test-reload --summary all
```

Expected: the App-focused tests fail because App still has one IPC slot and synchronous reload.

- [ ] **Step 5: Add App ownership fields and deferred command outcome**

Add:

```zig
reload_job: ?*reload_job_mod.ReloadJob,
reload_ops: reload_job_mod.ReloadOps,
shutdown_pending: bool,
```

Import the module as `reload_job_mod`; initialize the fields to `null`, `reload_job_mod.production_ops`, and `false`. Replace `CommandOutcome` with:

```zig
const CommandOutcome = enum {
    response_ready,
    deferred_reload,
    shutdown_after_flush,
};
```

`queueCommandResponse` calls `beginIpcResponse` only for `response_ready` and `shutdown_after_flush`. For `deferred_reload`, it returns without borrowing `client` again. Refactor the read-complete branch so terminal HUP after transfer is routed to `reload_job.orphanClient()` rather than the former optional pointer.

Expose only these private-state transitions to out-of-tree tests:

```zig
pub fn serviceIpc(app: *App, revents: i16, now_ns: u64) void;
pub fn pollTimeoutAt(app: *App, now_ns: u64) i32;
pub fn serviceReloadReady(app: *App) void;
```

Each TestAdapter method delegates directly to the named production helper; no test-only branch enters the normal daemon path.

- [ ] **Step 6: Start reload transactionally and move the connection once**

Replace synchronous `handleReload` with a start method that:

```zig
fn beginReload(self: *App) !void {
    if (self.reload_job != null) return error.ReloadAlreadyInProgress;
    const resolved = try config_mod.resolveConfigPathForReload(
        self.allocator,
        self.environ,
        self.config_path,
    );
    defer self.allocator.free(resolved.path);
    const job = try reload_job_mod.ReloadJob.start(
        self.allocator,
        self.io,
        resolved,
        self.reload_ops,
    );
    job.takeClient(&self.ipc_client);
    self.reload_job = job;
}
```

Map busy/start/path errors to the existing human-readable `error:` response through the still-owned normal client. Only successful start returns `.deferred_reload`. End every request-slice and client-pointer borrow before `takeClient`.

- [ ] **Step 7: Expand polling and aggregate all deadlines**

Use fixed slots:

```zig
var fds = [6]posix.pollfd{
    .{ .fd = wl_fd, .events = linux.POLL.IN, .revents = 0 },
    .{ .fd = self.tfd, .events = linux.POLL.IN, .revents = 0 },
    .{ .fd = self.sig_fd, .events = linux.POLL.IN, .revents = 0 },
    .{ .fd = -1, .events = 0, .revents = 0 },
    .{ .fd = -1, .events = 0, .revents = 0 },
    .{ .fd = -1, .events = 0, .revents = 0 },
};
```

Slot 4 polls job eventfd for `POLL.IN`; slot 5 uses events `0` while loading and the transferred client's `pollEvents()` while responding. Terminal bits are always inspected.

Replace `ipcPollTimeout` with a helper that returns `-1` without a clock read when no client/job deadline exists. Otherwise expire normal and reload response clients independently, compute their minimum `timeoutMs`, and clamp loading jobs to `500`. Call expiration before poll and after pending Wayland dispatch.

- [ ] **Step 8: Service each poll batch in shutdown-safe order**

After Wayland/timer work, service:

1. signal fd;
2. normal IPC slot;
3. reload client terminal/write state;
4. reload eventfd or the atomic fallback check.

Change stop handling to:

```zig
fn handleStop(self: *App, out: *ResponseQueue) void {
    self.shutdown_pending = true;
    dispatch.appendOk(out);
}
```

The stop response still sets `shutdown_after_flush`; its close transitions `running` to false. A reload completion begins with:

```zig
if (!self.running or self.shutdown_pending) return;
```

The fallback checks `readyAcquire` even when eventfd produced no event. Transient `WouldBlock` is retried by a later poll/fallback. Permanent/short/terminal notifier faults latch `notification_fault` and reject application after join.

- [ ] **Step 9: Join, apply transactionally, and respond only after completion**

On readiness:

1. call `joinOnce`;
2. read `notification_error`/fault and call `takeOutcomeAfterJoin` exactly once;
3. reject and free on notification/load failure;
4. call Task 4's frame interval helper before every other mutation;
5. apply filter, scale, fade cancellation, effect/animation/palette, and active-name reset on the main thread;
6. move the new palette slice into App and free the old slice;
7. queue `ok` or `error:` on the job client with a fresh monotonic response deadline;
8. destroy immediately if orphaned, otherwise keep phase `.responding` until complete/timeout/terminal.

Under `build_options.phase3c_force_reload_timer_failure`, only step 4 uses the failing timer adapter; ordinary `set-fps` keeps the production adapter.

- [ ] **Step 10: Make deinit complete every ownership path**

Before existing App fd/GPU/surface teardown:

```zig
self.closeIpcClient();
if (self.reload_job) |job| {
    job.deinit();
    self.reload_job = null;
}
```

Job deinit closes its client, joins before closing eventfd/freeing path, and frees an unconsumed result. Do not destroy or detach a running worker.

- [ ] **Step 11: Run focused GREEN, static checks, and commit**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-p3c-t6 \
  zig build test-reload --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-p3c-t6 \
  zig build test-ipc --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-p3c-t6 \
  zig build test-wayland-egl --summary all
! rg -n 'loadConfigFullRequireFile' src/app.zig
rg -n 'reload_job|shutdown_pending|\[6\]posix\.pollfd' src/app.zig
zig fmt --check build.zig src tests
git diff --check
git add src/app.zig tests/wayland_egl/app_reload_test.zig build.zig
git commit -m "fix(ipc): keep runtime responsive during reload"
```

Expected: all focused suites pass; App command dispatch contains no config file read or parser call.

---

### Task 7: Update the shipped and maintainer-local contracts

**Files:**

- Modify: `README.md:5-8,54-81,101-151,170-230`
- Modify: `AGENTS.md:8-20`
- Modify maintainer-local: `/home/px/wlchroma/specs/001-effect-system/contracts/config-schema.md`
- Modify maintainer-local: `/home/px/wlchroma/specs/004-runtime-ipc-ctl/data-model.md`
- Modify maintainer-local: `/home/px/wlchroma/specs/004-runtime-ipc-ctl/contracts/ipc-protocol.md`
- Modify maintainer-local: `/home/px/wlchroma/specs/007-runtime-effect-switching/contracts/reload-behavior.md`
- Modify maintainer-local: `/home/px/wlchroma/specs/010-config-version-consolidation/spec.md`

**Interfaces:**

- Consumes: implemented behavior and exact error/option names from Tasks 1–6.
- Produces: public strict-subset/reload semantics and matching maintainer-local source-of-truth contracts.

- [ ] **Step 1: Document the strict config subset and remove stale version claims**

Add to README Configuration:

```markdown
The file uses wlchroma's supported TOML subset: bare schema keys/sections,
decimal numbers, single-line double-quoted UTF-8 strings, arrays of quoted
strings, `#` comments outside strings, and `[[palettes]]`. Recognized strings
do not support TOML escapes; any backslash in one is rejected. Files must be
valid UTF-8 and may not contain ASCII control bytes other than tab and CRLF/LF
line endings.
```

State that palette names are `1`–`63` UTF-8 bytes. Remove every `config v2` / `config v2 required` phrase from Features, Runtime Control, and direct socket examples; `version` is optional and ignored.

- [ ] **Step 2: Document completion-confirmed asynchronous reload**

Update the reload command text:

```markdown
Reload file reading and parsing run on a transient background worker so
animation, Wayland events, signals, and other IPC remain responsive. Only one
reload may be in progress; another receives
`error: reload already in progress`. The response remains completion-confirmed:
`ok` is written only after the snapshot is applied, and an error leaves the
previous runtime state unchanged.
```

Document the default-off fault builds in AGENTS alongside the Phase 3A option:

```markdown
- Reload fault builds: `zig build -Dphase3c-reload-delay-ms=1500` and
  `zig build -Dphase3c-force-reload-timer-failure=true`.
```

- [ ] **Step 3: Amend maintainer-local specs without staging user files**

In the root checkout's ignored specs:

- spec 001: replace the stale version-gated header with the strict subset and recognized-string rules;
- spec 004 data model: make palette-name limit 63 UTF-8 bytes;
- spec 004 IPC contract: add one-in-flight busy error, background file/parse work, unrelated IPC responsiveness, disconnect semantics, and completion-confirmed response;
- spec 007 reload contract: add timer-failure atomicity, worker/main-thread boundary, stop precedence, and zero-output behavior;
- spec 010: keep `version` value-agnostic while applying document-wide UTF-8/control/key-value structure.

Do not stage or edit `EFFICIENCY_AUDIT.md`, `EFFICIENCY_AUDIT_2.md`, `EFFICIENCY_AUDIT_3.md`, or `mpris-wlchroma-audit-transcript.txt`.

- [ ] **Step 4: Verify documentation parity and commit tracked docs**

```sh
rg -n 'config v2|v2 required' README.md
rg -n 'supported TOML subset|reload already in progress|completion' README.md
rg -n 'phase3c-reload-delay-ms|phase3c-force-reload-timer-failure' AGENTS.md build.zig
git diff --check
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-p3c-t7 zig build test --summary all
git add README.md AGENTS.md
git commit -m "docs(config): document strict asynchronous reload"
```

Expected: the first `rg` has no matches; the tracked commit excludes ignored specs and all four user-owned files. Record the ignored spec diff separately in the Phase 3C evidence report.

---

### Task 8: Run full, live, review, and audit closeout gates

**Files:**

- Modify after approval: `docs/security/2026-07-19-security-performance-audit.md:35-67,148-168,331-end`
- Create ignored evidence: `.superpowers/sdd/phase3c-verification.md`

**Interfaces:**

- Consumes: Tasks 1–7 and the approved Phase 3C design.
- Produces: reproducible verification evidence, restored live session, independent review, and exact Fixed dispositions for the four canonical rows.

- [ ] **Step 1: Run static and focused verification from a clean tree**

```sh
zig version
zig fmt --check build.zig bench src tests
git diff --check
git diff --check 1ccbee5
test "$(rg -n "splitScalar\(u8, content, '\\n'\)" src/config/config.zig | wc -l)" -eq 1
! rg -n 'loadConfigFullRequireFile' src/app.zig
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-p3c-final-config zig test src/config/config.zig
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-p3c-final-ipc zig build test-ipc --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-p3c-final-reload zig build test-reload --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-p3c-final-wayland zig build test-wayland-egl --summary all
```

Record exact step/test totals and operation-count matches; do not summarize a command as passing unless its exit status is zero.

- [ ] **Step 2: Run the complete optimization matrix**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-p3c-final-debug \
  zig build -Doptimize=Debug
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-p3c-final-debug \
  zig build -Doptimize=Debug test --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-p3c-final-safe \
  zig build -Doptimize=ReleaseSafe
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-p3c-final-safe \
  zig build -Doptimize=ReleaseSafe test --summary all
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-p3c-final-fast \
  zig build -Doptimize=ReleaseFast
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-p3c-final-fast \
  zig build -Doptimize=ReleaseFast test --summary all
```

Expected: every build and full suite passes in all three modes.

- [ ] **Step 3: Build isolated normal and fault binaries**

```sh
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-p3c-live-normal \
  zig build -Doptimize=ReleaseSafe --prefix /tmp/wlchroma-p3c-normal
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-p3c-live-delay \
  zig build -Doptimize=ReleaseSafe -Dphase3c-reload-delay-ms=1500 \
  --prefix /tmp/wlchroma-p3c-delay
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-p3c-live-timer \
  zig build -Doptimize=ReleaseSafe \
  -Dphase3c-force-reload-timer-failure=true \
  --prefix /tmp/wlchroma-p3c-timer-failure
```

Check required tools before use with `command -v niri`, `command -v socat`, and `command -v sha256sum`; do not install missing packages during verification. `wlchroma-ctl` is available from each prefix.

- [ ] **Step 4: Capture live state and request the interruption checkpoint**

Record:

```sh
pgrep -a -f '/wlchroma([[:space:]]|$)'
readlink -f "/proc/$daemon_pid/exe"
tr '\0' ' ' < "/proc/$daemon_pid/cmdline"
readlink -f "/proc/$daemon_pid/cwd"
sha256sum "$config_path"
wlchroma-ctl query
niri msg outputs
```

Also record the exact socket owner and `mpris-chroma` process/service state. Present the capture and restoration commands to the user before signaling the exact PID. Do not use `pkill` or a name-wide signal.

- [ ] **Step 5: Run normal and delayed live acceptance**

After approval, stop only the captured daemon PID, launch the isolated daemon with a temporary explicit config, and verify:

- normal reload changes FPS, effect, speed, palette, scale, and filter, then `query` reports the completed values;
- invalid escape, malformed file, and missing file return `error:` with the before/after query identical;
- during a 1500 ms delayed reload, animation visibly continues and separate `query` returns before the reload finishes;
- a second reload during that delay returns `error: reload already in progress`;
- disconnecting the first client does not cancel application;
- `stop` remains accepted during delayed loading, then teardown waits safely for worker join;
- logs contain no allocator, ownership, eventfd, timer, EGL, or stale-completion warning.

Use monotonic timestamps around the delayed reload and separate query. Report responsiveness latency as evidence for PERF-L1, not as a general render-throughput benchmark.

- [ ] **Step 6: Run timer-failure and zero-output live acceptance**

Launch the timer-failure build, capture `query`, issue reload with a different config, and prove the error plus byte-for-byte unchanged query/state.

Before zero-output testing, identify the exact Niri output and arm a tested 15-second recovery command that turns that same output back on. Obtain explicit user confirmation, then:

1. disable only that resolved output;
2. prove the daemon remains query-responsive;
3. reload a different FPS while zero-output;
4. re-enable the output and prove the stored interval is used;
5. cancel/wait the recovery process only after the output is visibly restored.

Skip no safety step even if the compositor previously recovered correctly.

- [ ] **Step 7: Restore and prove the original session state**

Stop only the isolated PID. Restore the exact prior executable, argv, cwd, config hash, socket/query state, output mode/scale, and `mpris-chroma` state. Verify fresh process evidence and the original config hash. If any restoration check differs, keep working and do not close the audit.

- [ ] **Step 8: Request independent two-stage review**

Dispatch one requirements reviewer against the approved design/plan and one code-quality reviewer against `1ccbee5..HEAD`. Require explicit review of:

- all four audit mappings;
- worker/result atomic ordering and address stability;
- connection/path/palette/fd/thread ownership on every error and shutdown path;
- aggregate deadlines, notification fallback, stop precedence, and zero-output semantics;
- strict parser compatibility and one-pass evidence;
- build-option default-off overhead and documentation parity;
- automated/live limitations and restoration evidence.

Resolve every Critical, Important, and Minor finding with a focused test and commit before continuing.

- [ ] **Step 9: Update the canonical ledger only after approval**

Change exactly `APP-L2`, `PERF-L1`, `CONF-L1`, and `BUILD-L1` from Open to Fixed. Add a Phase 3C closeout section containing exact commit IDs, test totals, mode matrix, policy probes, static counts, live/fault evidence, independent review verdict, restoration evidence, and truthful unavailable claims.

```sh
git diff --check
git add docs/security/2026-07-19-security-performance-audit.md
git commit -m "docs(security): close phase 3c audit findings"
```

- [ ] **Step 10: Final verification, branch review, push, and CI**

```sh
zig fmt --check build.zig bench src tests
git diff --check
git diff --check 1ccbee5
ZIG_GLOBAL_CACHE_DIR=/tmp/wlchroma-p3c-final-head zig build test --summary all
git status --short --branch
git log --oneline 1ccbee5..HEAD
```

Expected: branch worktree is clean. The root checkout still lists only the four pre-existing user-owned untracked files plus intentional ignored maintainer-spec edits.

After user approval, push `phase-3c-config-reload-closeout`, verify GitHub Lint and Test are green at the branch head, merge locally with the chosen non-destructive strategy, rerun the full test suite on merged `main`, push `main`, and verify origin is `0/0`. Do not remove the worktree until merged-main verification and retained evidence are complete.

---

## Completion record

Phase 3C is complete only when every task checkbox is satisfied, all four canonical rows have independently approved Fixed evidence, the live session is restored, GitHub Lint/Test are green, merged `main` passes the full suite, and the user-owned audit/transcript files remain untouched.
