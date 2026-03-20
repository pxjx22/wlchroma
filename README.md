# ly-colormix-wallpaper

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
    ./zig-out/bin/ly-colormix-wallpaper
