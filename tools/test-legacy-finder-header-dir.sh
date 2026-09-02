#!/usr/bin/env bash
# A legacy-variable adapter must point at the directory that actually
# holds the header the consumer includes.
#
# Why this exists
# ---------------
# Konsole's KF6 build failed at sonnet:
#
#   sonnet/src/plugins/hunspell/hunspelldict.h:11:10:
#       fatal error: 'hunspell.hxx' file not found
#
# The package was found -- Conan declared hunspell::hunspell and sonnet
# enabled the plugin -- but no hunspell include directory reached the
# compile line. The adapter handed over the imported target's
# INTERFACE_INCLUDE_DIRECTORIES, which is <pkg>/include, while the header
# lives at <pkg>/include/hunspell/hunspell.hxx and sonnet writes
# `#include <hunspell.hxx>` unqualified. One level too high.
#
# Upstream's FindHUNSPELL resolves that with find_path and PATH_SUFFIXES.
# The adapter now does the same when told which header to look for, and
# searches inside the package only: falling back to the host would
# compile against a different hunspell than the one being linked.
set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

if ! command -v cmake >/dev/null 2>&1; then
    printf 'cmake unavailable; skipping\n'
    exit 0
fi

PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT

# A package laid out the way Conan lays hunspell out: the target's
# include dir is include/, the header is one level below it.
mkdir -p "$PROBE/pkg/include/hunspell" "$PROBE/proj"
printf '#pragma once\n' >"$PROBE/pkg/include/hunspell/hunspell.hxx"

cat >"$PROBE/proj/hunspell-config.cmake" <<EOF
add_library(hunspell::hunspell INTERFACE IMPORTED)
set_target_properties(hunspell::hunspell PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES "$PROBE/pkg/include")
EOF

python3 - "$REPO_ROOT" "$PROBE" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + '/contrib/konsole/qt-host')
from qt_cmake_components import legacy_package_config
open(sys.argv[2] + '/proj/HUNSPELLConfig.cmake', 'w').write(
    legacy_package_config(
        package='hunspell', target='hunspell::hunspell',
        variable_prefix='HUNSPELL', version='1.7.2',
        header='hunspell.hxx', path_suffixes='hunspell'))
PY

cat >"$PROBE/proj/CMakeLists.txt" <<EOF
cmake_minimum_required(VERSION 3.16)
project(adapter NONE)
set(hunspell_PACKAGE_FOLDER_RELEASE "$PROBE/pkg")
include("\${CMAKE_CURRENT_SOURCE_DIR}/HUNSPELLConfig.cmake")
message(STATUS "RESOLVED=\${HUNSPELL_INCLUDE_DIRS}")
EOF

resolved=$(cmake -S "$PROBE/proj" -B "$PROBE/build" 2>&1 \
           | sed -n 's/^-- RESOLVED=//p')

if [ -z "$resolved" ]; then
    printf 'the adapter set no include directory at all\n' >&2
    exit 1
fi

# The point: the directory must contain the header, not merely be an
# ancestor of it. Handing over an ancestor is exactly what failed.
if [ ! -f "$resolved/hunspell.hxx" ]; then
    printf 'the adapter resolved to %s, which does not contain\n' "$resolved" >&2
    printf 'hunspell.hxx. A consumer including it unqualified will fail\n' >&2
    printf 'with "file not found", which is the sonnet build failure.\n' >&2
    exit 1
fi

# And it must not wander outside the package. Rebuild with the header
# absent from the package but present elsewhere; the adapter must not
# find the stray copy.
rm -f "$PROBE/pkg/include/hunspell/hunspell.hxx"
mkdir -p "$PROBE/elsewhere/hunspell"
printf '#pragma once\n' >"$PROBE/elsewhere/hunspell/hunspell.hxx"
stray_out=$(CMAKE_PREFIX_PATH="$PROBE/elsewhere" \
            cmake -S "$PROBE/proj" -B "$PROBE/build2" 2>&1 || true)
strayed=$(printf '%s' "$stray_out" | sed -n 's/^-- RESOLVED=//p')
case "$strayed" in
    "$PROBE/elsewhere"*)
        printf 'the adapter resolved outside the package, to %s\n' "$strayed" >&2
        printf 'That compiles against headers from a different build than\n' >&2
        printf 'the library being linked.\n' >&2
        exit 1
        ;;
esac

# With the header genuinely absent from the package, the adapter must
# say so rather than report the package found with nothing usable. That
# is the difference between failing here and failing inside some
# consumer's compile with a bare "file not found".
printf '%s' "$stray_out" | grep -q 'FATAL_ERROR\|is not under the' \
    || { printf 'the adapter stayed quiet when the header was missing:\n' >&2
         printf '%s\n' "$stray_out" | tail -5 | sed 's/^/  /' >&2
         exit 1; }

# Prevention, not just repair: properties that make the next adapter of
# this shape impossible rather than merely unlikely.
python3 - "$REPO_ROOT" <<'INVARIANTS'
import ast, pathlib, sys

root = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(root / 'contrib/konsole/qt-host'))
from qt_cmake_components import legacy_package_config

# 1. An adapter cannot be written without saying which header its
#    consumers include. Forgetting that is what let the include directory
#    default to the package root.
try:
    legacy_package_config(package='p', target='p::p',
                          variable_prefix='P', version='1')
except TypeError:
    pass
else:
    sys.exit('an adapter was generated with no header declared')

# 2. Nor with an empty one, the same mistake spelled differently.
try:
    legacy_package_config(package='p', target='p::p',
                          variable_prefix='P', version='1', header='')
except ValueError:
    pass
else:
    sys.exit('an adapter was generated with an empty header')

# 3. Every call site actually passes one, so a future adapter added
#    without it fails here rather than in some consumer's compile.
source = (root / 'contrib/konsole/qt-host/conanfile.py').read_text()
calls = [n for n in ast.walk(ast.parse(source))
         if isinstance(n, ast.Call)
         and getattr(n.func, 'id', '') == 'legacy_package_config']
if not calls:
    sys.exit('no legacy_package_config call sites found; renamed?')
for call in calls:
    if 'header' not in {kw.arg for kw in call.keywords}:
        sys.exit('a legacy_package_config call at line %d declares no header'
                 % call.lineno)

# 4. The generated adapter must fail loudly when the header does not
#    resolve, instead of reporting the package found with no usable
#    include directory.
generated = legacy_package_config(
    package='p', target='p::p', variable_prefix='P', version='1', header='p.h')
if 'FATAL_ERROR' not in generated:
    sys.exit('the adapter no longer fails when the header does not resolve')
INVARIANTS

printf 'legacy finder adapter: resolves to the header directory, stays in package\n'
