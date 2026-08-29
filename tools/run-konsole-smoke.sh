#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    printf 'usage: %s KONSOLE_BINARY OUTPUT_DIR\n' "$0" >&2
    exit 2
fi
binary=$1
out=$2
mkdir -p "$out"
display=${DISPLAY:-:99}
server_log="$out/xvfb.log"
app_log="$out/konsole.log"
render_log="$out/render.log"
png="$out/konsole-window.png"
[[ -x $binary ]] || { printf 'error: missing Konsole: %s\n' "$binary" >&2; exit 1; }

Xvfb "$display" -screen 0 1280x900x24 -ac +extension GLX +render -noreset >"$server_log" 2>&1 &
xvfb_pid=$!
app_pid=
cleanup() {
    if [[ -n ${app_pid:-} ]]; then
        kill "$app_pid" 2>/dev/null || true
        wait "$app_pid" 2>/dev/null || true
    fi
    kill "$xvfb_pid" 2>/dev/null || true
    wait "$xvfb_pid" 2>/dev/null || true
}
trap cleanup EXIT

for _ in {1..60}; do
    xdpyinfo -display "$display" >/dev/null 2>&1 && break
    sleep 1
done
xdpyinfo -display "$display" >/dev/null 2>&1 || {
    printf 'error: Xvfb did not become ready\n' >&2
    exit 1
}

install_dir=${KONSOLE_INSTALL_DIR:-$(cd "$(dirname "$binary")/.." && pwd)}
runtime_dir="$out/xdg-runtime"
mkdir -p "$runtime_dir"
chmod 700 "$runtime_dir"
export DISPLAY="$display"
export XDG_RUNTIME_DIR="$runtime_dir"
export XDG_DATA_DIRS="$install_dir/share:/usr/share"
export QT_QPA_PLATFORM=xcb
export LD_LIBRARY_PATH="$install_dir/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LIBGL_ALWAYS_SOFTWARE=1
export SE_RENDER_DEBUG_FILE="$render_log"

"$binary" --separate --nofork --hold >"$app_log" 2>&1 &
app_pid=$!
window_id=
for _ in {1..60}; do
    window_id=$(xdotool search --onlyvisible --pid "$app_pid" 2>/dev/null | head -n 1 || true)
    [[ -n $window_id ]] && break
    if ! kill -0 "$app_pid" 2>/dev/null; then
        cat "$app_log" >&2 || true
        printf 'error: Konsole exited before creating a window\n' >&2
        exit 1
    fi
    sleep 1
done
[[ -n $window_id ]] || {
    cat "$app_log" >&2 || true
    printf 'error: no visible Konsole window\n' >&2
    exit 1
}

xwd -display "$display" -id "$window_id" -silent >"$out/window.xwd"
convert "$out/window.xwd" "$out/window.png"
xwd -display "$display" -root -silent >"$out/screen.xwd"
convert "$out/screen.xwd" "$png"
dimensions=$(identify -format '%wx%h' "$png")
[[ $dimensions == 1280x900 ]] || {
    printf 'error: screenshot size %s\n' "$dimensions" >&2
    exit 1
}
deviation=$(convert "$png" -format '%[standard-deviation]' info:)
[[ $deviation != 0 && $deviation != 0.0* ]] || {
    printf 'error: screenshot is blank\n' >&2
    exit 1
}
if grep -Eiq 'Could not find the Qt platform plugin|cannot connect to display|failed to initialize graphics backend|no xcb' "$app_log"; then
    cat "$app_log" >&2
    printf 'error: graphical startup failure in log\n' >&2
    exit 1
fi
printf 'Konsole graphical smoke: PASS (%s, pixel stddev %s)\n' "$dimensions" "$deviation"
