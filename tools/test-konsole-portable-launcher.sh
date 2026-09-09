#!/usr/bin/env bash
# Regression guard for the relocatable bundle launcher.
#
# The launcher is the user's entry point. Its application-owned data and
# plugin paths must follow the bundle root, while the isolated-smoke switch
# must be able to prove that the executable's RPATH is sufficient for shared
# libraries. This probe avoids building Qt/KF6 and tests the environment
# contract at the boundary where path drift would otherwise be invisible.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT

mkdir -p "$PROBE/runtime/bin" "$PROBE/runtime/lib/plugins" "$PROBE/runtime/share"
cat >"$PROBE/runtime/bin/konsole" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'LD_LIBRARY_PATH=%s\n' "${LD_LIBRARY_PATH-}" >"$KONSOLE_LAUNCHER_PROBE"
printf 'QT_PLUGIN_PATH=%s\n' "${QT_PLUGIN_PATH-}" >>"$KONSOLE_LAUNCHER_PROBE"
printf 'XDG_DATA_DIRS=%s\n' "${XDG_DATA_DIRS-}" >>"$KONSOLE_LAUNCHER_PROBE"
STUB
chmod 755 "$PROBE/runtime/bin/konsole"
install -m 755 "$REPO_ROOT/contrib/konsole/konsole-launcher.sh" "$PROBE/runtime/konsole"

run_probe() {
    local mode=$1
    local expected_ld=$2
    local disable_ld=$3
    local expected_plugins="$PROBE/runtime/lib/plugins"
    local expected_data="$PROBE/runtime/share"
    local output="$PROBE/$mode.txt"

    env -u LD_LIBRARY_PATH -u QT_PLUGIN_PATH -u XDG_DATA_DIRS \
        KONSOLE_LAUNCHER_PROBE="$output" \
        ${disable_ld:+KONSOLE_SMOKE_DISABLE_LD_LIBRARY_PATH=1} \
        "$PROBE/runtime/konsole"

    grep -Fqx "LD_LIBRARY_PATH=$expected_ld" "$output" || {
        printf 'unexpected LD_LIBRARY_PATH in %s\n' "$mode" >&2
        cat "$output" >&2
        exit 1
    }
    grep -Fqx "QT_PLUGIN_PATH=$expected_plugins" "$output" || {
        printf 'unexpected QT_PLUGIN_PATH in %s\n' "$mode" >&2
        cat "$output" >&2
        exit 1
    }
    grep -Fqx "XDG_DATA_DIRS=$expected_data" "$output" || {
        printf 'unexpected XDG_DATA_DIRS in %s\n' "$mode" >&2
        cat "$output" >&2
        exit 1
    }
}

run_probe normal "$PROBE/runtime/lib" ''
run_probe isolated '' 1
printf 'Konsole portable launcher: PASS (bundle data/plugins and isolated RPATH mode)\n'
