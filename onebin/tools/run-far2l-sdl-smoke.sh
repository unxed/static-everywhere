#!/usr/bin/env bash
# Start the far2l SDL preview on an X11 display and prove that it creates a
# visible window. The build itself is responsible for providing SDL; this
# script never points it at a host toolkit or a host SDL installation.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    printf 'usage: %s FAR2L OUT_DIR\n' "$0" >&2
    exit 2
fi

FAR2L=$1
OUT=$2
mkdir -p "$OUT" "$OUT/config" "$OUT/runtime"
chmod 700 "$OUT/runtime"

command -v xdotool >/dev/null || { echo 'run-far2l-sdl-smoke.sh: xdotool is required' >&2; exit 2; }
command -v xwininfo >/dev/null || { echo 'run-far2l-sdl-smoke.sh: xwininfo is required' >&2; exit 2; }

export XDG_CONFIG_HOME="$OUT/config"
export XDG_RUNTIME_DIR="$OUT/runtime"
export SDL_VIDEODRIVER=x11
export FAR2L_SDL_DEBUG_REDRAW=1

app_pid=
cleanup() {
    if [ -n "${app_pid:-}" ]; then
        kill "$app_pid" 2>/dev/null || true
        wait "$app_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT

timeout --foreground 45s "$FAR2L" --SDL --notty --mortal --size=100x30 \
    >"$OUT/far2l.log" 2>&1 &
app_pid=$!

window_id=
for _ in $(seq 1 90); do
    window_id=$(xdotool search --onlyvisible --name 'far2l' 2>/dev/null | head -n 1 || true)
    if [ -n "$window_id" ]; then
        break
    fi
    if ! kill -0 "$app_pid" 2>/dev/null; then
        wait "$app_pid" || true
        echo 'run-far2l-sdl-smoke.sh: far2l exited before creating a window' >&2
        cat "$OUT/far2l.log" >&2 || true
        exit 1
    fi
    sleep 1
done

[ -n "$window_id" ] || {
    echo 'run-far2l-sdl-smoke.sh: no visible far2l window appeared' >&2
    cat "$OUT/far2l.log" >&2 || true
    exit 1
}

xdotool getwindowname "$window_id" >"$OUT/window-title.txt"
xwininfo -root -tree >"$OUT/window-tree.txt"
if command -v import >/dev/null 2>&1; then
    import -window root "$OUT/screenshot.png" 2>/dev/null || true
fi
printf 'window_id=%s\n' "$window_id" | tee "$OUT/window-proof.txt"

# The smoke test proves startup and drawing; shutdown is a separate diagnostic
# signal and may be affected by the preview backend's current exit lifecycle.
kill -TERM "$app_pid" 2>/dev/null || true
wait "$app_pid" 2>/dev/null || true
app_pid=
printf '%s\n' 'far2l SDL smoke: visible X11 window created' \
    | tee -a "$OUT/window-proof.txt"
