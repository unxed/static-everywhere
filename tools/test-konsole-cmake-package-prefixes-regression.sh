#!/usr/bin/env bash
# Regression test for Conan CMake package directories exposed through
# CMAKE_MODULE_PATH but consumed by CONFIG-mode find_package().
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
PROBE=$(mktemp -d /tmp/static-everywhere-konsole-cmake-prefixes.XXXXXX)
trap 'rm -rf "$PROBE"' EXIT

mkdir -p "$PROBE/prefix/lib/cmake/Qt6Core" "$PROBE/source"
printf '%s\n' 'set(Qt6Core_FOUND TRUE)' >"$PROBE/prefix/lib/cmake/Qt6Core/Qt6CoreConfig.cmake"
cat >"$PROBE/source/CMakeLists.txt" <<CMAKE
cmake_minimum_required(VERSION 3.21)
project(konsole_cmake_package_prefix_probe CXX)
find_package(Qt6Core CONFIG REQUIRED)
if(NOT Qt6Core_FOUND)
    message(FATAL_ERROR "Qt6Core was not found through the promoted prefix")
endif()
CMAKE

cmake -S "$PROBE/source" -B "$PROBE/build" -G Ninja     -DCMAKE_PROJECT_INCLUDE="$REPO_ROOT/contrib/konsole/project-include.cmake"     -DCMAKE_MODULE_PATH="$PROBE/prefix/lib/cmake/Qt6Core"     -DCMAKE_PREFIX_PATH=
printf 'Konsole CMake package-prefix regression: PASS\n'
