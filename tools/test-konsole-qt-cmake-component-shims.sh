#!/usr/bin/env bash
# Regression test for Conan Qt's aggregate CMake config and KDE's component
# style find_package(Qt6<Module>) calls.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
PROBE=$(mktemp -d /tmp/static-everywhere-konsole-qt-components.XXXXXX)
trap 'rm -rf "$PROBE"' EXIT

mkdir -p "$PROBE/generators" "$PROBE/source"
cat >"$PROBE/generators/Qt6Config.cmake" <<'CMAKE'
set(Qt6_FOUND TRUE)
set(Qt6_VERSION_STRING "6.11.1")
add_library(Qt6::Core INTERFACE IMPORTED)
add_library(Qt6::Widgets INTERFACE IMPORTED)
CMAKE
cat >"$PROBE/generators/Qt6ConfigVersion.cmake" <<'CMAKE'
set(PACKAGE_VERSION "6.11.1")
if(PACKAGE_FIND_VERSION VERSION_LESS_EQUAL PACKAGE_VERSION)
    set(PACKAGE_VERSION_COMPATIBLE TRUE)
endif()
if(PACKAGE_FIND_VERSION VERSION_EQUAL PACKAGE_VERSION)
    set(PACKAGE_VERSION_EXACT TRUE)
endif()
CMAKE

PYTHONPATH="$REPO_ROOT/contrib/konsole/qt-host" \
    python3 - "$PROBE/generators" <<'PY'
import pathlib
import sys

from qt_cmake_components import component_config, component_version_config

destination = pathlib.Path(sys.argv[1])
for module in ("Core", "Widgets"):
    (destination / f"Qt6{module}Config.cmake").write_text(
        component_config(module), encoding="utf-8"
    )
    (destination / f"Qt6{module}ConfigVersion.cmake").write_text(
        component_version_config(), encoding="utf-8"
    )
PY

cat >"$PROBE/source/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.21)
project(konsole_qt_component_probe CXX)
find_package(Qt6Core 6.11.1 CONFIG REQUIRED)
find_package(Qt6Widgets CONFIG REQUIRED)
if(NOT TARGET Qt6::Core OR NOT TARGET Qt6::Widgets)
    message(FATAL_ERROR "Qt6 component adapters did not expose aggregate targets")
endif()
if(NOT Qt6Core_VERSION VERSION_EQUAL "6.11.1")
    message(FATAL_ERROR "Qt6Core version was not propagated")
endif()
CMAKE

cmake -S "$PROBE/source" -B "$PROBE/build" -G Ninja \
    -DCMAKE_PREFIX_PATH="$PROBE/generators"
printf 'Konsole Qt component-config regression: PASS\n'
