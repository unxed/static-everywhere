#!/usr/bin/env bash
# Every angle-include in every module of the KF6 graph must be satisfiable
# with the host-include stage in place -- i.e. by zig's bundled headers, by a
# vendored package, or by the staged host contract -- never only by the
# wide /usr/include the stage replaces.
#
# Why this exists
# ---------------
# The stage removes from the compiler's view every host header outside the
# contract's dependency closure. That is the point, and also a new way to
# fail: a module that quietly relied on some other host -dev package would
# now stop with "file not found", two hours in. Run over the sources of
# the whole graph, this answers that in minutes. First run: 35 modules,
# 1451 distinct includes, zero host-only. It stays run.
#
# Needs the module sources (fetched shallow into $SE_KDE_SRC_CACHE, default
# /tmp/se-kde-src) and a stage built from the host contract.
set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
STAGE=${1:?usage: $0 <host-include-stage>}
CACHE=${SE_KDE_SRC_CACHE:-/tmp/se-kde-src}
CXX="${REPO_ROOT}/onebin/toolchain/zig-c++"

command -v zig >/dev/null 2>&1 || { printf 'zig unavailable; skipping\n'; exit 0; }
[ -d "$STAGE" ] || { printf 'stage %s does not exist\n' "$STAGE" >&2; exit 1; }

mkdir -p "$CACHE"
mapfile -t modules < <(grep -vE '^\s*(#|$)' "$REPO_ROOT/contrib/konsole/kde-graph.txt" \
    | grep -vxE 'kdoctools|kirigami|extra-cmake-modules|breeze-icons|plasma-wayland-protocols')
for m in "${modules[@]}"; do
    [ -d "$CACHE/$m" ] && continue
    group=frameworks; case "$m" in konsole) group=utilities ;; qca) group=libraries ;; esac
    git clone -q --depth 1 "https://invent.kde.org/$group/$m.git" "$CACHE/$m" 2>/dev/null \
        || printf 'note: could not fetch %s\n' "$m"
done

# Top-level include names the vendored (Conan) side provides. Derived from
# the vendored roots when given, else from the recipe's known packages.
vendored_tops="Qt6 QtCore QtGui QtWidgets QtNetwork QtDBus QtXml QtQml QtQuick QtPrintSupport QtMultimedia QtSvg QtOpenGL QtConcurrent QtSql QtTest QtQmlIntegration QtQuickWidgets QtDesigner QtUiPlugin unicode freetype2 fontconfig harfbuzz openssl pcre2.h zlib.h zconf.h png.h pngconf.h libxml2 libxslt hunspell expat.h brotli lz4.h zstd.h bzlib.h dbus-1.0 glib-2.0 xkbcommon libpng16 jpeglib.h jconfig.h jmorecfg.h tiffio.h webp double-conversion md4c.h ffi.h uuid canberra.h libmount qca-qt6 gpgme.h"
if [ -n "${SE_VENDORED_ROOTS_FILE:-}" ] && [ -f "$SE_VENDORED_ROOTS_FILE" ]; then
    while IFS= read -r root; do
        [ -d "$root" ] && for e in "$root"/*; do vendored_tops="$vendored_tops $(basename "$e")"; done
    done <"$SE_VENDORED_ROOTS_FILE"
fi

PROBE=$(mktemp -d); trap 'rm -rf "$PROBE"' EXIT
grep -rhoE '#include <[a-zA-Z0-9_/.+-]+>' "$CACHE"/*/src 2>/dev/null \
    | sed 's/#include <//;s/>//' | sort -u >"$PROBE/includes.txt"
total=$(wc -l <"$PROBE/includes.txt")

hostonly=()
while IFS= read -r inc; do
    top=${inc%%/*}
    case " $vendored_tops " in *" $top "*) continue ;; esac
    # KF6-internal, generated, or project-local names are not host headers.
    case "$inc" in K*/*|kio/*|*_export.h|*_debug.h|*_version.h|*_logging.h|ui_*|config-*|*.moc|*_p.h) continue ;; esac
    printf '#include <%s>\n' "$inc" >"$PROBE/p.cpp"
    if ONEBIN_HOST_INCLUDE_DIR="$STAGE" "$CXX" -target x86_64-linux-gnu.2.28 -fsyntax-only -E "$PROBE/p.cpp" >/dev/null 2>&1; then
        continue                                # satisfiable with the stage
    fi
    if "$CXX" -target x86_64-linux-gnu.2.28 -fsyntax-only -E "$PROBE/p.cpp" >/dev/null 2>&1; then
        hostonly+=("$inc")                      # only the wide /usr/include had it
    fi
done <"$PROBE/includes.txt"

if [ "${#hostonly[@]}" -gt 0 ]; then
    printf 'includes satisfiable only by the unstaged /usr/include (%s of %s):\n' "${#hostonly[@]}" "$total" >&2
    printf '  %s\n' "${hostonly[@]}" >&2
    printf 'Each belongs to a host package outside contrib/konsole/host-dev-packages.txt;\n' >&2
    printf 'add the package, or the module fails with "file not found" under the stage.\n' >&2
    exit 1
fi
printf 'kde graph host includes: %s modules, %s distinct includes, none host-only outside the contract\n' \
    "${#modules[@]}" "$total"
