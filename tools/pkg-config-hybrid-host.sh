#!/usr/bin/env bash
# Keep the hybrid boundary explicit when Meson asks pkg-config for a static
# dependency closure. Static GTK/GLib archives must still receive their
# private dependencies, so the recipe keeps --prefer-static; this wrapper
# changes only declared X11/OpenGL -l arguments to explicit shared objects.
set -euo pipefail

HOST_LIBDIR=/usr/lib/x86_64-linux-gnu
HOST_DYNAMIC_LIBS=(
    X11 Xext Xi Xrandr Xrender Xcursor Xdamage Xfixes Xcomposite Xinerama
    X11-xcb Xau Xdmcp ICE SM xcb xcb-render xcb-shm xcb-xkb
    xcb-render-util xcb-image xcb-keysyms xcb-util xcb-xinerama xcb-cursor
    Xtst GL EGL GLX
)

host_shared_object() {
    local library=$1 candidate
    for candidate in \
        "${HOST_LIBDIR}/lib${library}.so" \
        "${HOST_LIBDIR}/lib${library}.so."*; do
        if [ -e "${candidate}" ]; then
            printf '%s' "${candidate}"
            return 0
        fi
    done
    return 1
}

output=$(/usr/bin/pkg-config "$@")
needs_rewrite=0
for library in "${HOST_DYNAMIC_LIBS[@]}"; do
    if grep -Eq "(^| )-l${library}( |$)" <<<"${output}"; then
        needs_rewrite=1
        host_shared_object "${library}" >/dev/null || {
            printf 'pkg-config-hybrid-host: dynamic host library is missing: %s\n' \
                "${HOST_LIBDIR}/lib${library}.so[.SONAME]" >&2
            exit 1
        }
    fi
done

if [ "${needs_rewrite}" -eq 0 ]; then
    printf '%s\n' "${output}"
    exit 0
fi

for library in "${HOST_DYNAMIC_LIBS[@]}"; do
    shared_object=$(host_shared_object "${library}" 2>/dev/null || true)
    [ -n "${shared_object}" ] || continue
    output=$(printf '%s\n' "${output}" \
        | sed "s#\(^\| \)-l${library}\( \|$\)#\1${shared_object}\2#g")
done
printf '%s\n' "${output}"
