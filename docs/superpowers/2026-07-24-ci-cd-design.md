# CI/CD Pipeline Design

**Date:** 2026-07-24
**Status:** approved

## Overview

Replace the single minimal `.github/workflows/ci.yml` with three independent workflow files: lint, test, and release. Each workflow has its own trigger and responsibilities.

## Workflows

### 1. `lint.yml` — Code quality checks

**Trigger:** `push` and `pull_request` on all branches.

**Jobs:**

| Job | Steps |
|-----|-------|
| `fmt` | Checkout, install Zig 0.16.0 via `mlugg/setup-zig@v2`, run `zig fmt --check src/ tests/ build.zig` |
| `custom-checks` | Runs on push and PR (not PR-only). Shell steps: commit message format validation (PR merges validated on the merge commit, single-branch pushes validated on all commits in the push), TOML validity of `config.toml.example`, no committed build artifacts (`zig-out/`, `.zig-cache/`) |

**Custom check details:**

- Commit message format: enforces `<type>(<scope>): <description>` as documented in CONTRIBUTING.md
- TOML check: validates `config.toml.example` is parseable (e.g. `python3 -c "import tomllib; tomllib.load(open('config.toml.example','rb'))"`)
- Build artifact check: `git ls-files zig-out/ .zig-cache/` must return empty

### 2. `test.yml` — Full test suite

**Trigger:** `push` and `pull_request` on all branches.

**Single job:**

- Checkout code
- Install Zig 0.16.0 (`mlugg/setup-zig@v2`)
- Install system deps: `libegl1-mesa-dev libgles2-mesa-dev libwayland-bin libwayland-dev wayland-scanner`
- Run `zig build test` — exercises the complete test suite (unit, IPC, Wayland/EGL lifecycle, effect mutation, color_fade)

This replaces the current convention of only running `zig test src/config/config.zig` in CI.

### 3. `release.yml` — Tag-triggered binary releases

**Trigger:** push of a tag matching `v*` (e.g. `v0.2.0`).

**Single job:**

- Checkout code (with full history for changelog generation)
- Install Zig 0.16.0 + system deps
- Build: `zig build -Doptimize=ReleaseSafe`
- Generate changelog from `git log` between this tag and the previous tag
- Upload `wlchroma` and `wlchroma-ctl` binaries to the GitHub Release via `softprops/action-gh-release@v2`

**Changelog audit caveat:** The release workflow should audit the CHANGELOG (if one exists) in its build/ test step to verify the version in the changelog matches the tag. If no CHANGELOG exists, generate release notes from commit history. This ensures release notes are accurate and complete.

**Build optimization:** `ReleaseSafe` chosen over `ReleaseFast` — bounds checks are worth keeping for a wallpaper daemon.

## What is removed

The existing `.github/workflows/ci.yml` is replaced entirely by the three new files.

## Non-goals

- Matrix builds across OS/arch (Ubuntu latest only, matching current CI)
- Container images or distro packages
- Code coverage reporting
- Benchmark tracking