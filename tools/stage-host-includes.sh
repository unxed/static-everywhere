#!/usr/bin/env bash
# Build a filtered copy of /usr/include holding only the headers of the
# host packages the recipe deliberately depends on.
#
# Why this exists
# ---------------
# konsole compiled TerminalDisplay.cpp against the host's ICU 74 headers
# and linked Conan's ICU 78 archives: undefined ubidi_*_74. ICU is not in
# the host contract; libicu-dev is on the runner only because libxml2-dev
# depends on it. But /usr/include is one directory: reachable for X11, it
# is reachable for everything Ubuntu has installed. This makes the cause
# of the search order irrelevant -- an unlisted host header cannot be
# found at all.
#
# Two derived sets, no hand lists:
#   1. the dependency closure of the listed -dev packages (libx11-dev's
#      Xlib.h includes X11/X.h from x11proto-dev; the first version of
#      this script staged only the listed packages' own files and got
#      "X11/X.h: file not found");
#   2. every top-level name a vendored (Conan) include root provides;
#      host headers under such a name are excluded, so the closure of
#      libxml2-dev cannot bring libicu-dev's unicode/ back in.
set -euo pipefail

usage() {
    printf 'usage: %s <stage-dir> <vendored-include-roots-file|-> <dev-package>...\n' "$0" >&2
    exit 2
}
[ "$#" -ge 3 ] || usage
STAGE=$1; VENDORED=$2; shift 2

command -v dpkg >/dev/null 2>&1 || { printf 'stage-host-includes: dpkg unavailable\n' >&2; exit 1; }

declare -A vendored_top
if [ "$VENDORED" != "-" ]; then
    while IFS= read -r root; do
        [ -d "$root" ] || continue
        for entry in "$root"/*; do
            [ -e "$entry" ] && vendored_top[$(basename "$entry")]=1
        done
    done <"$VENDORED"
fi

closure=$(apt-cache depends --recurse --no-recommends --no-suggests \
              --no-conflicts --no-breaks --no-replaces --no-enhances "$@" 2>/dev/null \
          | grep -oE '^[a-z0-9][a-z0-9.+-]*-dev$' | sort -u)
pkgs=()
for pkg in "$@" $closure; do
    dpkg -s "$pkg" >/dev/null 2>&1 && pkgs+=("$pkg")
done
mapfile -t pkgs < <(printf '%s\n' "${pkgs[@]}" | sort -u)

missing=()
for pkg in "$@"; do dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg"); done
if [ "${#missing[@]}" -gt 0 ]; then
    printf 'stage-host-includes: listed packages not installed: %s\n' "${missing[*]}" >&2
    exit 1
fi

rm -rf "$STAGE"; mkdir -p "$STAGE"
excluded=(); linked=0
for pkg in "${pkgs[@]}"; do
    while IFS= read -r f; do
        case "$f" in /usr/include/*) ;; *) continue ;; esac
        [ -f "$f" ] || continue
        rel=${f#/usr/include/}
        top=${rel%%/*}
        if [ -n "${vendored_top[$top]:-}" ]; then excluded+=("$pkg:$top"); continue; fi
        mkdir -p "$STAGE/$(dirname "$rel")"
        ln -sfn "$f" "$STAGE/$rel"
        linked=$((linked + 1))
    done < <(dpkg -L "$pkg" 2>/dev/null)
done
[ "${#excluded[@]}" -eq 0 ] || printf 'stage-host-includes: excluded (vendored top-level name): %s\n' \
    "$(printf '%s\n' "${excluded[@]}" | sort -u | tr '\n' ' ')"

# The stage must satisfy the contract it exists for, and must not carry
# the header that caused this -- checked at staging time, not by a compile.
for must in X11/Xlib.h X11/X.h xcb/xcb.h GL/gl.h EGL/egl.h; do
    [ -e "$STAGE/$must" ] || { printf 'stage-host-includes: %s missing from the stage\n' "$must" >&2; exit 1; }
done
if [ -e "$STAGE/unicode/uvernum.h" ]; then
    printf 'stage-host-includes: unicode/uvernum.h is staged; the host ICU would shadow the vendored one again\n' >&2
    exit 1
fi
printf 'stage-host-includes: %s headers from %s packages (closure of %s) staged at %s\n' \
    "$linked" "${#pkgs[@]}" "$#" "$STAGE"
