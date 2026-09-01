#!/usr/bin/env bash
# Regression test for host ABI discovery after Zig makes CMake's ABI probe
# fail. CMake must retain the fixed x86_64 multiarch metadata before KDE's
# FindX11/FindXCB MODULEs call find_library().
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
PROBE=$(mktemp -d /tmp/static-everywhere-konsole-host-cmake.XXXXXX)
trap 'rm -rf "$PROBE"' EXIT

if ! command -v cmake >/dev/null 2>&1; then
    printf 'cmake unavailable; skipping\n'
    exit 0
fi
if [ ! -e /usr/include/X11/Xlib.h ] ||
   [ ! -e /usr/lib/x86_64-linux-gnu/libX11.so ]; then
    printf 'X11 development files unavailable; skipping\n'
    exit 0
fi

# Deliberately erase the values that a failed Zig compiler probe leaves
# behind. The repository hook must restore them before the project continues.
cat >"$PROBE/project-include.cmake" <<CMAKE
set(CMAKE_SIZEOF_VOID_P "")
set(CMAKE_LIBRARY_ARCHITECTURE "")
set(CMAKE_C_IMPLICIT_INCLUDE_DIRECTORIES "")
set(CMAKE_CXX_IMPLICIT_INCLUDE_DIRECTORIES "")
include("$REPO_ROOT/contrib/konsole/project-include.cmake")
CMAKE

mkdir -p "$PROBE/source"
cat >"$PROBE/source/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.21)
project(konsole_host_cmake_discovery C)

if(NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
    message(FATAL_ERROR "the fixed target pointer size was not restored")
endif()
if(NOT CMAKE_LIBRARY_ARCHITECTURE STREQUAL "x86_64-linux-gnu")
    message(FATAL_ERROR "the fixed multiarch target was not restored")
endif()
if(NOT CMAKE_C_IMPLICIT_INCLUDE_DIRECTORIES STREQUAL "/usr/include")
    message(FATAL_ERROR "the C implicit include contract was not restored")
endif()

find_package(X11 MODULE REQUIRED)
if(NOT X11_X11_LIB OR NOT EXISTS "${X11_X11_LIB}")
    message(FATAL_ERROR "FindX11 did not discover the host X11 library")
endif()
message(STATUS "host X11 discovery: ${X11_X11_LIB}")
CMAKE

cmake -S "$PROBE/source" -B "$PROBE/build" -G Ninja \
    -DCMAKE_PROJECT_INCLUDE="$PROBE/project-include.cmake"
printf 'Konsole host CMake discovery regression: PASS\n'
