#!/usr/bin/env bash
# Assert that a statically linked Qt host really contains the xcb GL
# integration plugins.
#
# Why this exists
# ---------------
# The first desktop launch died with
#
#   QXcbIntegration: Cannot create platform OpenGL context, neither GLX
#                    nor EGL are enabled
#   Failed to initialize graphics backend for OpenGL.
#
# The window appeared and vanished half a second later, taking the TCP
# link to f4 with it. Qt was built with GLX and EGL support -- the
# archives sit in plugins/xcbglintegrations -- but in a static build
# those are separate plugins, and nothing emitted Q_IMPORT_PLUGIN for
# them. The platform plugin alone gives you a window and no way to draw.
#
# CI could not catch it. The smoke run forces QSG_RHI_BACKEND=software
# under the offscreen platform, so it never asks for a GL context and
# starts happily either way: a host incapable of using a GPU shipped
# green. This check is the positive assertion the smoke run cannot make.
#
# It reads the binary, not the build log: what matters is what ended up
# in the artifact.
set -euo pipefail

if [ "$#" -ne 1 ]; then
    printf 'usage: %s <qt-host-binary>\n' "$0" >&2
    exit 2
fi
BIN="$1"

if [ ! -f "$BIN" ]; then
    printf 'check-gl-integrations: %s does not exist\n' "$BIN" >&2
    exit 1
fi

# Qt registers a static plugin through a symbol named
# qt_static_plugin_<ClassName>; the xcb GL integrations are
# QXcbGlxIntegrationPlugin and QXcbEglIntegrationPlugin. Stripped
# binaries keep no .symtab entry for these, so look for the class name in
# the plugin metadata, which survives stripping because it is data.
found=""
for cls in QXcbGlxIntegrationPlugin QXcbEglIntegrationPlugin; do
    if strings -a "$BIN" 2>/dev/null | grep -qF "$cls"; then
        found="$found $cls"
    fi
done

if [ -z "$found" ]; then
    printf 'no xcb GL integration plugin is linked into %s\n' "$BIN" >&2
    printf '\n' >&2
    printf 'Neither QXcbGlxIntegrationPlugin nor QXcbEglIntegrationPlugin is\n' >&2
    printf 'present. On a real display Qt will report "neither GLX nor EGL\n' >&2
    printf 'are enabled", fail to create a context, and exit -- the window\n' >&2
    printf 'appears and disappears. The smoke run cannot see this because it\n' >&2
    printf 'forces software rendering.\n' >&2
    printf '\n' >&2
    printf 'Check that plugins/xcbglintegrations/*.a exist in the Qt package\n' >&2
    printf 'and that contrib/f4-qt/import-qt-static-plugins.cmake imports\n' >&2
    printf 'them.\n' >&2
    exit 1
fi

printf 'GL integrations linked:%s\n' "$found"
