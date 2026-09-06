#!/usr/bin/env bash
set -euo pipefail

if [[ ($# -ne 1 && $# -ne 2) || ! -x $1 ]]; then
    printf 'usage: %s EXECUTABLE [INSTALL_PREFIX]\n' "$0" >&2
    exit 2
fi

binary=$1
# shellcheck disable=SC1007  # keep cd silent even when the caller exports CDPATH
prefix=${2:-$(CDPATH= cd -- "$(dirname -- "$binary")/.." && pwd)}
# shellcheck disable=SC1007  # keep cd silent even when the caller exports CDPATH
prefix=$(CDPATH= cd -- "$prefix" && pwd)
declare -A audited_objects=()
declare -A internal_objects=()

find_internal_library() {
    local soname=$1
    find "$prefix" \( -type f -o -type l \) -name "$soname" -print -quit 2>/dev/null
}

audit_needed_closure() {
    local object=$1
    local canonical soname needed internal
    canonical=$(readlink -f "$object")
    [[ -n ${audited_objects[$canonical]:-} ]] && return
    audited_objects[$canonical]=1
    needed=$(readelf -d "$object" | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p')
    printf 'DT_NEEDED for %s:\n%s\n' "$object" "${needed:-<none>}"
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
        esac
        internal=$(find_internal_library "$soname")
        if [[ -n $internal ]]; then
            printf 'internal runtime library: %s -> %s\n' "$soname" "$internal"
            internal_objects[$internal]=1
            audit_needed_closure "$internal"
            continue
        fi
        case $soname in
            libc.so.6|libdl.so.2|libpthread.so.0|libm.so.6|libgcc_s.so.1|\
            librt.so.1|libutil.so.1|ld-linux-x86-64.so.2|\
            libX11.so.6|libX11-xcb.so.1|libXfixes.so.3|libxcb.so.1|\
            libxcb-icccm.so.4|libxcb-image.so.0|libxcb-keysyms.so.1|\
            libxcb-randr.so.0|libxcb-render.so.0|libxcb-render-util.so.0|\
            libxcb-shape.so.0|libxcb-shm.so.0|libxcb-sync.so.1|\
            libxcb-xfixes.so.0|libxcb-xkb.so.1|libxcb-res.so.0|\
            libxcb-glx.so.0|libEGL.so.1|libICE.so.6|libSM.so.6|\
            libcanberra.so.0)
                ;;
            *)
                printf 'error: undeclared dynamic dependency: %s\n' "$soname" >&2
                exit 1
                ;;
        esac
    done <<< "$needed"
}

audit_needed_closure "$binary"

if (( ${#internal_objects[@]} > 0 )); then
    runtime_paths=$(readelf -d "$binary" \
        | sed -n 's/.*Library \(rpath\|runpath\): \[\([^]]*\)\].*/\2/p')
    if ! grep -Fq "\$ORIGIN/../lib" <<< "$runtime_paths"; then
        printf 'error: internal runtime libraries require an origin-relative ../lib RPATH; got: %s\n' \
            "${runtime_paths:-<none>}" >&2
        exit 1
    fi
fi

string_table=$(strings "$binary")
grep -q 'QXcbIntegrationPlugin' <<< "$string_table" || {
    printf 'error: qxcb static plugin is absent\n' >&2
    exit 1
}
grep -Eq 'QXcb(Glx|Egl)IntegrationPlugin' <<< "$string_table" || {
    printf 'error: qxcb GL integration plugin is absent\n' >&2
    exit 1
}
printf 'Konsole artifact contract: PASS (static Qt/KF6, host X11/Canberra/OpenGL ABI only)\n'
