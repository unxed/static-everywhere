#!/usr/bin/env bash
# Regression guard for packages the recipe disables with
# CMAKE_DISABLE_FIND_PACKAGE_<P>=ON.
#
# find_package() of a disabled package leaves <P>_FOUND undefined, and a
# package config template then substitutes an empty @<P>_FOUND@. kcoreaddons
# writes `if (@UDev_FOUND@ OR @LibMount_FOUND@)` for static builds; with UDev
# disabled that became `if ( OR 1)` and kcrash failed to configure. This
# fixture configures the same template shape through the real project hook
# and loads the result the way a consumer's find_package() would.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT

mkdir -p "$PROBE/source"
cat >"$PROBE/source/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.19)
project(KCoreAddons LANGUAGES NONE)

find_package(UDev)
set(LibMount_FOUND TRUE)
configure_file(ProbeConfig.cmake.in "${CMAKE_BINARY_DIR}/ProbeConfig.cmake" @ONLY)
include("${CMAKE_BINARY_DIR}/ProbeConfig.cmake")
if(NOT PROBE_BRANCH STREQUAL "taken")
    message(FATAL_ERROR "the configured template did not evaluate its condition")
endif()
CMAKE
cat >"$PROBE/source/ProbeConfig.cmake.in" <<'CMAKE'
if (@UDev_FOUND@ OR @LibMount_FOUND@)
    set(PROBE_BRANCH "taken")
endif()
if (@UDev_FOUND@)
    message(FATAL_ERROR "a disabled package was reported as found")
endif()
CMAKE

cmake -S "$PROBE/source" -B "$PROBE/build" \
    -DCMAKE_DISABLE_FIND_PACKAGE_UDev=ON \
    -DCMAKE_PROJECT_INCLUDE="$REPO_ROOT/contrib/konsole/project-include.cmake" \
    >"$PROBE/configure.log" 2>&1 || {
    sed -n '1,240p' "$PROBE/configure.log" >&2
    exit 1
}

printf 'Konsole disabled packages: PASS (a disabled package configures as not found)\n'
