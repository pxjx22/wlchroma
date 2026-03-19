# ly-colormix-wallpaper

A small Zig Wayland layer-shell wallpaper daemon.

The current MVP creates one background surface per output, allocates shared-memory buffers, paints a single solid color, and commits that buffer as a wallpaper layer.

## Build

```bash
zig build
```

## Run

```bash
zig build run
```

## MVP Scope

- connect to the Wayland display
- discover outputs and required globals
- create a background layer-shell surface for each output
- allocate shm buffers and paint a solid color
- commit the wallpaper and stay in the event loop
