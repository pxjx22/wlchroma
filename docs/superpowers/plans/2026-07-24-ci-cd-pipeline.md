# CI/CD Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single `.github/workflows/ci.yml` with three independent workflows (lint, test, release) as designed in `docs/superpowers/2026-07-24-ci-cd-design.md`.

**Architecture:** Three standalone YAML workflow files in `.github/workflows/`. Lint runs `zig fmt --check` plus shell-scripted custom checks (commit format, TOML validity, no artifacts). Test runs `zig build test` on push/PR. Release triggers on `v*` tags, builds ReleaseSafe, generates changelog from git log, uploads binaries to GitHub Releases.

**Tech Stack:** GitHub Actions YAML, Zig 0.16.0, `mlugg/setup-zig@v2`, `actions/checkout@v4`, `softprops/action-gh-release@v2`, shell scripting.

## Global Constraints

- Zig pinned to **0.16.0** (`.zig-version`)
- System deps: `libegl1-mesa-dev libgles2-mesa-dev libwayland-bin libwayland-dev` (Ubuntu; wayland-scanner provided by libwayland-bin)
- Commit format: `<type>(<scope>): <description>` with types `feat|fix|test|docs|refactor|perf` and scopes `ipc|ctl|config|renderer|build|repo|app|security`; merge commits exempt
- Release optimization: `ReleaseSafe`
- Release trigger: tag matching `v*` (e.g. `v0.2.0`)
- `softprops/action-gh-release@v2` for release uploads

---

### Task 1: Lint workflow

**Files:**
- Create: `.github/workflows/lint.yml`

**Interfaces:**
- Produces: Two jobs — `fmt` (zig fmt --check) and `custom-checks` (commit format, TOML validity, build artifacts) — both run on push and pull_request

- [ ] **Step 1: Create `.github/workflows/lint.yml`**

```yaml
name: Lint

on:
  push:
  pull_request:

jobs:
  fmt:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: mlugg/setup-zig@v2
        with:
          version: 0.16.0
      - name: Check formatting
        run: zig fmt --check src/ tests/ build.zig

  custom-checks:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Commit message format
        run: |
          set -euo pipefail
          PATTERN='^(feat|fix|test|docs|refactor|perf)\((ipc|ctl|config|renderer|build|repo|app|security)\): .+'
          if [ "${{ github.event_name }}" = "pull_request" ]; then
            RANGE="${{ github.event.pull_request.base.sha }}..${{ github.event.pull_request.head.sha }}"
          else
            if [ "${{ github.event.before }}" = "0000000000000000000000000000000000000000" ]; then
              DEFAULT_BRANCH="${{ github.event.repository.default_branch }}"
              BASE=$(git merge-base "origin/$DEFAULT_BRANCH" HEAD 2>/dev/null || echo "")
              if [ -n "$BASE" ]; then
                RANGE="$BASE..HEAD"
              else
                RANGE="HEAD"
              fi
            else
              RANGE="${{ github.event.before }}..${{ github.event.after }}"
            fi
          fi
          BAD=$(git log --no-merges --format="%s" $RANGE | grep -vE "$PATTERN" || true)
          if [ -n "$BAD" ]; then
            echo "Commits with invalid format:"
            echo "$BAD"
            echo ""
            echo "Expected: <type>(<scope>): <description>"
            echo "  types:  feat, fix, test, docs, refactor, perf"
            echo "  scopes: ipc, ctl, config, renderer, build, repo, app, security"
            exit 1
          fi
          echo "All commit messages match format."

      - name: TOML validity
        run: python3 -c "import tomllib; tomllib.load(open('config.toml.example','rb'))"

      - name: Build artifacts check
        run: |
          ARTIFACTS=$(git ls-files zig-out/ .zig-cache/ || true)
          if [ -n "$ARTIFACTS" ]; then
            echo "Build artifacts committed:"
            echo "$ARTIFACTS"
            exit 1
          fi
          echo "No build artifacts committed."
```

- [ ] **Step 2: Verify zig fmt passes locally**

