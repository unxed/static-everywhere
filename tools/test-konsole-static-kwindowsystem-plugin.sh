#!/usr/bin/env bash
# Regression guard for the static-Qt KWindowSystem plugin boundary.
#
# QPluginLoader cannot load a MODULE when Qt is static. The recipe therefore
# has to add KWindowSystem's X11 implementation to KF6WindowSystem itself,
# compile its MOC output as a static plugin, and register that plugin with
# Q_IMPORT_PLUGIN. The upstream MODULE links KF6WindowSystem, so it must stop
# carrying the same objects, or its link fails on duplicate X11Plugin
# symbols (the first CI run of this hook). This configure-only fixture has the
# upstream target shape -- a MODULE in src/platforms/xcb whose sources overlap
# the framework's -- and exercises the real project hook without rebuilding
# the KDE graph.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT

mkdir -p "$PROBE/source/src/platforms/xcb"
cat >"$PROBE/source/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.19)
project(KWindowSystem LANGUAGES CXX)

set(KWINDOWSYSTEM_X11 ON)
add_subdirectory(src)

function(check_static_kwindowsystem_plugin)
    get_target_property(probe_sources KF6WindowSystem SOURCES)
    get_target_property(probe_definitions KF6WindowSystem COMPILE_DEFINITIONS)
    get_target_property(probe_module_sources KF6WindowSystemX11Plugin SOURCES)
    get_target_property(probe_module_links KF6WindowSystemX11Plugin LINK_LIBRARIES)
    file(READ "${CMAKE_CURRENT_SOURCE_DIR}/src/pluginwrapper.cpp" probe_wrapper)
    string(REPLACE ";" "\n" probe_sources "${probe_sources}")
    file(WRITE "${CMAKE_BINARY_DIR}/probe-result.txt"
        "sources=\n${probe_sources}\n"
        "definitions=${probe_definitions}\n"
        "module_sources=${probe_module_sources}\n"
        "module_links=${probe_module_links}\n"
        "wrapper=${probe_wrapper}\n")
endfunction()

cmake_language(DEFER DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    CALL check_static_kwindowsystem_plugin)
CMAKE

cat >"$PROBE/source/src/CMakeLists.txt" <<'CMAKE'
add_library(KF6WindowSystem STATIC pluginwrapper.cpp platforms/xcb/kxutils.cpp)
add_subdirectory(platforms/xcb)
CMAKE

cat >"$PROBE/source/src/platforms/xcb/CMakeLists.txt" <<'CMAKE'
add_library(KF6WindowSystemX11Plugin MODULE)
target_sources(KF6WindowSystemX11Plugin PRIVATE
    kwindoweffects.cpp
    kwindowshadow.cpp
    kwindowsystem.cpp
    kxutils.cpp
    plugin.cpp
)
target_link_libraries(KF6WindowSystemX11Plugin PRIVATE KF6WindowSystem)
CMAKE

cat >"$PROBE/source/src/pluginwrapper.cpp" <<'CPP'
#include <QPluginLoader>
Q_GLOBAL_STATIC(KWindowSystemPluginWrapper, s_pluginWrapper)
CPP
for source in kwindoweffects.cpp kwindowshadow.cpp kwindowsystem.cpp kxutils.cpp plugin.cpp; do
    : >"$PROBE/source/src/platforms/xcb/$source"
done

cmake -S "$PROBE/source" -B "$PROBE/build" -G Ninja \
    -DCMAKE_PROJECT_INCLUDE="$REPO_ROOT/contrib/konsole/project-include.cmake" \
    >"$PROBE/configure.log" 2>&1 || {
    sed -n '1,240p' "$PROBE/configure.log" >&2
    exit 1
}

result="$PROBE/build/probe-result.txt"
[[ -f $result ]] || {
    printf 'static KWindowSystem plugin probe produced no result\n' >&2
    exit 1
}
fail() {
    printf '%s\n' "$1" >&2
    cat "$result" >&2
    exit 1
}
grep -Fq 'QT_STATICPLUGIN' "$result" || fail 'KWindowSystem target has no QT_STATICPLUGIN definition'
for source in kwindoweffects.cpp kwindowshadow.cpp kwindowsystem.cpp plugin.cpp; do
    grep -Fq "src/platforms/xcb/$source" "$result" ||
        fail "KWindowSystem target omitted static X11 plugin source: $source"
done
kxutils_count=$(grep -c 'kxutils\.cpp$' "$result" || true)
[[ $kxutils_count == 1 ]] ||
    fail "a source both targets compile was added to KF6WindowSystem again ($kxutils_count copies)"
grep -Eq '^module_sources=[^;]*static_everywhere_x11plugin_stub\.cpp$' "$result" ||
    fail 'the X11 MODULE still compiles the plugin objects KF6WindowSystem now owns'
grep -Fxq 'module_links=' "$result" ||
    fail 'the X11 MODULE still links KF6WindowSystem (duplicate X11Plugin symbols)'
grep -Fq '#include <QtPlugin>' "$result" || fail 'KWindowSystem wrapper has no QtPlugin include'
grep -Fq 'Q_IMPORT_PLUGIN(X11Plugin)' "$result" || fail 'KWindowSystem wrapper has no static X11 plugin import'

printf 'Konsole static KWindowSystem plugin: PASS (source hook, target contract, no duplicate MODULE)\n'
