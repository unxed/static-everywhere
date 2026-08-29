#!/usr/bin/env bash
# f4-diag — run f4 with every relevant Qt diagnostic turned on and save a
# single log that explains a graphical failure.
#
# Why this exists
# ---------------
# CI proves f4 builds, audits clean, and runs headless (offscreen). It
# does NOT prove f4 draws a window on a real display: no CI step opens
# one. The gap between "runs headless" and "shows a picture" covers the
# xcb/Wayland platform plugin against a live server, real GL-or-software
# rendering to a visible surface, and fonts -- none of which a headless
# run exercises.
#
# So the first real graphical test is a user launching the binary. When
# that fails, "it didn't work" is not diagnosable; this wrapper makes the
# failure explain itself instead, by turning on the diagnostics Qt
# already has and capturing them together with the environment that
# shapes them.
#
# Usage:
#   f4-diag [--software] [--x11|--wayland] [-- <f4 args...>]
#
#   --software   force Qt's software scene graph (bypass GL entirely)
#   --x11        force the xcb platform plugin
#   --wayland    force the wayland platform plugin
#   everything after --  is passed through to f4
#
# The log is written to f4-diag-<timestamp>.log next to the binary, and
# its path is printed at the end. Attach that file to a bug report.

set -uo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
F4="${SCRIPT_DIR}/f4"
if [ ! -x "$F4" ]; then
    # Allow running from anywhere if f4 is on PATH.
    F4=$(command -v f4 || true)
fi
if [ -z "$F4" ] || [ ! -x "$F4" ]; then
    printf 'f4-diag: cannot find the f4 binary next to this script or on PATH\n' >&2
    exit 2
fi

force_software=0
force_platform=""
passthrough=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --software) force_software=1; shift ;;
        --x11) force_platform="xcb"; shift ;;
        --wayland) force_platform="wayland"; shift ;;
        --) shift; passthrough=("$@"); break ;;
        *) passthrough+=("$1"); shift ;;
    esac
done

STAMP=$(date +%Y%m%d-%H%M%S)
LOG="${SCRIPT_DIR}/f4-diag-${STAMP}.log"

{
    printf '===== f4-diag %s =====\n\n' "$STAMP"

    printf '%s\n' '----- host -----'
    uname -a
    printf 'distro: '
    # shellcheck disable=SC1091
    (. /etc/os-release 2>/dev/null && printf '%s\n' "$PRETTY_NAME") || echo unknown
    printf 'DISPLAY=%s  WAYLAND_DISPLAY=%s  XDG_SESSION_TYPE=%s\n' \
        "${DISPLAY:-}" "${WAYLAND_DISPLAY:-}" "${XDG_SESSION_TYPE:-}"
    printf 'XDG_RUNTIME_DIR=%s\n' "${XDG_RUNTIME_DIR:-}"

    printf '\n%s\n' '----- is there a GPU / libGL on this host? -----'
    # The optional-GL forwarder means the binary starts either way; this
    # just records which path it will take.
    for cand in libGL.so.1 /usr/lib/x86_64-linux-gnu/libGL.so.1 \
                /usr/lib64/libGL.so.1; do
        if ldconfig -p 2>/dev/null | grep -q "$cand" || [ -e "$cand" ]; then
            printf 'libGL: found (%s)\n' "$cand"; found_gl=1; break
        fi
    done
    [ -n "${found_gl:-}" ] || printf 'libGL: NOT found -> software rendering expected\n'

    printf '\n%s\n' '----- fonts -----'
    # The headless run showed a Fontconfig warning; on a desktop a missing
    # config usually is not fatal, but record it so a blank-text failure
    # is not a mystery.
    if command -v fc-list >/dev/null 2>&1; then
        printf 'fontconfig sees %s fonts\n' "$(fc-list 2>/dev/null | wc -l)"
    else
        printf 'fc-list not present; cannot enumerate fonts\n'
    fi

    printf '\n%s\n' '----- launch configuration -----'
    # Turn on Qt's own diagnostics. These are the real channels, confirmed
    # against Qt sources:
    #   QT_DEBUG_PLUGINS   plugin load attempts and why each fails
    #   QSG_INFO           scene-graph backend selection and GL/RHI init
    #   qt.qpa.*           platform (xcb/wayland) connection and screen setup
    #   SE_RENDER_DEBUG    our own libGL probe / software-fallback decision
    export QT_DEBUG_PLUGINS=1
    export QSG_INFO=1
    export SE_RENDER_DEBUG=1
    export QT_LOGGING_RULES="qt.qpa.*=true;qt.scenegraph.*=true;qt.rhi.*=true"

    if [ "$force_software" -eq 1 ]; then
        export QT_QUICK_BACKEND=software
        export QT_XCB_GL_INTEGRATION=none
        printf 'forcing software rendering (QT_QUICK_BACKEND=software)\n'
    fi
    if [ -n "$force_platform" ]; then
        export QT_QPA_PLATFORM="$force_platform"
        printf 'forcing platform plugin: %s\n' "$force_platform"
    fi

    printf 'binary: %s\n' "$F4"
    printf 'args:   %s\n' "${passthrough[*]:-(none)}"
    printf 'env:    QT_DEBUG_PLUGINS=1 QSG_INFO=1 SE_RENDER_DEBUG=1\n'
    printf '        QT_LOGGING_RULES=%s\n' "$QT_LOGGING_RULES"
    [ -n "${QT_QPA_PLATFORM:-}" ] && printf '        QT_QPA_PLATFORM=%s\n' "$QT_QPA_PLATFORM"
    [ -n "${QT_QUICK_BACKEND:-}" ] && printf '        QT_QUICK_BACKEND=%s\n' "$QT_QUICK_BACKEND"

    printf '\n%s\n' '----- f4 output (stderr+stdout) -----'
} >"$LOG" 2>&1

# Run f4, teeing everything into the log. Do not let a crash abort the
# capture -- a non-zero exit is exactly what we want recorded.
"$F4" "${passthrough[@]}" >>"$LOG" 2>&1
rc=$?

{
    printf '\n%s\n' '----- exit -----'
    printf 'f4 exited with code %d\n' "$rc"
    if [ "$rc" -ne 0 ]; then
        printf '\nIf the window never appeared, the most telling lines above are:\n'
        printf '  * "[se-render] ..."      -- which render backend was chosen\n'
        printf '  * "Got keys from plugin meta data" / "not a plugin" -- plugin loading\n'
        printf '  * "qt.qpa.xcb" / "Could not connect to display" -- the display link\n'
        printf '  * "qt.scenegraph" / "Failed to create ... context" -- rendering\n'
    fi
} >>"$LOG" 2>&1

printf 'f4-diag: full log written to\n  %s\n' "$LOG"
printf 'Attach that file to a bug report. Exit code was %d.\n' "$rc"
exit "$rc"
