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
- `[effect].name` selects the active wallpaper effect. Supported values: `"colormix"` (default) and `"glass_drift"`. An unknown value exits at startup with a clear error.
- `"glass_drift"` renders a layered frosted-glass pane animation using a fixed palette: ice blue (`#7BA9CC`), pale silver (`#BCC9D8`), and deep slate (`#4A6B88`). It requires GPU (EGL). If EGL is unavailable, `wlchroma` falls back to colormix automatically and logs a warning.
- `[effect.settings].speed` scales animation velocity for whichever effect is active. Valid range: `0.25`–`2.5`. Defaults to `1.0`. Out-of-range values exit at startup with a clear error.

## Limitations

- Linux Wayland only; no X11 support
- Requires a Wayland compositor that exposes `zwlr_layer_shell_v1` (`wlr-layer-shell`)
- The public v1 effect surface is intentionally small: two effects (`colormix` and `glass_drift`); further effects are out of scope for this release
- Multi-monitor output is supported, but all outputs use the same global config; there is no per-output config yet
- Outputs added after `wlchroma` starts do not get a wallpaper surface until you restart it

## Troubleshooting

- If the app exits immediately, make sure you are running inside a Wayland session and your compositor exposes `zwlr_layer_shell_v1` (`wlr-layer-shell`).
- If build linking fails, install the missing Wayland/EGL/GLES development packages and confirm `wayland-scanner` is on your `PATH`.
- If a config file is ignored or rejected, check that it lives at one of the lookup paths above and starts with `version = 1`.
- If GPU initialization fails, `wlchroma` should continue on the CPU/SHM fallback path, but reduced-resolution GPU scaling options will not apply.
