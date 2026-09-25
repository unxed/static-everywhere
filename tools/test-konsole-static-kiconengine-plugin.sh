#!/usr/bin/env bash
# Regression guard for the static-Qt KIconEngine plugin boundary.
#
# KIconTheme::initTheme() selects the "KIconEngine" icon theme, which only
# KIconThemes' KIconEnginePlugin provides. Static Qt cannot load that MODULE,
# so without a static registration every themed icon resolves to nothing and
# the compiled-in breeze theme is never drawn. The upstream library already
# compiles kiconengineplugin.cpp; the hook must register it with
# Q_IMPORT_PLUGIN in kicontheme.cpp, build the library with QT_STATICPLUGIN,
# not compile the plugin twice, and leave the MODULE an empty placeholder.
# Configure-only fixture with the upstream target shape.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT

mkdir -p "$PROBE/source/src"
cat >"$PROBE/source/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.19)
project(KIconThemes LANGUAGES CXX)

add_subdirectory(src)

function(check_static_kiconengine_plugin)
    get_target_property(probe_sources KF6IconThemes SOURCES)
    get_target_property(probe_definitions KF6IconThemes COMPILE_DEFINITIONS)
    get_target_property(probe_module_sources KIconEnginePlugin SOURCES)
    get_target_property(probe_module_links KIconEnginePlugin LINK_LIBRARIES)
    file(READ "${CMAKE_CURRENT_SOURCE_DIR}/src/kicontheme.cpp" probe_theme)
    string(REPLACE ";" "\n" probe_sources "${probe_sources}")
    file(WRITE "${CMAKE_BINARY_DIR}/probe-result.txt"
        "sources=\n${probe_sources}\n"
        "definitions=${probe_definitions}\n"
        "module_sources=${probe_module_sources}\n"
        "module_links=${probe_module_links}\n"
        "theme=${probe_theme}\n")
endfunction()

cmake_language(DEFER DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    CALL check_static_kiconengine_plugin)
CMAKE

cat >"$PROBE/source/src/CMakeLists.txt" <<'CMAKE'
add_library(KF6IconThemes STATIC kiconengineplugin.cpp kicontheme.cpp)
add_library(KIconEnginePlugin MODULE kiconengineplugin.cpp)
target_link_libraries(KIconEnginePlugin PRIVATE KF6IconThemes)
CMAKE

cat >"$PROBE/source/src/kiconengineplugin.cpp" <<'CPP'
class KIconEnginePlugin : public QIconEnginePlugin
{
    Q_OBJECT
    Q_PLUGIN_METADATA(IID "org.qt-project.Qt.QIconEngineFactoryInterface" FILE "kiconengineplugin.json")
};
CPP
cat >"$PROBE/source/src/kicontheme.cpp" <<'CPP'
#include "kicontheme.h"

#include "debug.h"
CPP

run_configure() {
    cmake -S "$PROBE/source" -B "$PROBE/build" -G Ninja \
        -DCMAKE_PROJECT_INCLUDE="$REPO_ROOT/contrib/konsole/project-include.cmake" \
        >"$PROBE/configure.log" 2>&1 || {
        sed -n '1,240p' "$PROBE/configure.log" >&2
        exit 1
    }
}
run_configure
# A cached kde-builder checkout is configured again: the edit must not repeat.
run_configure

result="$PROBE/build/probe-result.txt"
[[ -f $result ]] || {
    printf 'static KIconEngine plugin probe produced no result\n' >&2
    exit 1
}
fail() {
    printf '%s\n' "$1" >&2
    cat "$result" >&2
    exit 1
}
grep -Fq 'QT_STATICPLUGIN' "$result" || fail 'KIconThemes target has no QT_STATICPLUGIN definition'
plugin_count=$(grep -c 'kiconengineplugin\.cpp$' "$result" || true)
[[ $plugin_count == 1 ]] ||
    fail "KF6IconThemes compiles kiconengineplugin.cpp $plugin_count times"
grep -Eq '^module_sources=[^;]*static_everywhere_KIconEnginePlugin_stub\.cpp$' "$result" ||
    fail 'the KIconEnginePlugin MODULE still compiles the plugin KF6IconThemes owns'
grep -Fxq 'module_links=' "$result" ||
    fail 'the KIconEnginePlugin MODULE still links KF6IconThemes (duplicate plugin symbols)'
grep -Fq '#include <QtPlugin>' "$result" || fail 'kicontheme.cpp has no QtPlugin include'
import_count=$(grep -c '^Q_IMPORT_PLUGIN(KIconEnginePlugin)$' "$result" || true)
[[ $import_count == 1 ]] ||
    fail "kicontheme.cpp imports KIconEnginePlugin $import_count times"

printf 'Konsole static KIconEngine plugin: PASS (source hook, target contract, idempotent, no duplicate MODULE)\n'
