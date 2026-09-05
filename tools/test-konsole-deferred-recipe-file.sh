#!/usr/bin/env bash
# Regression test for recipe files used from cmake_language(DEFER).
# The file deliberately lives outside the CMake source directory: resolving
# CMAKE_CURRENT_LIST_DIR in the deferred callback must not be used.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT

mkdir -p "$PROBE/source"
cat >"$PROBE/recipe-marker.cmake" <<'CMAKE'
set(SE_DEFERRED_RECIPE_MARKER "loaded" CACHE INTERNAL "deferred recipe probe")
CMAKE

cat >"$PROBE/source/CMakeLists.txt" <<CMAKE
cmake_minimum_required(VERSION 3.21)
project(konsole_deferred_recipe_file_probe NONE)

include("$REPO_ROOT/contrib/konsole/defer-recipe-file.cmake")
_se_konsole_defer_recipe_file("$PROBE/recipe-marker.cmake")

function(check_marker)
    if(NOT SE_DEFERRED_RECIPE_MARKER STREQUAL "loaded")
        message(FATAL_ERROR "deferred recipe file was not included")
    endif()
endfunction()
cmake_language(DEFER DIRECTORY "\${CMAKE_CURRENT_SOURCE_DIR}" CALL check_marker)
CMAKE

cmake -S "$PROBE/source" -B "$PROBE/build" -G Ninja \
    >"$PROBE/configure.log" 2>&1 || {
    sed -n '1,200p' "$PROBE/configure.log" >&2
    exit 1
}

printf 'PASS: deferred recipe files retain their absolute path\n'
