#!/bin/sh

set -eu

CONFIG_PATH=${1:-"${XDG_CONFIG_HOME:-$HOME/.config}/wlchroma/config.toml"}
DWELL_SECONDS=${DWELL_SECONDS:-4}
EFFECTS=${EFFECTS:-"gyro_echo velvet_mesh signal_matrix colormix fract_lattice"}
CTL=${CTL:-"$(dirname "$0")/../zig-out/bin/wlchroma-ctl"}

if [ ! -f "$CONFIG_PATH" ]; then
    printf 'error: config file not found: %s\n' "$CONFIG_PATH" >&2
    exit 1
fi

if [ ! -x "$CTL" ]; then
    printf 'error: wlchroma-ctl not found or not executable: %s\n' "$CTL" >&2
    exit 1
fi

TMP_DIR=$(mktemp -d)
BACKUP_PATH="$TMP_DIR/config.toml.backup"
cp "$CONFIG_PATH" "$BACKUP_PATH"

restore_config() {
    cp "$BACKUP_PATH" "$CONFIG_PATH"
    "$CTL" reload >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
}

trap restore_config EXIT INT TERM

set_effect() {
    effect_name=$1
    tmp_out="$TMP_DIR/config.toml"

    awk -v effect_name="$effect_name" '
        BEGIN {
            in_effect = 0;
            replaced = 0;
        }
        /^\[/ {
            if (in_effect && !replaced) {
                print "name = \"" effect_name "\"";
                replaced = 1;
            }
            in_effect = ($0 == "[effect]");
            print;
            next;
        }
        {
            if (in_effect && $0 ~ /^[[:space:]]*name[[:space:]]*=/) {
                if (!replaced) {
                    print "name = \"" effect_name "\"";
                    replaced = 1;
                }
                next;
            }
            print;
        }
        END {
            if (in_effect && !replaced) {
                print "name = \"" effect_name "\"";
                replaced = 1;
            }
            if (!replaced) {
                exit 2;
            }
        }
    ' "$CONFIG_PATH" > "$tmp_out" || {
        printf 'error: failed to set [effect].name in %s\n' "$CONFIG_PATH" >&2
        exit 1
    }

    mv "$tmp_out" "$CONFIG_PATH"
    "$CTL" reload >/dev/null
}

for effect in $EFFECTS; do
    printf 'switching effect -> %s\n' "$effect"
    set_effect "$effect"
    sleep "$DWELL_SECONDS"
done
