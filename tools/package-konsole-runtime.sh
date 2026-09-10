#!/usr/bin/env bash
# Make the installed Konsole tree portable without requiring user-managed
# environment variables. The executable keeps an $ORIGIN RPATH as its
# primary mechanism; the launcher supplies the data/library search paths that
# an ordinary desktop installation would provide.
set -euo pipefail

if [[ $# -ne 2 || ! -d $1 ]]; then
    printf 'usage: %s KDE_INSTALL_PREFIX OUTPUT_DIR\n' "$0" >&2
    exit 2
fi

prefix=$(CDPATH= cd -- "$1" && pwd)
output=$2
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

[[ -x "$prefix/bin/konsole" ]] || {
    printf 'error: missing installed Konsole: %s\n' "$prefix/bin/konsole" >&2
    exit 1
}
[[ -d "$prefix/lib" ]] || {
    printf 'error: missing installed library directory: %s/lib\n' "$prefix" >&2
    exit 1
}

mkdir -p "$output/bin" "$output/lib" "$output/share"
cp -a "$prefix/bin/konsole" "$output/bin/konsole"
if [[ -e "$prefix/bin/konsoleprofile" ]]; then
    cp -a "$prefix/bin/konsoleprofile" "$output/bin/konsoleprofile"
fi

# Copy every application-owned shared object at the install-lib root. This is
# a closure rule, not a libkonsoleapp name exception: a future Konsole split
# library is packaged automatically.
find "$prefix/lib" -maxdepth 1 \( -type f -o -type l \) -name '*.so*' \
    -exec cp -a --target-directory="$output/lib" {} +

# KDE_INSTALL_PLUGINDIR is not stable across KDE projects. In this recipe it
# is intentionally empty, so a MODULE target such as KWindowSystem's X11
# backend is installed below "$prefix/kf6" rather than "$prefix/lib". Other
# projects may use a lib/plugins or a multiarch Qt plugin directory. Normalize
# every nested shared object into one relocatable Qt plugin root while keeping
# its path below the plugin directory (platforms/, kf6/, imageformats/, ...).
# This closes the whole install-layout class instead of naming one framework.
while IFS= read -r -d '' module; do
    relative=${module#"$prefix"/}
    if [[ $relative == lib/*.so* && ${relative#lib/} != */* ]]; then
        continue
    fi
    case "$relative" in
        */plugins/*) plugin_relative=${relative#*/plugins/} ;;
        plugins/*) plugin_relative=${relative#plugins/} ;;
        lib/*) plugin_relative=${relative#lib/} ;;
        *) plugin_relative=$relative ;;
    esac
    destination="$output/lib/plugins/$plugin_relative"
    mkdir -p "$(dirname -- "$destination")"
    cp -a "$module" "$destination"
done < <(find "$prefix" -mindepth 2 \( -type f -o -type l \) -name '*.so*' -print0)

if [[ -d "$prefix/share" ]]; then
    cp -a "$prefix/share/." "$output/share/"
fi

install -m 755 "$repo_root/contrib/konsole/konsole-launcher.sh" "$output/konsole"
printf 'Konsole runtime bundle: %s\n' "$output"
printf 'Internal shared libraries:\n'
find "$output/lib" -maxdepth 1 \( -type f -o -type l \) -name '*.so*' -printf '  %f\n' | sort
