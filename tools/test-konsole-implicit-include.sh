#!/usr/bin/env bash
# /usr/include must be treated as implicit for every kde-builder module,
# even after CMake's compiler detection shadows the cache value.
#
# Why this exists
# ---------------
# konsole compiled TerminalDisplay.cpp against the host's ICU 74 headers
# and linked Conan's ICU 78 archives: undefined ubidi_*_74. FindX11 hands
# X11 consumers X11_INCLUDE_DIR=/usr/include, and CMake -- unable to
# introspect zig-c++ -- records no implicit include dirs, so it emits
# that as -I/usr/include ahead of the Conan paths.
#
# The first fix set CMAKE_CXX_IMPLICIT_INCLUDE_DIRECTORIES via -D. The
# value reached konsole's CMakeCache and did nothing: CMakeCXXCompiler.cmake
# runs `set(... "")` as a normal variable, which shadows the cache. The
# hook now sets the normal variable after project(). This checks the
# behaviour -- host include absent from the compile line -- under exactly
# that shadowing.
set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
HOOK="${REPO_ROOT}/contrib/konsole/project-include.cmake"
CXX="${REPO_ROOT}/onebin/toolchain/zig-c++"

if ! command -v cmake >/dev/null 2>&1 || ! command -v zig >/dev/null 2>&1; then
    printf 'cmake or zig unavailable; skipping\n'; exit 0
fi

PROBE=$(mktemp -d); trap 'rm -rf "$PROBE"' EXIT
mkdir -p "$PROBE/proj"
printf 'int v = 1;\n' >"$PROBE/proj/m.cpp"
cat >"$PROBE/proj/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.16)
project(consumer CXX)
add_library(fakex11 INTERFACE)
target_include_directories(fakex11 INTERFACE /usr/include)  # what FindX11 hands out
add_library(m m.cpp)
target_link_libraries(m PRIVATE fakex11)
EOF
# The shadowing CMakeCXXCompiler.cmake performs, reproduced verbatim.
printf 'set(CMAKE_CXX_IMPLICIT_INCLUDE_DIRECTORIES "")\n' >"$PROBE/shadow.cmake"

flags() {  # $1 = project-include
    rm -rf "$PROBE/b"
    cmake -S "$PROBE/proj" -B "$PROBE/b" -DCMAKE_CXX_COMPILER="$CXX" \
        -DCMAKE_CXX_IMPLICIT_INCLUDE_DIRECTORIES=/usr/include \
        -DCMAKE_PROJECT_INCLUDE="$1" >/dev/null 2>&1
    grep -oE '(-I|-isystem )/usr/include' "$PROBE/b/CMakeFiles/m.dir/flags.make" || true
}

# With only the cache value, shadowed: the host include must appear, or
# this test is not reproducing the failure.
[ -n "$(flags "$PROBE/shadow.cmake")" ] \
    || { printf 'the cache value alone survived shadowing; the probe does not\n' >&2
         printf 'reproduce the failure and proves nothing\n' >&2; exit 1; }

# With the real hook (which runs after the shadowing point): absent.
cat >"$PROBE/shadow-then-hook.cmake" <<EOF
set(CMAKE_CXX_IMPLICIT_INCLUDE_DIRECTORIES "")
include("$HOOK")
EOF
r=$(flags "$PROBE/shadow-then-hook.cmake")
[ -z "$r" ] \
    || { printf 'the hook does not keep /usr/include implicit: %s still emitted;\n' "$r" >&2
         printf 'the host ICU headers will shadow the Conan ones again\n' >&2; exit 1; }

printf 'implicit include: hook keeps /usr/include off the compile line despite cache shadowing\n'
