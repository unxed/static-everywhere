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

# Copy every application-owned shared object at the install-lib root and all
# installed KDE modules. This is a closure rule, not a libkonsoleapp name
# exception: a future Konsole split library is packaged automatically.
find "$prefix/lib" -maxdepth 1 \( -type f -o -type l \) -name '*.so*' \
    -exec cp -a --target-directory="$output/lib" {} +
if [[ -d "$prefix/lib/plugins" ]]; then
    cp -a "$prefix/lib/plugins" "$output/lib/"
fi
if [[ -d "$prefix/share" ]]; then
    cp -a "$prefix/share/." "$output/share/"
fi

install -m 755 "$repo_root/contrib/konsole/konsole-launcher.sh" "$output/konsole"
printf 'Konsole runtime bundle: %s\n' "$output"
printf 'Internal shared libraries:\n'
find "$output/lib" -maxdepth 1 \( -type f -o -type l \) -name '*.so*' -printf '  %f\n' | sort
