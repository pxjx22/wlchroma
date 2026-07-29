# wlchroma

Animated, palette-driven wallpaper for Linux Wayland desktops. Renders shader effects behind your windows with configurable colors, frame rate, and live runtime controls via a Unix socket.

## Features

- Eleven built-in effects — one CPU-rendered, ten GPU shader effects
- Three-color palettes drive all effects; named palettes can be switched at runtime
- Runs on compositors that expose `zwlr_layer_shell_v1` (`wlr-layer-shell`)
- Falls back to a CPU/SHM path when EGL/GPU rendering is unavailable
- Controllable at runtime via `wlchroma-ctl` or direct socket scripting
- Multi-monitor support with hotplug: monitors connected or disconnected at runtime gain/lose their wallpaper automatically (all outputs share one global config)

## Requirements

- Linux with a Wayland session
- A compositor exposing `zwlr_layer_shell_v1` (`wlr-layer-shell`)
- Zig `0.16.0`
- `wayland-scanner`
- Development libraries: `wayland-client`, `wayland-egl`, `EGL`, `GLESv2`

Package names vary by distro. The build expects the library names listed in `build.zig`.

## Build

```bash
zig build
```

Both `wlchroma` and `wlchroma-ctl` are built and placed in `zig-out/bin/`.

## Run

```bash
./zig-out/bin/wlchroma
```

Or build and run in one step:

```bash
zig build run
```

### CLI Flag

`wlchroma` accepts one optional flag:

```
--config <path>  /  -c <path>
```

Load the given config file instead of the default XDG/HOME lookup.

## Configuration

`wlchroma` looks for a config file at:

1. `$XDG_CONFIG_HOME/wlchroma/config.toml`
2. `$HOME/.config/wlchroma/config.toml`

If no config file exists, built-in defaults are used. There is a single config format; a top-level `version` key is optional and ignored.

The file uses wlchroma's supported TOML subset: bare schema keys/sections,
decimal numbers, single-line double-quoted UTF-8 strings, arrays of quoted
strings, `#` comments outside strings, and `[[palettes]]`. Recognized strings
do not support TOML escapes; any backslash in one is rejected. Files must be
valid UTF-8 and may not contain ASCII control bytes other than tab and CRLF/LF
line endings.

Copy the example config to get started:

```bash
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/wlchroma"
cp config.toml.example "${XDG_CONFIG_HOME:-$HOME/.config}/wlchroma/config.toml"
```

### Config Keys

