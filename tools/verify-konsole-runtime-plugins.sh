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
# bundled KWindowSystem MODULE that claims the IID it can never serve.
set -euo pipefail

if [[ $# -ne 1 || ! -d $1 ]]; then
    printf 'usage: %s KONSOLE_RUNTIME_DIR\n' "$0" >&2
    exit 2
fi

runtime=$(CDPATH= cd -- "$1" && pwd)
binary="$runtime/bin/konsole"
plugin_root="$runtime/lib/plugins"
iid='org.kde.kwindowsystem.KWindowSystemPluginInterface'

[[ -f $binary ]] || {
    printf 'error: portable bundle has no Konsole executable: %s\n' "$binary" >&2
    exit 1
}

printf 'Portable plugin inventory (%s):\n' "$plugin_root"
if [[ -d $plugin_root ]]; then
    find -L "$plugin_root" -type f -name '*.so*' -printf '  %P\n' | sort
fi

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

if [[ -d $plugin_root/kf6/kwindowsystem ]]; then
    while IFS= read -r -d '' module; do
        module_strings=$(strings -a "$module") || {
            printf 'error: strings could not inspect %s\n' "$module" >&2
            exit 1
        }
        if grep -Fq "$iid" <<<"$module_strings"; then
            printf 'error: bundle ships a KWindowSystem MODULE that static Qt cannot load: %s\n' \
                "$module" >&2
            exit 1
        fi
    done < <(find -L "$plugin_root/kf6/kwindowsystem" -type f -name '*.so*' -print0)
fi

printf 'Konsole runtime plugin payload: PASS (KWindowSystem X11 backend is a static plugin of the executable)\n'
