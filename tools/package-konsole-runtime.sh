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
cp -aL "$prefix/bin/konsole" "$output/bin/konsole"
if [[ -e "$prefix/bin/konsoleprofile" ]]; then
    cp -aL "$prefix/bin/konsoleprofile" "$output/bin/konsoleprofile"
fi

# Copy every application-owned shared object at the install-lib root. This is
# a closure rule, not a libkonsoleapp name exception: a future Konsole split
# library is packaged automatically.
find -L "$prefix/lib" -maxdepth 1 -type f -name '*.so*' \
    -exec cp -aL --target-directory="$output/lib" {} +

# Loadable modules are not packaged. Qt is static in this recipe, and a
# static QtCore refuses every MODULE: QPluginLoader logs "Cannot load ...
# into a statically linked Qt library", and KPluginFactory goes through it.
# The bundle used to carry them anyway -- konsolepart.so,
# KIconEnginePlugin.so and the KWindowSystem placeholder, 123 MB that
# nothing could load. Whatever Konsole needs from a plugin is linked into
# the executable as a static Qt plugin (see verify-konsole-runtime-plugins.sh).
# The modules are listed so the omission stays visible in the build log.
# Only the install-lib root above is an application library directory.
skipped_modules=()
while IFS= read -r -d '' module; do
    relative=${module#"$prefix"/}
    if [[ $relative == lib/*.so* && ${relative#lib/} != */* ]]; then
        continue
    fi
    skipped_modules+=("$relative")
done < <(find -L "$prefix" -mindepth 2 -type f -name '*.so*' -print0 | sort -z)

# share/ keeps its relative symlinks. breeze-icons is 94% symlinks (54142
# files per theme, 7848 distinct): copying with -L turned 2 x 4.6 MB of
# icons into 470 MB of duplicates. A link that is absolute, leaves share/ or
# dangles only works on the machine that built it, so exactly those are
# replaced by a copy of what they point at. Build-time-only data is left
# out by contrib/konsole/runtime-share-exclude.txt.
if [[ -d "$prefix/share" ]]; then
    share_src=$(realpath -- "$prefix/share")
    cp -a "$share_src/." "$output/share/"
    while IFS= read -r -d '' link; do
        relative=${link#"$output/share/"}
        source_link="$share_src/$relative"
        target=$(readlink -- "$source_link")
        resolved=$(realpath -m -- "$(realpath -- "$(dirname -- "$source_link")")/$target")
        if [[ $target != /* && $resolved == "$share_src"/* && -e $source_link ]]; then
            continue
        fi
        [[ -e $source_link ]] || {
            printf 'error: dangling symlink in install share/: %s -> %s\n' "$relative" "$target" >&2
            exit 1
        }
        rm -f -- "$link"
        cp -aL -- "$source_link" "$link"
    done < <(find "$output/share" -type l -print0)
    while read -r excluded _; do
        [[ -z $excluded || $excluded == \#* ]] && continue
        case $excluded in
            /*|*..*) printf 'error: invalid share exclusion: %s\n' "$excluded" >&2; exit 1 ;;
        esac
        rm -rf -- "${output:?}/share/$excluded"
    done < "$repo_root/contrib/konsole/runtime-share-exclude.txt"
fi

install -m 755 "$repo_root/contrib/konsole/konsole-launcher.sh" "$output/konsole"
printf 'Konsole runtime bundle: %s\n' "$output"
printf 'Internal shared libraries:\n'
find "$output/lib" -maxdepth 1 \( -type f -o -type l \) -name '*.so*' -printf '  %f\n' | sort
if (( ${#skipped_modules[@]} > 0 )); then
    printf 'Loadable modules left out (static Qt cannot load them):\n'
    printf '  %s\n' "${skipped_modules[@]}"
fi
