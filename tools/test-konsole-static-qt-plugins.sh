#!/usr/bin/env bash
# Regression test for Konsole's static Qt plugin import hook.
#
# It covers two configure-time failure classes: generated source files that
# appear only during CMake generation, and Conan build-target names leaking
# from QMAKE_PRL_LIBS into a consumer's link interface.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT

mkdir -p "$PROBE/src" "$PROBE/fakeqt/include" \
    "$PROBE/fakeqt/plugins/platforms" \
    "$PROBE/fakeqt/plugins/xcbglintegrations"

cat >"$PROBE/fakeqt/include/QtPlugin" <<'HEADER'
#pragma once
#define Q_IMPORT_PLUGIN(NAME) int static_everywhere_import_##NAME(void) { return 0; }
HEADER

make_plugin() {
    local directory=$1
    local name=$2
    local class_name=$3
    local source="$PROBE/${name}.cpp"
    local object="$PROBE/${name}.o"
    local archive="$PROBE/fakeqt/plugins/${directory}/lib${name}.a"

    printf 'struct QStaticPluginShim { int value; }; QStaticPluginShim qt_static_plugin_%s() { return {0}; }\n' \
        "$class_name" >"$source"
    c++ -c "$source" -o "$object"
    ar rcs "$archive" "$object"
    printf 'QMAKE_PRL_LIBS = -lCONAN_LIB::libpng_png_RELEASE -lm\n' \
        >"${archive%.a}.prl"
}

make_plugin platforms qxcb QXcbIntegrationPlugin
make_plugin xcbglintegrations qxcb-glx-integration QXcbGlIntegrationPlugin
make_plugin xcbglintegrations qxcb-egl-integration QXcbEglIntegrationPlugin

cat >"$PROBE/src/CMakeLists.txt" <<CMAKE
cmake_minimum_required(VERSION 3.21)
project(konsole_static_qt_plugins_probe CXX)

set(qt_PACKAGE_FOLDER_RELEASE "$PROBE/fakeqt")
add_library(Qt6::Core STATIC IMPORTED)
add_library(Qt6::Gui INTERFACE IMPORTED)
set_property(TARGET Qt6::Gui PROPERTY INTERFACE_INCLUDE_DIRECTORIES
    "\$<BUILD_INTERFACE:$PROBE/fakeqt/include>")

include("$REPO_ROOT/contrib/konsole/import-static-qt-plugins.cmake")

# Make the old directory-local TARGET exception observable. The target name
# is still not a valid link item once exported as -lCONAN_LIB::... .
add_library(CONAN_LIB::libpng_png_RELEASE INTERFACE IMPORTED)

function(check_konsole_static_qt_plugins)
    set(generated "\${CMAKE_BINARY_DIR}/static_everywhere_konsole_qt_plugins.cpp")
    if(NOT EXISTS "\${generated}")
        message(FATAL_ERROR "Konsole plugin registration source was not configured")
    endif()
    file(READ "\${generated}" imports)
    foreach(plugin QXcbIntegrationPlugin QXcbGlIntegrationPlugin QXcbEglIntegrationPlugin)
        string(FIND "\${imports}" "Q_IMPORT_PLUGIN(\${plugin})" plugin_offset)
        if(plugin_offset EQUAL -1)
            message(FATAL_ERROR "missing Q_IMPORT_PLUGIN(\${plugin}) in: \${imports}")
        endif()
    endforeach()
    string(REGEX MATCHALL "Q_IMPORT_PLUGIN\\([^)]*\\)" plugin_imports "\${imports}")
    list(LENGTH plugin_imports import_count)
    if(NOT import_count EQUAL 3)
        message(FATAL_ERROR "expected exactly three Q_IMPORT_PLUGIN calls, got \${import_count}")
    endif()

    get_target_property(links Qt6::Gui INTERFACE_LINK_LIBRARIES)
    if("\${links}" MATCHES "::" OR "\${links}" MATCHES "CONAN_LIB")
        message(FATAL_ERROR "Conan target leaked into Qt6::Gui: \${links}")
    endif()
endfunction()

cmake_language(DEFER DIRECTORY "\${CMAKE_CURRENT_SOURCE_DIR}"
    CALL check_konsole_static_qt_plugins)
CMAKE

cmake -S "$PROBE/src" -B "$PROBE/build" -G Ninja \
    >"$PROBE/configure.log" 2>&1 || {
    sed -n '1,240p' "$PROBE/configure.log" >&2
    exit 1
}

printf 'PASS: Konsole static Qt plugin hook configures sources and filters Conan .prl targets\n'
