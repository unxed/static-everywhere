#!/usr/bin/env bash
# Keep the hybrid boundary explicit when Meson asks pkg-config for a static
# dependency closure. Static GTK/GLib archives must still receive their
# private dependencies, so the recipe keeps --prefer-static; this wrapper
# changes only host GUI/desktop -l arguments to explicit shared objects.
set -euo pipefail

HOST_LIBDIR=/usr/lib/x86_64-linux-gnu
HOST_DYNAMIC_LIBS=(
    X11 Xext Xi Xrandr Xrender Xcursor Xdamage Xfixes Xcomposite Xinerama
    X11-xcb Xau Xdmcp ICE SM xcb xcb-render xcb-shm xcb-xkb
    xcb-render-util xcb-image xcb-keysyms xcb-util xcb-xinerama xcb-cursor
    GL EGL GLX dbus-1 atspi atk-bridge-2.0
)

output=$(/usr/bin/pkg-config "$@")
needs_rewrite=0
for library in "${HOST_DYNAMIC_LIBS[@]}"; do
    if grep -Eq "(^| )-l${library}( |$)" <<<"${output}"; then
        needs_rewrite=1
        [ -e "${HOST_LIBDIR}/lib${library}.so" ] || {
            printf 'pkg-config-hybrid-host: dynamic host library is missing: %s\n' \
                "${HOST_LIBDIR}/lib${library}.so" >&2
            exit 1
        }
    fi
done

if [ "${needs_rewrite}" -eq 0 ]; then
    printf '%s\n' "${output}"
    exit 0
fi

for library in "${HOST_DYNAMIC_LIBS[@]}"; do
    output=$(printf '%s\n' "${output}" \
        | sed "s#\(^\| \)-l${library}\( \|$\)#\1${HOST_LIBDIR}/lib${library}.so\2#g")
done
printf '%s\n' "${output}"
