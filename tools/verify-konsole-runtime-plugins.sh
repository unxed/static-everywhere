#!/usr/bin/env bash
# Static Qt cannot load a KDE MODULE with QPluginLoader. Inspect the executable
# registration; the graphical smoke separately proves Qt actually selects it.
set -euo pipefail
if [[ $# -ne 1 || ! -d $1 ]]; then
    printf 'usage: %s KONSOLE_RUNTIME_DIR\n' "$0" >&2
    exit 2
fi
runtime=$(CDPATH= cd -- "$1" && pwd)
binary="$runtime/bin/konsole"
[[ -f $binary ]] || { printf 'missing Konsole executable\n' >&2; exit 1; }
if [[ -e $runtime/lib/plugins/kf6/kwindowsystem/KF6WindowSystemX11Plugin.so ]]; then
    printf 'error: redundant dynamic X11 backend in static Qt bundle\n' >&2
    exit 1
fi
symbols=$(nm --defined-only -C "$binary")
grep -Fq 'qt_static_plugin_X11Plugin()' <<<"$symbols" || {
    printf 'error: executable has no static KWindowSystem X11 registration\n' >&2
    exit 1
}
plugin_strings=$(strings -a "$binary")
grep -Fq 'org.kde.kwindowsystem.KWindowSystemPluginInterface' <<<"$plugin_strings" || {
    printf 'error: executable has no KWindowSystem plugin metadata\n' >&2
    exit 1
}
printf 'Konsole runtime plugins: PASS (X11 backend embedded in executable)\n'
