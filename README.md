# wlchroma

`wlchroma` is a low-power animated wallpaper for Linux Wayland desktops. It renders a simple colormix shader behind your windows and defaults to a deliberate 15 fps cadence to keep CPU/GPU use modest.

## Requirements

- Linux with a Wayland session
- A compositor that supports `wlr-layer-shell`
- Zig `0.15.2`
- `wayland-scanner`
- Development libraries for `wayland-client`, `wayland-egl`, `EGL`, and `GLESv2`

If EGL is unavailable at runtime, `wlchroma` falls back to a CPU/SHM path instead of using the GPU renderer.

## Clean Machine Setup

On a fresh Linux/Wayland machine, install:

- Zig `0.15.2`
- Wayland client development packages
- `wayland-scanner`
- EGL/OpenGL ES 2.0 development packages

Package names vary by distro, but the build expects the libraries named in `build.zig`: `wayland-client`, `wayland-egl`, `EGL`, and `GLESv2`.

## Build

```bash
zig build
```

## Run

```bash
./zig-out/bin/wlchroma
```

You can also build and run in one step:

```bash
zig build run
```

## Configuration

`wlchroma` looks for a config file in this order:

1. `$XDG_CONFIG_HOME/wlchroma/config.toml`
2. `$HOME/.config/wlchroma/config.toml`

If no config file exists, built-in defaults are used. If a config file does exist, it must include `version = 1`.

The public v1 config surface is:

- `version`
- `fps`
- `[renderer].scale`
- `[renderer].upscale_filter`
- `[effect.settings].palette`

Start from `config.toml.example`:

```bash
mkdir -p "$HOME/.config/wlchroma"
cp config.toml.example "$HOME/.config/wlchroma/config.toml"
```

### Config Notes

- `fps` defaults to `15`. That is an intentional low-power default for the wallpaper animation; it is not tied to your monitor refresh rate.
- `renderer.scale = 1.0` renders at native resolution. Lower values render to a smaller offscreen image and then scale it up, which usually reduces GPU work but makes the result look softer or chunkier.
- `renderer.scale` must be between `0.1` and `1.0`. Values from `0.95` up to but not including `1.0` are rejected.
- `renderer.upscale_filter = "nearest"` keeps the upscaled image crisp and blocky. `"linear"` smooths it out, but can look blurrier.
- `renderer.scale` and `renderer.upscale_filter` matter only on the EGL/GPU reduced-resolution path. If `wlchroma` falls back to the CPU/SHM renderer, those knobs do not change the output path.
- `[effect.settings].palette` must contain exactly three `"#RRGGBB"` colors.

## Limitations

- Linux Wayland only; no X11 support
- Requires a compositor with `wlr-layer-shell`
- The public v1 effect surface is intentionally small: one colormix effect with a 3-color palette
- Multi-monitor output is supported, but all outputs use the same global config

## Troubleshooting

- If the app exits immediately, make sure you are running inside a Wayland session and your compositor supports `wlr-layer-shell`.
- If build linking fails, install the missing Wayland/EGL/GLES development packages and confirm `wayland-scanner` is on your `PATH`.
- If a config file is ignored or rejected, check that it lives at one of the lookup paths above and starts with `version = 1`.
- If GPU initialization fails, `wlchroma` should continue on the CPU/SHM fallback path, but reduced-resolution GPU scaling options will not apply.
