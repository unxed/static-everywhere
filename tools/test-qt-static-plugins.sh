#!/usr/bin/env bash
# Regression test for the CMAKE_PROJECT_INCLUDE hooks, entered through
# contrib/f4-qt/project-include.cmake.
#
# The failure it guards against is not a link error but a runtime one --
# every GUI test aborting with "Could not find the Qt platform plugin
# offscreen" before running a line of its own code. That is invisible to
# any check that only builds, so this test asserts the two things that
# actually make the difference:
#
#   1. the generated Q_IMPORT_PLUGIN translation unit is compiled into
#      EVERY consumer of Qt6::Gui, not just the application -- the same
#      mistake the Qt6::OpenGL hook made in its first version;
#   2. the plugin archives reach the link line.
#
# Qt is mocked rather than built: the point under test is the CMake
# plumbing, and a real static Qt takes two hours. The mock supplies a
# QtPlugin header so the generated file genuinely compiles, and a stand-in
# libqoffscreen.a in a package layout matching Conan's, so find_library
# exercises the real code path.
set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT

mkdir -p "$PROBE/src/nested" "$PROBE/fakeqt/plugins/platforms" \
         "$PROBE/fakeqt/include" "$PROBE/fakeqt/libexec" \
         "$PROBE/fakeqt/qml/QtQuick" "$PROBE/src/qml"

# A stand-in qmlimportscanner emitting the real output shape, including a
# header-only module with no plugin (which must be skipped, not fatal).
cat >"$PROBE/fakeqt/libexec/qmlimportscanner" <<SCANNER
#!/bin/sh
cat <<'JSON'
[
  {
    "classname": "QtQuick2Plugin",
    "name": "QtQuick",
    "path": "PLUGINDIR",
    "plugin": "qtquick2plugin",
    "type": "module"
  },
  {
    "name": "QtQuick.Layouts.headeronly",
    "type": "module"
  },
  {
    "classname": "QtQuick2Plugin",
    "name": "QtQuick",
    "path": "PLUGINDIR",
    "plugin": "qtquick2plugin",
    "type": "module"
  },
  {
    "classname": "ZoinGalleryQmlPlugin",
    "name": "ZoinGallery",
    "path": "TREEDIR",
    "plugin": "zoingalleryqmlplugin",
    "type": "module"
  }
]
JSON
SCANNER
chmod +x "$PROBE/fakeqt/libexec/qmlimportscanner"
sed -i "s|PLUGINDIR|$PROBE/fakeqt/qml/QtQuick|; s|TREEDIR|$PROBE/src|" \
    "$PROBE/fakeqt/libexec/qmlimportscanner"
printf 'int se_plugin_impl_QtQuick2Plugin(void){return 0;}\n' >"$PROBE/qq.c"
cc -c "$PROBE/qq.c" -o "$PROBE/qq.o"
ar rcs "$PROBE/fakeqt/qml/QtQuick/libqtquick2plugin.a" "$PROBE/qq.o"
printf 'import QtQuick\n' >"$PROBE/src/qml/Main.qml"

