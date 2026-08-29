#!/usr/bin/env bash
# Verify that GNOME Terminal's GTK/UI stack is present in the executable rather
# than in dynamic dependencies.
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: verify-gnome-terminal-static.sh BINARY" >&2
    exit 2
fi

BIN=$1
[ -x "$BIN" ] || { printf 'verifier: executable not found: %s\n' "$BIN" >&2; exit 1; }

DYN=$(readelf -dW "$BIN" 2>/dev/null)
SEG=$(readelf -lW "$BIN" 2>/dev/null)

if ! grep -q 'INTERP' <<<"$SEG"; then
    echo 'verifier: no PT_INTERP; expected Profile H with pinned glibc' >&2
    exit 1
fi
if ! grep -q 'GNU_RELRO' <<<"$SEG"; then
    echo 'verifier: GNU_RELRO is missing' >&2
    exit 1
fi
if ! grep -qE 'BIND_NOW|FLAGS.*NOW' <<<"$DYN"; then
    echo 'verifier: BIND_NOW is missing' >&2
    exit 1
fi
if grep -qE 'RPATH|RUNPATH' <<<"$DYN"; then
    echo 'verifier: RPATH/RUNPATH leaked into the artifact' >&2
    exit 1
fi

TOOLKIT_NEEDED=$(grep -E 'NEEDED.*\[(lib(gtk-3|gdk-3|vte-2\.91|handy-1|glib-2\.0|gobject-2\.0|gio-2\.0|pango-1\.0|pangocairo-1\.0|cairo|gdk_pixbuf-2\.0|harfbuzz|freetype|fontconfig|pcre2-8|atk-1\.0|epoxy|pixman-1|png16|jpeg|tiff|webp|ffi|pcre)\.so)' <<<"$DYN" || true)
if [ -n "$TOOLKIT_NEEDED" ]; then
    echo 'verifier: dynamic GTK stack detected:' >&2
    printf '%s\n' "$TOOLKIT_NEEDED" >&2
    exit 1
fi

echo 'GNOME Terminal static GTK verification: PASS'
