#!/usr/bin/env bash
# Verify the portable bundle's KDE plugin contract before graphical smoke.
#
# Qt is static in this recipe, and a static QtCore refuses every MODULE:
# QPluginLoader logs "Cannot load ... into a statically linked Qt library".
# KWindowSystem's X11 backend therefore has to be a static Qt plugin inside
# the executable, registered with Q_IMPORT_PLUGIN. The first CI run that
# shipped it as KF6WindowSystemX11Plugin.so passed a presence check here and
# still started without a window-system backend. Check what static Qt can
# actually use: the plugin class and its IID in the executable, and no
# bundled MODULE at all.
set -euo pipefail

if [[ $# -ne 1 || ! -d $1 ]]; then
    printf 'usage: %s KONSOLE_RUNTIME_DIR\n' "$0" >&2
    exit 2
fi

runtime=$(CDPATH= cd -- "$1" && pwd)
binary="$runtime/bin/konsole"
iid='org.kde.kwindowsystem.KWindowSystemPluginInterface'

[[ -f $binary ]] || {
    printf 'error: portable bundle has no Konsole executable: %s\n' "$binary" >&2
    exit 1
}

binary_strings=$(strings -a "$binary") || {
    printf 'error: strings could not inspect %s\n' "$binary" >&2
    exit 1
}
grep -Fq "$iid" <<<"$binary_strings" || {
    printf 'error: Konsole has no KWindowSystem plugin IID\n' >&2
    exit 1
}
grep -Fq 'X11Plugin' <<<"$binary_strings" || {
    printf 'error: Konsole does not contain the static KWindowSystem X11Plugin\n' >&2
    exit 1
}

# Icons. breeze is SVG-only and ships compiled into the executable as the
# KF6BreezeIcons resource: KIconTheme::initTheme() selects the "KIconEngine"
# theme, which needs KIconEngine's plugin, and Qt needs its SVG plugins to
# draw anything. The first bundles had none of these three, drew text-only
# toolbars, and still carried 15,000 breeze SVG files and symlinks nothing
# could render.
for class in KIconEnginePlugin QSvgIconPlugin QSvgPlugin; do
    grep -Fq "$class" <<<"$binary_strings" || {
        printf 'error: Konsole does not contain the static icon plugin %s\n' "$class" >&2
        exit 1
    }
done
icon_dirs=$(find "$runtime/share/icons" -mindepth 1 -maxdepth 1 -name 'breeze*' 2>/dev/null || true)
if [[ -n $icon_dirs ]]; then
    printf 'error: bundle ships breeze as files; it belongs in the executable:\n%s\n' "$icon_dirs" >&2
    exit 1
fi

# No module of any kind: static Qt refuses them all, so each one is dead
# weight (the 36046810445 bundle carried 123 MB), and one that claims a
# plugin IID only makes a missing static plugin look present.
modules=
while IFS= read -r -d '' object; do
    # Application libraries live at lib/ itself, next to $ORIGIN/../lib.
    [[ $(dirname -- "$object") == "$runtime/lib" ]] && continue
    modules+="  ${object#"$runtime"/}"$'\n'
done < <(find -L "$runtime" -type f -name '*.so*' -print0)
if [[ -n $modules ]]; then
    printf 'error: bundle ships loadable modules that static Qt cannot load:\n%s' "$modules" >&2
    exit 1
fi

printf 'Konsole runtime plugin payload: PASS (KWindowSystem X11 backend and icon engines are static plugins of the executable; breeze compiled in; no dead modules)\n'
