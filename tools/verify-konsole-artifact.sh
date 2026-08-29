#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ! -x $1 ]]; then
    printf 'usage: %s EXECUTABLE\n' "$0" >&2
    exit 2
fi

binary=$1
needed=$(readelf -d "$binary" | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p')
printf 'DT_NEEDED for %s:\n%s\n' "$binary" "${needed:-<none>}"
while IFS= read -r soname; do
    [[ -z $soname ]] && continue
    case $soname in
        libQt6*.so*|libKF5*.so*|libKF6*.so*|libKDE*.so*)
            printf 'error: host Qt/KDE library escaped: %s\n' "$soname" >&2
            exit 1
            ;;
        libGL.so*|libGLX.so*|libOpenGL.so*)
            printf 'error: OpenGL is a hard dependency: %s\n' "$soname" >&2
            exit 1
            ;;
        libc.so.6|libdl.so.2|libpthread.so.0|libm.so.6|libgcc_s.so.1|\
        libX11.so.6|libX11-xcb.so.1|libxcb.so.1|libxcb-cursor.so.0|\
        libxcb-icccm.so.4|libxcb-image.so.0|libxcb-keysyms.so.1|\
        libxcb-randr.so.0|libxcb-render.so.0|libxcb-render-util.so.0|\
        libxcb-shape.so.0|libxcb-shm.so.0|libxcb-sync.so.1|\
        libxcb-xfixes.so.0|libxcb-xkb.so.1|libICE.so.6|libSM.so.6)
            ;;
        *)
            printf 'error: undeclared dynamic dependency: %s\n' "$soname" >&2
            exit 1
            ;;
    esac
done <<< "$needed"

string_table=$(strings "$binary")
grep -q 'QXcbIntegrationPlugin' <<< "$string_table" || {
    printf 'error: qxcb static plugin is absent\n' >&2
    exit 1
}
grep -Eq 'QXcb(Glx|Egl)IntegrationPlugin' <<< "$string_table" || {
    printf 'error: qxcb GL integration plugin is absent\n' >&2
    exit 1
}
printf 'Konsole artifact contract: PASS (static Qt/KF6, host X11/OpenGL ABI only)\n'
