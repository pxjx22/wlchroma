# Config Schema Contract: Effect System v1

**Feature**: 001-effect-system
**Date**: 2026-03-23
**Config format**: TOML, version-gated (`version = 1` required in existing files)

This document defines the public TOML configuration surface added or changed by the
effect system. All existing keys are unchanged.

---

## New / Changed Keys

### `[effect] name`

| Property   | Value |
|------------|-------|
| Section    | `[effect]` |
| Key        | `name` |
| Type       | Quoted string |
| Default    | `"colormix"` (when `[effect]` section or `name` key is absent) |
| Valid      | `"colormix"`, `"glass_drift"` |
| Invalid    | Any other string → startup error naming the bad value, non-zero exit |

**Behaviour**:
- If `[effect]` section is present but `name` is absent: default to `"colormix"`,
  log a notice.
- If `name` is an unrecognised value: reject at startup. Do not fall back silently.

**Example**:
```toml
[effect]
name = "glass_drift"
```

---

### `[effect.settings] speed`

| Property   | Value |
|------------|-------|
| Section    | `[effect.settings]` |
| Key        | `speed` |
| Type       | Float |
| Default    | `1.0` (when key is absent) |
| Valid      | `0.25` ≤ speed ≤ `2.5` |
| Invalid    | Outside that range, or not a valid float → startup error, non-zero exit |

**Behaviour**:
- Scales the apparent animation speed of the active effect.
- `0.5` = half speed, `2.0` = double speed, `1.0` = unchanged (default).
- Does **not** change the frame rate — only the time value passed to the shader.
- Applies to all effects equally.

**Example**:
```toml
[effect.settings]
speed = 0.75
```

---

## Full Example Config (effect system additions shown)

```toml
version = 1
fps = 15

[effect]
name = "glass_drift"

[effect.settings]
speed = 0.8

[renderer]
scale = 1.0
upscale_filter = "nearest"
```

---

## Validation Rules Summary

| Key | Missing | Wrong type | Out of range | Unknown value |
|-----|---------|------------|--------------|---------------|
| `effect.name` | Default `colormix` + notice | error | n/a | `UnsupportedEffect` error |
| `effect.settings.speed` | Default `1.0` | `InvalidValue` error | `InvalidValue` error | n/a |

---

## Interaction with GPU Fallback

If `effect.name = "glass_drift"` is set but GPU rendering is unavailable at runtime:
- wlchroma logs: `"effect glass_drift requires GPU; falling back to colormix on CPU path"`
- wlchroma continues running on the CPU path with colormix.
- This is a runtime condition, not a config error. The config file is not rejected.
- `effect.settings.speed` still applies to the colormix fallback.