# A QtPlugin header just real enough that Q_IMPORT_PLUGIN compiles and
# leaves a symbol behind we can check for.
# The real Q_IMPORT_PLUGIN references the plugin's registration symbol,
# which lives in the plugin archive -- so a plugin imported but not linked
# is an undefined symbol. The mock reproduces that dependency; a first
# version merely defined a symbol locally, and its negative control for
# "archive dropped from the link line" passed a broken hook because
# nothing referenced the archive at all.
cat >"$PROBE/fakeqt/include/QtPlugin" <<'HDR'
#pragma once
#define Q_IMPORT_PLUGIN(NAME)                                   \
    extern "C" int se_plugin_impl_##NAME(void);                 \
    extern "C" int se_imported_##NAME(void)                     \
    { return se_plugin_impl_##NAME(); }
HDR

cat >"$PROBE/src/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.21)
project(plugin_import_regression CXX)

# Nested project first: CMAKE_PROJECT_INCLUDE fires after it too, at a
# point where the Qt targets do not exist yet. Same ordering that caught
# a missing top-level guard in the Qt6::OpenGL hook.
add_subdirectory(nested)

set(qt_PACKAGE_FOLDER_RELEASE "${FAKE_QT}")

# Static Qt: Core is a STATIC IMPORTED target, which is how the hook tells
# a static build from a shared one.
file(WRITE "${CMAKE_BINARY_DIR}/core.cpp" "int qt_core(){return 0;}\n")
add_library(qt6core_impl STATIC "${CMAKE_BINARY_DIR}/core.cpp")
add_library(Qt6::Core STATIC IMPORTED)
set_property(TARGET Qt6::Core PROPERTY
             IMPORTED_LOCATION "$<TARGET_FILE:qt6core_impl>")

# Qt6::Quick and Qt6::OpenGL exist so the sibling hook in the aggregator
# is satisfied too -- this way one probe exercises the real entry point,
# contrib/f4-qt/project-include.cmake, rather than a hook in isolation.
file(WRITE "${CMAKE_BINARY_DIR}/gl.cpp" "int qt_opengl(){return 0;}\n")
add_library(qt6opengl STATIC "${CMAKE_BINARY_DIR}/gl.cpp")
add_library(Qt6::OpenGL INTERFACE IMPORTED)
set_property(TARGET Qt6::OpenGL PROPERTY INTERFACE_LINK_LIBRARIES qt6opengl)
add_library(Qt6::Quick INTERFACE IMPORTED)

add_library(Qt6::Gui INTERFACE IMPORTED)
set_property(TARGET Qt6::Gui PROPERTY
             INTERFACE_INCLUDE_DIRECTORIES "${FAKE_QT}/include")

file(WRITE "${CMAKE_BINARY_DIR}/xcb.cpp"
"extern \"C\" int se_plugin_impl_QXcbIntegrationPlugin(){return 0;}
extern \"C\" int se_plugin_impl_QSvgPlugin(){return 0;}
extern \"C\" int se_plugin_impl_QSvgIconPlugin(){return 0;}
extern \"C\" int se_plugin_impl_QGifPlugin(){return 0;}
extern \"C\" int se_plugin_impl_QIcoPlugin(){return 0;}\n")
add_library(qt6xcb STATIC "${CMAKE_BINARY_DIR}/xcb.cpp")
add_library(Qt6::QXcbIntegrationPlugin INTERFACE IMPORTED)
set_property(TARGET Qt6::QXcbIntegrationPlugin PROPERTY
             INTERFACE_LINK_LIBRARIES qt6xcb)
foreach(_p QSvgPlugin QSvgIconPlugin QGifPlugin QIcoPlugin)
  add_library(Qt6::${_p} INTERFACE IMPORTED)
  set_property(TARGET Qt6::${_p} PROPERTY INTERFACE_LINK_LIBRARIES qt6xcb)
endforeach()

# A static library between Qt6::Gui and the executables, linked by both --
# the shape ZoinGalleryCore has in the real tree. The run this test failed
# to prevent died on a ninja dependency cycle precisely because the
# generated import unit was compiled into this kind of target; and even
# without the cycle, an executable and a pulled archive member both
# carrying the registration object is a duplicate definition.
file(WRITE "${CMAKE_BINARY_DIR}/core.cxx" "int zoin_core(){return 0;}\n")
add_library(ZoinCore STATIC "${CMAKE_BINARY_DIR}/core.cxx")
target_link_libraries(ZoinCore PRIVATE Qt6::Gui)

file(WRITE "${CMAKE_BINARY_DIR}/m.cpp" "int main(){return 0;}\n")
add_executable(f4-qt-host "${CMAKE_BINARY_DIR}/m.cpp")
target_link_libraries(f4-qt-host PRIVATE Qt6::Gui ZoinCore)

# The consumer that matters: in the real failure it was f4's tests, not
# the app, that could not start.
add_executable(F4SomeTest "${CMAKE_BINARY_DIR}/m.cpp")
target_link_libraries(F4SomeTest PRIVATE Qt6::Gui ZoinCore)
CMAKE
printf '%s\n' \
    'cmake_minimum_required(VERSION 3.21)' \
    'project(nested_gallery NONE)' \
    >"$PROBE/src/nested/CMakeLists.txt"

# A stand-in for the archive Conan ships but declares no component for.
printf 'int se_plugin_impl_QOffscreenIntegrationPlugin(void){return 0;}\n' >"$PROBE/off.c"
cc -c "$PROBE/off.c" -o "$PROBE/off.o"
ar rcs "$PROBE/fakeqt/plugins/platforms/libqoffscreen.a" "$PROBE/off.o"

fail() {
    printf '%s\n' "$1" >&2
    sed 's/^/  /' "$2" >&2
    exit 1
}

cmake -S "$PROBE/src" -B "$PROBE/build" -G Ninja \
    -DFAKE_QT="$PROBE/fakeqt" \
    -DCMAKE_PROJECT_INCLUDE="$REPO_ROOT/contrib/f4-qt/project-include.cmake" \
    >"$PROBE/configure.log" 2>&1 \
    || fail 'configure failed' "$PROBE/configure.log"

grep -Fq -- "static-everywhere: imported static Qt plugins into Qt6::Gui's" \
    "$PROBE/configure.log" \
    || fail 'the plugin hook did not run in the top-level scope' \
            "$PROBE/configure.log"

# The aggregator must run BOTH hooks; passing a list to CMAKE_PROJECT_INCLUDE
# on an older CMake silently drops the extra files, which is exactly the
# failure mode the single entry point exists to remove.
grep -Fq -- "static-everywhere: added Qt6::OpenGL to Qt6::Quick's link interface" \
    "$PROBE/configure.log" \
    || fail 'the aggregator did not run the Qt6::OpenGL hook' \
            "$PROBE/configure.log"

cmake --build "$PROBE/build" >"$PROBE/build.log" 2>&1 \
    || fail 'the probe failed to build with the plugin imports' "$PROBE/build.log"

# Both plugins imported, and imported into BOTH consumers. Checking the
# symbol in the produced binaries rather than the CMake property is
# deliberate: the property being set is not the same claim as the
# translation unit being compiled into each executable.
for exe in f4-qt-host F4SomeTest; do
    for plugin in QXcbIntegrationPlugin QOffscreenIntegrationPlugin \
                  QSvgPlugin QSvgIconPlugin QGifPlugin QIcoPlugin \
                  QtQuick2Plugin; do
        nm -A "$PROBE/build/$exe" 2>/dev/null \
            | grep -q "se_imported_${plugin}" \
            || fail "${exe} does not carry the import for ${plugin}" \
                    "$PROBE/build.log"
    done
done

# The import unit must NOT be compiled into static libraries. That is the
# real tree's failure mode, and the reason the hook restricts its
# INTERFACE_SOURCES entry to EXECUTABLE targets the way Qt itself does.
if nm "$PROBE/build/libZoinCore.a" 2>/dev/null | grep -q 'se_imported_'; then
    fail 'the import unit was compiled into a static library' "$PROBE/build.log"
fi

printf 'static Qt plugin import: both plugins in both consumers: pass\n'