| Key | Default | Range / Values | Notes |
|---|---|---|---|
| `fps` | `15` | `1`–`120` (integer) | Animation cadence; not tied to monitor refresh rate. |
| `[renderer].scale` | `1.0` | `0.1`–`1.0` | `1.0` = native resolution. Lower values reduce GPU work. Values from `0.95` to `<1.0` are rejected. GPU path only. |
| `[renderer].upscale_filter` | `"nearest"` | `"nearest"`, `"linear"` | `"nearest"` = crisp/blocky. `"linear"` = smooth/softer. GPU path only. |
| `[effect].name` | `"colormix"` | See [Effects](#effects) | Unknown values exit at startup with an error. |
| `[effect.settings].palette` | `["#1e1e2e", "#89b4fa", "#a6e3a1"]` | Exactly 3 `"#RRGGBB"` colors | Drives all effects. |
| `[effect.settings].speed` | `1.0` | `0.25`–`2.5` | Animation speed multiplier. Out-of-range values exit at startup. |

Config is loaded once at startup. Use `wlchroma-ctl reload` to apply config changes — including switching the effect — without restarting. All keys are applied: `effect.name` rebuilds the effect in place, `speed` changes take effect without restarting the animation, and `renderer.scale` / `upscale_filter` apply immediately.

## Effects

| Name | Description |
|---|---|
| `"colormix"` | Smooth CPU-rendered color gradient blend (default; works without GPU) |
| `"glass_drift"` | Layered frosted-glass pane animation with sinusoidal drifting planes |
| `"frond_haze"` | Organic branching haze with drifting bloom pockets and palette-tinted canopy glow |
| `"lumen_tunnel"` | Rotating tunnel shells with palette-colored ribs, flare bands, and screen shimmer |
| `"velvet_mesh"` | Glowing lattice grid with square-bloom highlights and colour shimmer between nodes |
| `"starfield_fog"` | Procedural star field with additive glow on a smoothly varying nebula fog backdrop |
| `"gyro_echo"` | Reflective gyroid tunnel with palette-tinted materials, soft fog, and orbiting camera |
| `"hex_floret"` | Subdivided hexagon floret relief with ceramic shading and slow camera drift |
| `"dither_orb"` | Ordered-dither raymarched orb with palette-aware lighting and striped backdrop |
| `"signal_matrix"` | Matrix-like glyph field with palette-tinted scanlines, glow, and vertical signal drift |
| `"fract_lattice"` | Recursive box-lattice fractal carving with palette-aware sky shading and drifting camera |

All effects except `colormix` require GPU rendering. If the GPU path is unavailable, `wlchroma` renders the `colormix` fallback and logs a warning.

## Named Palettes

Add `[[palettes]]` entries to define named palettes that can be switched at runtime via `wlchroma-ctl set-palette`:

```toml
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

Palette names must be unique and contain 1–63 UTF-8 bytes. The initial colors come from `[effect.settings].palette`; named palettes are activated only via IPC.

## Runtime Control

`wlchroma` exposes a Unix domain socket at `$XDG_RUNTIME_DIR/wlchroma.sock` using a line-based text protocol.

### wlchroma-ctl

`wlchroma-ctl` is built alongside `wlchroma` by `zig build`. Both binaries are in `zig-out/bin/`.

| Command | Description |
|---|---|
| `wlchroma-ctl query` | Print current effect, fps, scale, and active palette |
| `wlchroma-ctl set-fps <1-240>` | Change frame rate (runtime range is wider than config) |
| `wlchroma-ctl set-scale <scale>` | Change render scale (`0.1`–`1.0`, applies immediately; GPU path only) |
| `wlchroma-ctl set-palette <name>` | Switch to a named palette |
| `wlchroma-ctl set-colors <#rrggbb> <#rrggbb> <#rrggbb> [fade_ms]` | Set the palette to three arbitrary colors live (no config file); optional fade duration glides to them |
| `wlchroma-ctl reload` | Re-read config file and apply all changes (effect, speed, fps, palette, scale, filter) |
| `wlchroma-ctl stop` | Shut down wlchroma gracefully |

Exit codes: `0` on success, `1` on error (errors printed to stderr).

Reload file reading and parsing run on a transient background worker so
animation, Wayland events, signals, and other IPC remain responsive. Only one
reload may be in progress; another receives
`error: reload already in progress`. The response remains completion-confirmed:
`ok` is written only after the snapshot is applied, and an error leaves the
previous runtime state unchanged.

**Runtime vs. config ranges:**
- `set-fps` accepts `1`–`240` at runtime; config file `fps` is limited to `1`–`120`.
- `set-scale` matches the config file's `renderer.scale` rules: `0.1`–`1.0`, with values from `0.95` to just under `1.0` rejected as too close to native.
- `set-colors` takes exactly three `#rrggbb` colors (same hex format as the config `palette`) and applies them immediately, like a same-effect `reload`. It reads no config file and does not persist — a later `reload` reverts to the config file's palette. `query` reports `palette=custom` afterward.
- `set-colors` accepts an optional 4th argument, a fade duration in whole milliseconds: `wlchroma-ctl set-colors '#120C14' '#e05f89' '#6d9bcb' 600`. Omitted or `0` applies instantly (unchanged); a positive value glides from the current colors to the new ones over that duration with smoothstep easing. A new `set-colors` mid-fade re-targets from wherever the colors are; `reload`/`set-palette` cancel a fade. Fade smoothness scales with the running `fps` (at the 15 default a short fade is only a handful of steps); ~500 ms is a good starting point.

For a real-world `set-colors` consumer, see [mpris-chroma](https://github.com/pxjx22/mpris-chroma) — a daemon that fades the wallpaper to the album art of whatever is playing.

### Direct Socket Access

The protocol is scriptable with standard Unix tools:

```bash
# query current state
echo 'query' | socat - UNIX-CONNECT:"$XDG_RUNTIME_DIR/wlchroma.sock"

# change fps
echo 'set-fps 60' | socat - UNIX-CONNECT:"$XDG_RUNTIME_DIR/wlchroma.sock"

# switch palette
echo 'set-palette ocean' | socat - UNIX-CONNECT:"$XDG_RUNTIME_DIR/wlchroma.sock"

# push three arbitrary colors live (no config file)
echo 'set-colors #120C14 #e05f89 #6d9bcb' | socat - UNIX-CONNECT:"$XDG_RUNTIME_DIR/wlchroma.sock"

# glide to three colors over 600 ms
echo 'set-colors #120C14 #e05f89 #6d9bcb 600' | socat - UNIX-CONNECT:"$XDG_RUNTIME_DIR/wlchroma.sock"

# or with nc (some implementations)
echo 'reload' | nc -U "$XDG_RUNTIME_DIR/wlchroma.sock"
```

Responses are newline-terminated. Multi-line responses (e.g. `query`) end with `ok`. Errors start with `error:`.

## Autostart

Use an absolute path if `wlchroma` is not on your `PATH`.

### niri

```kdl
spawn-at-startup "wlchroma"
```

### sway

To restart `wlchroma` on sway config reload, use a systemd user service with `exec_always`:

```ini
exec_always --no-startup-id systemctl --user restart wlchroma.service
```

### systemd --user

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

```bash
# save as ~/.config/systemd/user/wlchroma.service, then:
systemctl --user daemon-reload
systemctl --user enable --now wlchroma.service
```

## Multi-Monitor and Hotplug

- Monitors connected while `wlchroma` is running get the wallpaper automatically within a couple of seconds — no restart needed. New monitors use the current runtime state (including palettes or fps set via `wlchroma-ctl`).
- Disconnected monitors are cleaned up fully; repeated plug/unplug cycles (docks, TVs) do not leak resources.
- If every monitor disappears (undocking, lid close), `wlchroma` keeps running at ~0% CPU with `wlchroma-ctl` still responsive, and resumes rendering when a monitor returns. It exits only on SIGTERM, SIGINT (Ctrl-C), `wlchroma-ctl stop`, or compositor shutdown.
- Resolution/mode changes resize the wallpaper in place.

## Limitations

- Linux Wayland only — no X11 support.
- Requires `zwlr_layer_shell_v1` from the compositor.
- All outputs share one global config — no per-output effect or palette selection.

## Troubleshooting

- **Exits immediately:** Confirm you are in a Wayland session and your compositor exposes `zwlr_layer_shell_v1`.
- **Build linking errors:** Install the missing Wayland/EGL/GLES development packages and confirm `wayland-scanner` is on your `PATH`.
- **Config ignored or rejected:** Verify the file is at one of the lookup paths and that keys match the table above (parse errors are printed at startup and on `wlchroma-ctl reload`).
- **GPU init fails:** `wlchroma` continues on the CPU/SHM fallback, but `renderer.scale` and `renderer.upscale_filter` will not apply.

## Contributing

See `CONTRIBUTING.md` for contribution guidance and `AI_CONTRIBUTING.md` for agent-specific rules.
