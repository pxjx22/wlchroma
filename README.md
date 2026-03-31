# wlchroma

`wlchroma` is a low-power animated wallpaper for Linux Wayland desktops. It renders animated palette-driven wallpaper effects behind your windows and defaults to a deliberate 15 fps cadence to keep CPU/GPU use modest.

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

If no config file exists, built-in defaults are used. If a config file does exist, it must include `version = 1` (or `version = 2` for named-palette support — see below).

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
- Config file `fps` must be a whole number from `1` to `120`.
- Config is loaded once at startup. Use `wlchroma-ctl reload` to apply changes without restarting (see [Runtime Control](#runtime-control)).
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
| `"frond_haze"` | Organic branching haze with drifting bloom pockets and palette-tinted canopy glow |
| `"lumen_tunnel"` | Rotating tunnel shells with palette-colored ribs, flare bands, and screen shimmer |
| `"velvet_mesh"` | Glowing abs(sin) lattice grid with a soft square-bloom highlight on intersections and a subtle colour shimmer between nodes |
| `"starfield_fog"` | Procedural hash-based star field with additive star glow on a smoothly varying nebula fog backdrop |
| `"gyro_echo"` | Reflective gyroid tunnel with palette-tinted materials, soft fog, and a slow orbiting camera |
| `"hex_floret"` | Subdivided hexagon floret relief with palette-based ceramic shading and slow camera drift |
| `"dither_orb"` | Ordered-dither raymarched orb with palette-aware lighting and a striped dithered backdrop |
| `"signal_matrix"` | Procedural matrix-like glyph field with palette-tinted scanlines, glow, and vertical signal drift |
| `"fract_lattice"` | Recursive box-lattice fractal carving with palette-aware sky shading and slow drifting camera motion |

All effects except `colormix` use the GPU path. If GPU rendering is unavailable for the session, or a given surface has to fall back to SHM, `wlchroma` renders a `colormix` fallback automatically and logs a warning.
- `[effect.settings].speed` scales animation velocity for whichever effect is active. Valid range: `0.25`–`2.5`. Defaults to `1.0`. Out-of-range values exit at startup with a clear error.

### Config v2: Named Palettes

Set `version = 2` to define named color palettes that can be switched at runtime via `wlchroma-ctl set-palette`.

```toml
version = 2
fps = 30

[effect]
name = "velvet_mesh"

[effect.settings]
palette = ["#e63946", "#457b9d", "#1d3557"]

[[palettes]]
name = "ocean"
colors = ["#0077b6", "#00b4d8", "#90e0ef"]

[[palettes]]
name = "nord"
colors = ["#88c0d0", "#81a1c1", "#5e81ac"]
```

Palette names must be unique within the file. The initial effect colors come from `[effect.settings].palette`; named palettes are only activated via IPC.

## Runtime Control

`wlchroma` exposes a Unix domain socket at `$XDG_RUNTIME_DIR/wlchroma.sock` using a simple line-based protocol.

### wlchroma-ctl

Install `wlchroma-ctl` alongside `wlchroma` (same `zig build` step):

```bash
zig build install
# both binaries land in zig-out/bin/
```

Available commands:

| Command | Description |
|---|---|
| `wlchroma-ctl query` | Print current effect, fps, scale, and active palette |
| `wlchroma-ctl set-fps <1-240>` | Change animation frame rate for the running process |
| `wlchroma-ctl set-scale <scale>` | Change renderer scale factor for the running process |
| `wlchroma-ctl set-palette <name>` | Switch to a named palette (requires config v2) |
| `wlchroma-ctl reload` | Re-read config file and apply all changes |
| `wlchroma-ctl stop` | Gracefully shut down wlchroma |

`wlchroma-ctl` exits 0 on success and 1 on error. Errors are printed to stderr.

Runtime control notes:

- `set-fps` accepts `1` to `240` for the live process, even though config-file `fps` is limited to `1` to `120`.
- `set-scale` accepts any positive value up to `4.0` for the live process. Values above `1.0` are valid at runtime, unlike config-file `renderer.scale`, which is limited to `0.1` to `1.0`.

### Direct socket access

The protocol is scriptable with standard Unix tools:

```bash
# query current state
echo 'query' | socat - UNIX-CONNECT:"$XDG_RUNTIME_DIR/wlchroma.sock"

# change fps
echo 'set-fps 60' | socat - UNIX-CONNECT:"$XDG_RUNTIME_DIR/wlchroma.sock"

# switch palette (config v2 required)
echo 'set-palette ocean' | socat - UNIX-CONNECT:"$XDG_RUNTIME_DIR/wlchroma.sock"

# or with nc (some implementations)
echo 'reload' | nc -U "$XDG_RUNTIME_DIR/wlchroma.sock"
```

All responses are newline-terminated. Multi-line responses (such as `query`) end with `ok`. Error responses start with `error:`.

## Limitations

- Linux Wayland only; no X11 support
- Requires a Wayland compositor that exposes `zwlr_layer_shell_v1` (`wlr-layer-shell`)
- The public effect surface currently includes eleven effects: `colormix` plus ten GPU shader effects; there is no per-output effect config yet
- Multi-monitor output is supported, but all outputs use the same global config; there is no per-output config yet
- Outputs added after `wlchroma` starts do not get a wallpaper surface until you restart it

## Troubleshooting

- If the app exits immediately, make sure you are running inside a Wayland session and your compositor exposes `zwlr_layer_shell_v1` (`wlr-layer-shell`).
- If build linking fails, install the missing Wayland/EGL/GLES development packages and confirm `wayland-scanner` is on your `PATH`.
- If a config file is ignored or rejected, check that it lives at one of the lookup paths above and starts with a supported version header such as `version = 1` or `version = 2`.
- If GPU initialization fails, `wlchroma` should continue on the CPU/SHM fallback path, but reduced-resolution GPU scaling options will not apply.
