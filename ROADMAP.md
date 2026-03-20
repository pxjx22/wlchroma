# wlchroma roadmap

This file tracks what is shipped, what still needs polish before wider adoption, and what comes next.

## Current state

wlchroma is now a working Wayland animated wallpaper daemon with:
- EGL + OpenGL ES 2.0 GPU renderer
- CPU/SHM fallback path
- low-power 15fps default pacing
- configurable palette, fps, render scale, and upscale filter via TOML
- multi-output rendering
- basic output removal safety

## Near-term polish

These are the next practical improvements after the current release candidate work.

### Release ergonomics
- Add an autostart section to `README.md`
  - `niri` `spawn-at-startup`
  - `sway` `exec_always`
  - `systemd --user` unit example
- Document config reload behavior clearly
  - current expectation should be explicit if restart is required
- Add a `.zig-version` file for `zigup` / `zvm`
- Add a screenshot or GIF to the README
- Add a simple CI check for `zig build` and config tests

### Packaging and distribution
- Add a `PKGBUILD` or publish an AUR package
- Consider a GitHub release/tag once the docs and release ergonomics settle

## Next features

### Config and UX
- Add `--config` / `-c` to override config path
- Consider a user-facing config validation / lint mode later
- Keep the public config surface small and stable

### Outputs and docking
- Support runtime creation of wallpaper surfaces for newly added outputs
- Keep safe per-output teardown for removed outputs
- Add output targeting in config
  - `all`
  - include list
  - exclude list
- Longer term: per-output config blocks / overrides

### Daemon behavior
- Add config reload support
  - likely `SIGHUP` or a small IPC/restart-friendly command
- Improve process-manager integration docs and examples

## Engine evolution

### Effects system
- Keep `colormix` as the default effect
- Formalize effect selection so more shaders can be added cleanly
- Add more shader modes over time
- Keep effect-specific settings grouped under each effect in config

### Renderer
- Keep low-power behavior as the default design goal
- Improve render scaling further if needed
- Revisit refresh-aware pacing only if there is a clear visual win without hurting power use

## Deferred / acceptable limitations

These are known limitations that do not block the current release candidate but should remain visible.
- New outputs added after startup do not yet automatically get a wallpaper surface
- Config is global, not per-output
- No live config reload yet
- No GNOME/KDE support target right now
- No X11/XWayland support target right now

## Notes for future planning

Ideas worth revisiting after the current release settles:
- per-output presets
- effect cycling / selection from config
- hotplug policy options
- more ambient shader modes beyond colormix
- battery/eco mode presets
- optional screenshot generation for README/marketing
