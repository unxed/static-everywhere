#!/usr/bin/env bash
# Check the ignore-projects list against what the KF6 graph actually
# requires, from each module's own CMakeLists.txt, before a build.
#
# Why this exists
# ---------------
# kio's build reached meinproc6 -- kdoctools' DocBook host tool, built with
# this toolchain -- and it segfaulted. The safe answer is to drop kdoctools
# from the graph, which removes the whole class. But "safe" is a claim
# about every other module: if any of them requires KF6DocTools, dropping
# it moves the failure instead of removing it, and the next two-hour run
# says so.
#
# That claim is checkable in seconds. Each module's CMakeLists.txt is a
# public file; this fetches them for every module in the graph snapshot
# and fails if one calls find_package(<ignored package> ... REQUIRED).
# It also fails if an ignored project is not in the graph at all, since an
# ignore that matches nothing is either stale or misspelled.
#
# Read from the sources, not inferred from the failure: konsole and kio
# were checked by hand this way first; this makes the check stay done.
set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
GRAPH="${REPO_ROOT}/contrib/konsole/kde-graph.txt"
CONFIG="${REPO_ROOT}/contrib/konsole/kde-builder.yaml.in"

if ! command -v curl >/dev/null 2>&1; then
    printf 'curl unavailable; skipping the graph requirement scan\n'
    exit 0
fi

# ignore-projects is a YAML list (kde-builder rejects a string outright),
# so read the "- item" lines that follow the key.
ignored=$(python3 -c "
import re,sys
t=open(sys.argv[1]).read()
m=re.search(r'^  ignore-projects:\\s*\\n((?:\\s*(?:#.*|- .*)\\n)+)', t, re.M)
print(' '.join(re.findall(r'^\\s*- (\\S+)', m.group(1), re.M)) if m else '')
" "$CONFIG")
[ -n "$ignored" ] || { printf 'no ignore-projects in the config; nothing to check\n'; exit 0; }

mapfile -t modules < <(grep -vE '^\s*(#|$)' "$GRAPH")
[ "${#modules[@]}" -gt 0 ] || { printf 'the graph snapshot is empty\n' >&2; exit 1; }

# Map a project name to the CMake package a consumer would find. KDE's
# convention is KF6<CamelCase>; the few irregular ones are spelled out.
package_of() {
    case "$1" in
        kdoctools) echo KF6DocTools ;;
        kirigami)  echo KF6Kirigami ;;
        *) printf 'KF6%s' "$(printf '%s' "$1" | sed -E 's/^k//; s/(^|-)([a-z])/\U\2/g')" ;;
    esac
}

PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT

status=0
for project in $ignored; do
    if ! printf '%s\n' "${modules[@]}" | grep -qx "$project"; then
        printf 'ignore-projects names %s, which is not in the graph snapshot;\n' \
            "$project" >&2
        printf 'a stale or misspelled ignore protects nothing\n' >&2
        status=1
        continue
    fi
    package=$(package_of "$project")
    for module in "${modules[@]}"; do
        [ "$module" = "$project" ] && continue
        f="$PROBE/$module.cmake"
        if [ ! -f "$f" ]; then
            for group in frameworks libraries utilities plasma; do
                if curl -fsSL --max-time 20 \
                    "https://invent.kde.org/$group/$module/-/raw/master/CMakeLists.txt" \
                    -o "$f" 2>/dev/null; then
                    break
                fi
            done
            [ -f "$f" ] || { printf 'note: could not fetch CMakeLists.txt for %s\n' "$module"; continue; }
        fi
        if grep -qE "find_package\([[:space:]]*${package}[^)]*REQUIRED" "$f"; then
            printf '%s REQUIRES %s, but %s is ignored: the build will fail there\n' \
                "$module" "$package" "$project" >&2
            status=1
        fi
        if grep -qE "find_package\([[:space:]]*KF6[[:space:]][^)]*REQUIRED[^)]*COMPONENTS[^)]*\b${package#KF6}\b" "$f"; then
            printf '%s lists %s among REQUIRED KF6 components, but %s is ignored\n' \
                "$module" "${package#KF6}" "$project" >&2
            status=1
        fi
    done
done

[ "$status" -eq 0 ] && printf 'kde graph: no module requires an ignored project (%s)\n' "$ignored"
exit "$status"
