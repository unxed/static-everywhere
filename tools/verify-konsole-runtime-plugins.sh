#!/usr/bin/env bash
# Verify the portable bundle's KDE MODULE payload before graphical smoke.
#
# KWindowSystem's X11 backend is an explicit runtime boundary: its static
# library is part of konsole, but its platform implementation is a MODULE
# loaded through QPluginLoader. A layout-only fixture cannot prove that the
# real install preserved this ELF, so the built bundle checks the contract at
# the point where it is produced. The inventory also makes a missing or
# unexpectedly relocated module visible in a failed CI diagnostic.
set -euo pipefail

if [[ $# -ne 1 || ! -d $1 ]]; then
    printf 'usage: %s KONSOLE_RUNTIME_DIR\n' "$0" >&2
    exit 2
fi

runtime=$(CDPATH= cd -- "$1" && pwd)
plugin_root="$runtime/lib/plugins"
plugin="$plugin_root/kf6/kwindowsystem/KF6WindowSystemX11Plugin.so"

[[ -d $plugin_root ]] || {
    printf 'error: portable bundle has no plugin root: %s\n' "$plugin_root" >&2
    exit 1
}
[[ -f $plugin && ! -L $plugin ]] || {
    printf 'error: portable bundle is missing the KWindowSystem X11 MODULE: %s\n' "$plugin" >&2
    printf '%s\n' 'Portable plugin inventory:' >&2
    find -L "$plugin_root" -type f -name '*.so*' -printf '  %P\n' | sort >&2 || true
    exit 1
}

printf 'Portable plugin inventory (%s):\n' "$plugin_root"
find -L "$plugin_root" -type f -name '*.so*' -printf '  %P\n' | sort

file_output=$(file -b "$plugin")
grep -Fq 'ELF' <<<"$file_output" || {
    printf 'error: KWindowSystem X11 MODULE is not an ELF object: %s\n' "$file_output" >&2
    exit 1
}
elf_header=$(readelf -h "$plugin") || {
    printf 'error: readelf could not inspect KWindowSystem X11 MODULE\n' >&2
    exit 1
}
grep -Fq 'DYN (Shared object file)' <<<"$elf_header" || {
    printf 'error: KWindowSystem X11 MODULE is not an ELF shared object\n' >&2
    readelf -h "$plugin" >&2
    exit 1
}

# Q_PLUGIN_METADATA embeds both the interface IID and the xcb platform name.
# Checking both strings catches a copied-but-wrong module and protects the
# metadata contract that KWindowSystem uses before calling instance().
plugin_strings=$(strings -a "$plugin") || {
    printf 'error: strings could not inspect KWindowSystem X11 MODULE\n' >&2
    exit 1
}
grep -Fq 'org.kde.kwindowsystem.KWindowSystemPluginInterface' <<<"$plugin_strings" || {
    printf 'error: KWindowSystem X11 MODULE has no expected plugin IID\n' >&2
    exit 1
}
grep -Fq 'xcb' <<<"$plugin_strings" || {
    printf 'error: KWindowSystem X11 MODULE has no xcb platform metadata\n' >&2
    exit 1
}

printf 'Konsole runtime plugin payload: PASS (KWindowSystem X11 MODULE is present and loadable-shaped)\n'
