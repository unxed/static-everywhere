#!/usr/bin/env bash
# Regression test for Conan CONFIG adapters serving legacy variable-based
# upstream consumers.
set -euo pipefail


SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
PROBE=$(mktemp -d /tmp/static-everywhere-konsole-find-mode.XXXXXX)
trap 'rm -rf "$PROBE"' EXIT


mkdir -p "$PROBE/source" "$PROBE/config" "$PROBE/probe-include"
# The adapter now resolves the header itself, so the fixture has to
# be a directory that actually contains one.
printf '#pragma once\n' >"$PROBE/probe-include/probe.h"
cat >"$PROBE/source/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.25)
project(find_mode_probe LANGUAGES NONE)

find_package(LEGACY_PROBE REQUIRED)
if(NOT LEGACY_PROBE_FOUND)
    message(FATAL_ERROR "the generated CONFIG adapter did not find the target")
endif()
if(NOT EXISTS "${LEGACY_PROBE_INCLUDE_DIRS}/probe.h")
    message(FATAL_ERROR
        "the CONFIG adapter published ${LEGACY_PROBE_INCLUDE_DIRS}, which does "
        "not contain the header a consumer would include")
endif()
if(NOT LEGACY_PROBE_LIBRARIES STREQUAL "legacy::legacy")
    message(FATAL_ERROR "the CONFIG adapter did not publish the target")
endif()
if(NOT PKG_LEGACY_PROBE_VERSION STREQUAL "9.1")
    message(FATAL_ERROR "the CONFIG adapter did not publish the package version")
endif()
CMAKE
cat >"$PROBE/config/legacy_probe-config.cmake" <<'CMAKE'
add_library(legacy::legacy INTERFACE IMPORTED)
set_property(TARGET legacy::legacy PROPERTY INTERFACE_INCLUDE_DIRECTORIES "@PROBE_INCLUDE@")
set(legacy_probe_FOUND TRUE)
CMAKE
sed -i "s|@PROBE_INCLUDE@|$PROBE/probe-include|" \
    "$PROBE/config/legacy_probe-config.cmake"

python3 - "$REPO_ROOT/contrib/konsole/qt-host" "$PROBE/config/LEGACY_PROBEConfig.cmake" <<'PY'
import pathlib
import sys

sys.path.insert(0, sys.argv[1])
from qt_cmake_components import legacy_package_config

pathlib.Path(sys.argv[2]).write_text(
    legacy_package_config("legacy_probe", "legacy::legacy", "LEGACY_PROBE",
                          "9.1", header="probe.h"),
    encoding="utf-8",
)
PY

# Simulate the recipe's global Conan preference. The generated CONFIG adapter
# must bridge the target to the variables an upstream Find module expects.
cmake -S "$PROBE/source" -B "$PROBE/build" -G Ninja \
    -DCMAKE_PROJECT_INCLUDE="$REPO_ROOT/contrib/konsole/project-include.cmake" \
    -DCMAKE_PREFIX_PATH="$PROBE/config" \
    -DCMAKE_FIND_PACKAGE_PREFER_CONFIG=ON
printf 'Konsole CMake legacy CONFIG adapter regression: PASS\n'
