#!/usr/bin/env bash
# Regression guard for the static-Qt KWindowSystem plugin boundary.
#
# QPluginLoader cannot load a MODULE when Qt is static. The recipe therefore
# has to add KWindowSystem's X11 implementation to KF6WindowSystem itself,
# compile its MOC output as a static plugin, and register that plugin with
# Q_IMPORT_PLUGIN. This configure-only fixture exercises the real project
# hook and its source-shape checks without rebuilding the KDE graph.
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
    file(READ "${CMAKE_CURRENT_SOURCE_DIR}/src/pluginwrapper.cpp" probe_wrapper)
    file(WRITE "${CMAKE_BINARY_DIR}/probe-result.txt"
        "sources=${probe_sources}\n"
        "definitions=${probe_definitions}\n"
        "wrapper=${probe_wrapper}\n")
endfunction()

cmake_language(DEFER DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    CALL check_static_kwindowsystem_plugin)
CMAKE

cat >"$PROBE/source/src/CMakeLists.txt" <<'CMAKE'
add_library(KF6WindowSystem STATIC pluginwrapper.cpp)
CMAKE

cat >"$PROBE/source/src/pluginwrapper.cpp" <<'CPP'
#include <QPluginLoader>
Q_GLOBAL_STATIC(KWindowSystemPluginWrapper, s_pluginWrapper)
CPP
for source in kwindoweffects.cpp kwindowshadow.cpp kwindowsystem.cpp plugin.cpp; do
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
grep -Fq 'QT_STATICPLUGIN' "$result" || {
    printf 'KWindowSystem target has no QT_STATICPLUGIN definition\n' >&2
    cat "$result" >&2
    exit 1
}
for source in kwindoweffects.cpp kwindowshadow.cpp kwindowsystem.cpp plugin.cpp; do
    grep -Fq "src/platforms/xcb/$source" "$result" || {
        printf 'KWindowSystem target omitted static X11 plugin source: %s\n' "$source" >&2
        cat "$result" >&2
        exit 1
    }
done
grep -Fq '#include <QtPlugin>' "$result" || {
    printf 'KWindowSystem wrapper has no QtPlugin include\n' >&2
    cat "$result" >&2
    exit 1
}
grep -Fq 'Q_IMPORT_PLUGIN(X11Plugin)' "$result" || {
    printf 'KWindowSystem wrapper has no static X11 plugin import\n' >&2
    cat "$result" >&2
    exit 1
}

printf 'Konsole static KWindowSystem plugin: PASS (source hook and target contract)\n'
