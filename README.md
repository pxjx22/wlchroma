# wlchroma

`wlchroma` is a low-power animated wallpaper for Linux Wayland desktops. It renders a simple colormix shader behind your windows and defaults to a deliberate 15 fps cadence to keep CPU/GPU use modest.

## Requirements

- Linux with a Wayland session
- A Wayland compositor that exposes `zwlr_layer_shell_v1` (`wlr-layer-shell`)
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

## Autostart

Use an absolute path if `wlchroma` is not on your `PATH`.

### niri

Add this to your niri config:

```kdl
spawn-at-startup "wlchroma"
```

### sway

If you want sway config reloads to also restart `wlchroma`, start it through a user service and use `exec_always`:

```ini
exec_always --no-startup-id systemctl --user restart wlchroma.service
```

### systemd --user

Minimal unit example:

```ini
[Unit]
Description=wlchroma animated wallpaper
PartOf=graphical-session.target
After=graphical-session.target

[Service]
ExecStart=/absolute/path/to/wlchroma
Restart=on-failure

[Install]
WantedBy=default.target
```

Save it as `~/.config/systemd/user/wlchroma.service`, then run:

```bash
systemctl --user daemon-reload
systemctl --user enable --now wlchroma.service
```

## CLI

`wlchroma` accepts a single optional flag:

- `--config <path>` / `-c <path>` -- load the given config file instead of the default XDG/HOME lookup.

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
- `[effect].name`
- `[effect.settings].palette`
- `[effect.settings].speed`

Start from `config.toml.example`:

```bash
mkdir -p "$HOME/.config/wlchroma"
cp config.toml.example "$HOME/.config/wlchroma/config.toml"
```

### Config Notes

- `fps` defaults to `15`. That is an intentional low-power default for the wallpaper animation; it is not tied to your monitor refresh rate.
- Config is loaded once at startup. There is no live config reload yet, so after changing `config.toml` you must restart `wlchroma`.
- `renderer.scale = 1.0` renders at native resolution. Lower values render to a smaller offscreen image and then scale it up, which usually reduces GPU work but makes the result look softer or chunkier.
- `renderer.scale` must be between `0.1` and `1.0`. Values from `0.95` up to but not including `1.0` are rejected.
- `renderer.upscale_filter = "nearest"` keeps the upscaled image crisp and blocky. `"linear"` smooths it out, but can look blurrier.
- `renderer.scale` and `renderer.upscale_filter` matter only on the EGL/GPU reduced-resolution path. If `wlchroma` falls back to the CPU/SHM renderer, those knobs do not change the output path.
- `[effect.settings].palette` must contain exactly three `"#RRGGBB"` colors.
- `[effect].name` selects the active wallpaper effect. An unknown value exits at startup with a clear error. Supported values:

| Name | Description |
|---|---|
| `"colormix"` | Smooth CPU-rendered color gradient blend across the palette (default; works without GPU) |
| `"glass_drift"` | Layered frosted-glass pane animation using three sinusoidal drifting planes |
| `"aurora_bands"` | Diagonal aurora ribbons — three sheared sin waves drifting across both axes for an organic banded aurora feel |
| `"cloud_chamber"` | Soft slow fog using products of two-axis sin waves blended over a stable base colour for a gentle atmospheric look |
| `"ribbon_orbit"` | Soft polar-coordinate arcs orbiting the screen center with a slow ambient fill between them (recommended speed: 1.0) |
| `"plasma_quilt"` | Classic plasma: four angled sin waves in opposing directions produce a smoothly churning colour field (recommended speed: 0.7) |
| `"liquid_marble"` | UV-warped fract banding with wide smoothstep veins and a shimmer layer for a flowing marble stone look |
| `"velvet_mesh"` | Glowing abs(sin) lattice grid with a soft square-bloom highlight on intersections and a subtle colour shimmer between nodes |
| `"soft_interference"` | Drifting concentric interference rings from two slowly orbiting focal points |
| `"starfield_fog"` | Procedural hash-based star field with additive star glow on a smoothly varying nebula fog backdrop |
| `"tube_lights"` | Neon tube bands with smooth colour crossfades, depth-modulated highlights, and slowly scrolling surface shading (recommended speed: 0.8) |

All GPU effects require EGL. If EGL is unavailable, `wlchroma` falls back to `colormix` automatically and logs a warning.
- `[effect.settings].speed` scales animation velocity for whichever effect is active. Valid range: `0.25`–`2.5`. Defaults to `1.0`. Out-of-range values exit at startup with a clear error.

## Limitations

- Linux Wayland only; no X11 support
- Requires a Wayland compositor that exposes `zwlr_layer_shell_v1` (`wlr-layer-shell`)
- The public v1 effect surface includes eleven effects (`colormix`, `glass_drift`, and nine GPU shader effects); there is no per-output effect config yet
- Multi-monitor output is supported, but all outputs use the same global config; there is no per-output config yet
- Outputs added after `wlchroma` starts do not get a wallpaper surface until you restart it

## Troubleshooting

- If the app exits immediately, make sure you are running inside a Wayland session and your compositor exposes `zwlr_layer_shell_v1` (`wlr-layer-shell`).
- If build linking fails, install the missing Wayland/EGL/GLES development packages and confirm `wayland-scanner` is on your `PATH`.
- If a config file is ignored or rejected, check that it lives at one of the lookup paths above and starts with `version = 1`.
- If GPU initialization fails, `wlchroma` should continue on the CPU/SHM fallback path, but reduced-resolution GPU scaling options will not apply.
