#!/usr/bin/env bash
# Regression test for Conan CONFIG packages shadowing upstream MODULE finders.
set -euo pipefail


SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
PROBE=$(mktemp -d /tmp/static-everywhere-konsole-find-mode.XXXXXX)
trap 'rm -rf "$PROBE"' EXIT


mkdir -p "$PROBE/source" "$PROBE/module" "$PROBE/config"
cat >"$PROBE/source/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.25)
project(find_mode_probe LANGUAGES NONE)

find_package(LEGACY_PROBE REQUIRED)
if(NOT LEGACY_PROBE_FROM_MODULE)
    message(FATAL_ERROR "the Conan CONFIG package shadowed the upstream MODULE finder")
endif()
if(NOT LEGACY_PROBE_INCLUDE_DIRS STREQUAL "module-include")
    message(FATAL_ERROR "the MODULE finder did not publish its legacy variables")
endif()
CMAKE
cat >"$PROBE/module/FindLEGACY_PROBE.cmake" <<'CMAKE'
set(LEGACY_PROBE_FOUND TRUE)
set(LEGACY_PROBE_FROM_MODULE TRUE)
set(LEGACY_PROBE_INCLUDE_DIRS module-include)
CMAKE
cat >"$PROBE/config/LEGACY_PROBEConfig.cmake" <<'CMAKE'
set(LEGACY_PROBE_FOUND TRUE)
set(LEGACY_PROBE_FROM_CONFIG TRUE)
CMAKE

# Simulate the recipe's global Conan preference. The project hook must retain
# MODULE-first lookup so an upstream finder can publish its companion vars.
cmake -S "$PROBE/source" -B "$PROBE/build" -G Ninja \
    -DCMAKE_PROJECT_INCLUDE="$REPO_ROOT/contrib/konsole/project-include.cmake" \
    -DCMAKE_MODULE_PATH="$PROBE/module" \
    -DCMAKE_PREFIX_PATH="$PROBE/config" \
    -DCMAKE_FIND_PACKAGE_PREFER_CONFIG=ON
printf 'Konsole CMake MODULE/CONFIG precedence regression: PASS\n'
