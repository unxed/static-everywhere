#!/usr/bin/env bash
set -euo pipefail

if [[ ($# -ne 1 && $# -ne 2) || ! -x $1 ]]; then
    printf 'usage: %s EXECUTABLE [INSTALL_PREFIX]\n' "$0" >&2
    exit 2
fi

binary=$1
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HOST_RUNTIME_CONTRACT="$SCRIPT_DIR/../contrib/konsole/host-runtime-sonames.txt"
# shellcheck disable=SC1007  # keep cd silent even when the caller exports CDPATH
prefix=${2:-$(CDPATH= cd -- "$(dirname -- "$binary")/.." && pwd)}
# shellcheck disable=SC1007  # keep cd silent even when the caller exports CDPATH
prefix=$(CDPATH= cd -- "$prefix" && pwd)
declare -A audited_objects=()
declare -A internal_objects=()
declare -A allowed_host_sonames=()

while IFS= read -r soname || [[ -n $soname ]]; do
    [[ -z $soname || $soname == \#* ]] && continue
    [[ $soname =~ ^[A-Za-z0-9._+-]+$ ]] || {
        printf 'error: invalid host runtime SONAME: %s\n' "$soname" >&2
        exit 1
    }
    case $soname in
        libGL.so*|libGLX.so*|libOpenGL.so*)
            printf 'error: OpenGL SONAME is forbidden in the host runtime contract: %s\n' "$soname" >&2
            exit 1
            ;;
    esac
    allowed_host_sonames[$soname]=1
done < "$HOST_RUNTIME_CONTRACT"
(( ${#allowed_host_sonames[@]} > 0 )) || {
    printf 'error: host runtime contract is empty: %s\n' "$HOST_RUNTIME_CONTRACT" >&2
    exit 1
}

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
        [[ -n ${allowed_host_sonames[$soname]:-} ]] || {
            printf 'error: undeclared dynamic dependency: %s\n' "$soname" >&2
            exit 1
        }
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
