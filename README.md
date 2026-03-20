# wlchroma

An animated Wayland wallpaper using a GPU-rendered colormix shader.

## Features
- EGL + OpenGL ES 2.0 renderer
- Colormix animated shader (per-pixel UV-warp with palette lookup)
- Fixed 15fps low-power mode (intentionally choppy/ASCII aesthetic)
- Multi-monitor support via wlr-layer-shell
- CPU/SHM fallback if EGL is unavailable

## Requirements
- Zig 0.14 (or master, see build.zig for exact version)
- A Wayland compositor with wlr-layer-shell support (sway, river, Hyprland, etc.)
- EGL and OpenGL ES 2.0 (Mesa/libGL on most Linux systems)
- wayland-egl, wayland-client, wayland-scanner

## Build
    zig build

## Run
    ./zig-out/bin/wlchroma

## Config
- See `config.toml.example` for the public v1 config surface.
- `version = 1` is required in an existing config file; if no config file exists, built-in defaults still apply.
- `renderer.scale = 1.0` means native rendering; values from `0.95` up to but not including `1.0` are rejected as too close to native to justify the scaled offscreen path.
