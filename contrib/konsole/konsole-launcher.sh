#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export XDG_DATA_DIRS="$ROOT/share${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"
export QT_PLUGIN_PATH="$ROOT/lib/plugins${QT_PLUGIN_PATH:+:$QT_PLUGIN_PATH}"

# Fontconfig is statically linked, but its configuration and fonts are host
# data by design. Prefer an explicitly supplied configuration and otherwise
# point it at the standard Linux host location. This prevents a Conan
# package/build path from becoming an accidental runtime dependency while
# preserving the user's fontconfig policy.
if [[ -z ${FONTCONFIG_FILE:-} && -f /etc/fonts/fonts.conf ]]; then
    export FONTCONFIG_FILE=/etc/fonts/fonts.conf
fi
if [[ -z ${FONTCONFIG_PATH:-} && -d /etc/fonts ]]; then
    export FONTCONFIG_PATH=/etc/fonts
fi

if [[ ${KONSOLE_SMOKE_DISABLE_LD_LIBRARY_PATH:-0} == 1 ]]; then
    unset LD_LIBRARY_PATH
else
    export LD_LIBRARY_PATH="$ROOT/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
exec "$ROOT/bin/konsole" "$@"
