#!/usr/bin/env bash
# Regression test for contrib/f4-qt/link-qt6-opengl.cmake.
#
# CMAKE_PROJECT_INCLUDE is evaluated after nested project() calls too. The
# hook must ignore those subprojects and defer only from the top-level scope.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT

mkdir -p "$PROBE/src/nested"
printf '%s\n' \
    'cmake_minimum_required(VERSION 3.21)' \
    'project(hook_regression C)' \
    'add_library(Qt6::OpenGL INTERFACE IMPORTED)' \
    'add_subdirectory(nested)' \
    'file(WRITE "${CMAKE_BINARY_DIR}/f4.c" "void f4(void) {}\\n")' \
    'add_library(f4-qt-host STATIC "${CMAKE_BINARY_DIR}/f4.c")' \
    >"$PROBE/src/CMakeLists.txt"
printf '%s\n' \
    'cmake_minimum_required(VERSION 3.21)' \
    'project(nested_gallery NONE)' \
    >"$PROBE/src/nested/CMakeLists.txt"

cmake -S "$PROBE/src" -B "$PROBE/build" -G Ninja \
    -DCMAKE_PROJECT_INCLUDE="$REPO_ROOT/contrib/f4-qt/link-qt6-opengl.cmake" \
    >"$PROBE/configure.log" 2>&1

grep -Fq -- \
    '-- static-everywhere: linked Qt6::OpenGL into f4-qt-host' \
    "$PROBE/configure.log" || {
        printf 'top-level Qt6::OpenGL hook did not run successfully\n' >&2
        sed 's/^/  /' "$PROBE/configure.log" >&2
        exit 1
    }

printf 'Qt6::OpenGL hook nested-project guard: pass\n'