```bash
zig fmt --check src/ tests/ build.zig
echo "exit: $?"
```

Expected: exit 0, no output.

- [ ] **Step 3: Verify custom checks pass locally**

```bash
# TOML check
python3 -c "import tomllib; tomllib.load(open('config.toml.example','rb'))" && echo "TOML OK"

# Artifacts check
git ls-files zig-out/ .zig-cache/
```
Expected: TOML OK, empty output from git ls-files.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/lint.yml
git commit -m "feat(build): add lint workflow with zig fmt and custom checks"
```

---

### Task 2: Test workflow

**Files:**
- Create: `.github/workflows/test.yml`

**Interfaces:**
- Produces: Single job that runs `zig build test` (full suite: unit, IPC, Wayland/EGL, effect, color_fade)

- [ ] **Step 1: Create `.github/workflows/test.yml`**

```yaml
name: Test

on:
  push:
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: mlugg/setup-zig@v2
        with:
          version: 0.16.0

      - name: Install system dependencies
        run: sudo apt-get update && sudo apt-get install -y libegl1-mesa-dev libgles2-mesa-dev libwayland-bin libwayland-dev

      - name: Build
        run: zig build

      - name: Full test suite
        run: zig build test
```

- [ ] **Step 2: Verify test suite runs locally**

```bash
zig build test
```
Expected: exit 0, all 155+ tests pass.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/test.yml
git commit -m "feat(build): add test workflow running full test suite"
```

---

### Task 3: Release workflow

**Files:**
- Create: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: none
- Produces: GitHub Release with `wlchroma` and `wlchroma-ctl` binaries on `v*` tags

- [ ] **Step 1: Create `.github/workflows/release.yml`**

```yaml
name: Release

on:
  push:
    tags:
      - 'v*'

jobs:
  release:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - uses: mlugg/setup-zig@v2
        with:
          version: 0.16.0

      - name: Install system dependencies
        run: sudo apt-get update && sudo apt-get install -y libegl1-mesa-dev libgles2-mesa-dev libwayland-bin libwayland-dev

      - name: Build ReleaseSafe
        run: zig build -Doptimize=ReleaseSafe

      - name: Generate release notes
        run: |
          PREV_TAG=$(git tag --sort=-creatordate | grep '^v' | grep -v "^${{ github.ref_name }}$" | head -1)
          if [ -n "$PREV_TAG" ]; then
            git log --no-merges --pretty=format:'- %s' "$PREV_TAG..${{ github.ref_name }}" > /tmp/release_notes.txt
          else
            git log --no-merges --pretty=format:'- %s' "${{ github.ref_name }}" > /tmp/release_notes.txt
          fi

      - name: Upload release
        uses: softprops/action-gh-release@v2
        with:
          body_path: /tmp/release_notes.txt
          files: |
            zig-out/bin/wlchroma
            zig-out/bin/wlchroma-ctl
```

- [ ] **Step 2: Verify ReleaseSafe build and binary outputs exist**

```bash
zig build -Doptimize=ReleaseSafe
ls -la zig-out/bin/wlchroma zig-out/bin/wlchroma-ctl
```
Expected: both binaries exist and are non-empty executables.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "feat(build): add release workflow triggered by v* tags"
```

---

### Task 4: Remove old CI and finalize

**Files:**
- Remove: `.github/workflows/ci.yml`

- [ ] **Step 1: Remove the old workflow file**

```bash
git rm .github/workflows/ci.yml
```

- [ ] **Step 2: Verify only the three new workflows remain**

```bash
ls .github/workflows/
```
Expected: `lint.yml  release.yml  test.yml` (no `ci.yml`).

- [ ] **Step 3: Commit**

```bash
git commit -m "refactor(build): replace single ci.yml with lint, test, and release workflows"
```

- [ ] **Step 4: Push and verify GitHub Actions**

```bash
git push
```
After push, check the Actions tab on GitHub:
- Lint workflow: both `fmt` and `custom-checks` jobs pass
- Test workflow: `test` job passes (full suite)
- No artifacts committed, commits use valid format.
