#!/usr/bin/env bash
# Regression test for contrib/f4-qt/link-qt6-opengl.cmake.
#
# Two things have gone wrong with this hook, and both are pinned here:
#
#   1. CMAKE_PROJECT_INCLUDE is evaluated after nested project() calls too,
#      so the hook must ignore subprojects and defer only from the top-level
#      scope. It once fired inside ZoinGallery and aborted the build.
#   2. Naming a single consumer fixed the app and left f4's three test
#      executables failing on exactly the same missing archive. The hook
#      must repair Qt6::Quick's link interface, so every consumer inherits
#      it.
#
# The miniature project below mirrors the real shape rather than mocking
# it: a static library whose symbol lives in another static library, an
# imported target that fails to declare that edge, a nested subproject,
# and TWO consumers. It is built, not merely configured -- the first
# version of this test only grepped configure output for a message, which
# a hook that links the wrong target still prints.
set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT

mkdir -p "$PROBE/src/nested"
cat >"$PROBE/src/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.21)
project(hook_regression C)

# The nested project() comes FIRST, deliberately. CMAKE_PROJECT_INCLUDE
# runs the hook after it, at a point where Qt6::Quick does not exist yet,
# which is precisely the situation that aborted a real build. Declare it
# later and an unguarded hook would find the target already present and
# the guard would stop being load-bearing -- the first version of this
# test had exactly that ordering and its negative control passed a hook
# with the guard deleted.
add_subdirectory(nested)

# The archive that really holds the symbols (stands in for libQt6OpenGL.a).
file(WRITE "${CMAKE_BINARY_DIR}/gl.c" "int qopengl_symbol(void){return 1;}\n")
add_library(qt6opengl STATIC "${CMAKE_BINARY_DIR}/gl.c")
add_library(Qt6::OpenGL INTERFACE IMPORTED)
set_property(TARGET Qt6::OpenGL PROPERTY INTERFACE_LINK_LIBRARIES qt6opengl)

# Quick references those symbols but declares no edge -- the actual defect.
file(WRITE "${CMAKE_BINARY_DIR}/quick.c"
     "int qopengl_symbol(void); int quick(void){return qopengl_symbol();}\n")
add_library(qt6quick STATIC "${CMAKE_BINARY_DIR}/quick.c")
add_library(Qt6::Quick INTERFACE IMPORTED)
set_property(TARGET Qt6::Quick PROPERTY INTERFACE_LINK_LIBRARIES qt6quick)

file(WRITE "${CMAKE_BINARY_DIR}/m.c" "int quick(void); int main(void){return quick()-1;}\n")
add_executable(f4-qt-host "${CMAKE_BINARY_DIR}/m.c")
target_link_libraries(f4-qt-host PRIVATE Qt6::Quick)

# The targets that actually failed in CI were f4's tests, not the app.
add_executable(F4PanelSplitterTests "${CMAKE_BINARY_DIR}/m.c")
target_link_libraries(F4PanelSplitterTests PRIVATE Qt6::Quick)
CMAKE
printf '%s\n' \
    'cmake_minimum_required(VERSION 3.21)' \
    'project(nested_gallery NONE)' \
    >"$PROBE/src/nested/CMakeLists.txt"

fail() {
    printf '%s\n' "$1" >&2
    sed 's/^/  /' "$2" >&2
    exit 1
}

# Negative control: without the hook this must not link. A test that only
# ever sees the fixed state cannot tell a working hook from a build that
# never needed one.
cmake -S "$PROBE/src" -B "$PROBE/nohook" -G Ninja >"$PROBE/nohook.log" 2>&1
if cmake --build "$PROBE/nohook" >>"$PROBE/nohook.log" 2>&1; then
    fail 'the probe linked WITHOUT the hook -- it no longer reproduces the defect' \
         "$PROBE/nohook.log"
fi

cmake -S "$PROBE/src" -B "$PROBE/build" -G Ninja \
    -DCMAKE_PROJECT_INCLUDE="$REPO_ROOT/contrib/f4-qt/link-qt6-opengl.cmake" \
    >"$PROBE/configure.log" 2>&1

grep -Fq -- \
    "-- static-everywhere: added Qt6::OpenGL to Qt6::Quick's link interface" \
    "$PROBE/configure.log" \
    || fail 'the hook did not run in the top-level scope' "$PROBE/configure.log"

# Both consumers must link. Naming one target passes the app and fails
# here, which is exactly the regression this line exists to catch.
cmake --build "$PROBE/build" >"$PROBE/build.log" 2>&1 \
    || fail 'a consumer of Qt6::Quick still fails to link' "$PROBE/build.log"

printf 'Qt6::OpenGL hook: nested-project guard and both consumers link: pass\n'
