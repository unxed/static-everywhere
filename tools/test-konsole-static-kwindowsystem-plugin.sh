#!/usr/bin/env bash
# CI-only regression: apply to the pinned source, execute its actual backend
# CMakeLists, build/install the static graph and link an external consumer.
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT
read -r _ ref sha url < <(awk '$1 == "kwindowsystem"' "$REPO_ROOT/contrib/konsole/deps.lock")
git clone --quiet --depth 1 --branch "$ref" "$url" "$PROBE/upstream"
[[ $(git -C "$PROBE/upstream" rev-parse HEAD) == "$sha" ]]
cat >"$PROBE/patch.cmake" <<CMAKE
include("$REPO_ROOT/contrib/konsole/patch-kwindowsystem.cmake")
se_patch_kwindowsystem("$PROBE/upstream")
se_patch_kwindowsystem("$PROBE/upstream")
CMAKE
cmake -P "$PROBE/patch.cmake"
grep -Fq 'Q_IMPORT_PLUGIN(X11Plugin)' "$PROBE/upstream/src/pluginwrapper.cpp"

mkdir -p "$PROBE/source/backend"
cp "$PROBE/upstream/src/platforms/xcb/CMakeLists.txt" "$PROBE/source/backend/"
cat >"$PROBE/source/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.19)
project(StaticBackendBoundary CXX)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(KDE_INSTALL_PLUGINDIR lib/plugins)
set(KDE_INSTALL_INCLUDEDIR_KF include)
foreach(dep XCB::XCB XCB::RES Qt6::GuiPrivate)
    add_library(${dep} INTERFACE IMPORTED)
endforeach()
function(ecm_generate_headers)
endfunction()
add_library(KF6WindowSystem wrapper.cpp backend/kxutils.cpp)
add_subdirectory(backend)
if(NOT BUILD_SHARED_LIBS)
    if(TARGET KF6WindowSystemX11Plugin)
        message(FATAL_ERROR "static backend also declares a MODULE target")
    endif()
    get_target_property(sources KF6WindowSystem SOURCES)
    list(FILTER sources INCLUDE REGEX "kxutils[.]cpp$")
    list(LENGTH sources helpers)
    if(NOT helpers EQUAL 1)
        message(FATAL_ERROR "backend helper must have exactly one owner")
    endif()
elseif(NOT TARGET KF6WindowSystemX11Plugin)
    message(FATAL_ERROR "shared build lost its MODULE")
endif()
install(TARGETS KF6WindowSystem EXPORT Boundary ARCHIVE DESTINATION lib)
install(EXPORT Boundary DESTINATION lib/cmake/Boundary FILE BoundaryConfig.cmake)
CMAKE
cat >"$PROBE/source/wrapper.cpp" <<'CPP'
#ifdef KWINDOWSYSTEM_STATIC_X11
extern int qt_static_plugin_X11Plugin();
int framework() { return qt_static_plugin_X11Plugin(); }
#else
int framework() { return 0; }
#endif
CPP
cat >"$PROBE/source/backend/plugin.cpp" <<'CPP'
#ifndef QT_STATICPLUGIN
#error backend is not compiled as a static plugin
#endif
extern int backend_helper();
int qt_static_plugin_X11Plugin() { return backend_helper(); }
CPP
printf 'int backend_helper() { return 42; }\n' >"$PROBE/source/backend/kxutils.cpp"
for source in kwindoweffects.cpp kwindowshadow.cpp kwindowsystem.cpp fixx11h.h; do
    : >"$PROBE/source/backend/$source"
done
cmake -S "$PROBE/source" -B "$PROBE/build" -G Ninja \
    -DBUILD_SHARED_LIBS=OFF -DCMAKE_INSTALL_PREFIX="$PROBE/install"
cmake --build "$PROBE/build"
cmake --install "$PROBE/build"
if find "$PROBE/install" -name '*WindowSystemX11Plugin*' | grep .; then
    printf 'static install contains a redundant plugin\n' >&2
    exit 1
fi
mkdir "$PROBE/consumer"
cat >"$PROBE/consumer/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.19)
project(InstalledConsumer CXX)
find_package(Boundary CONFIG REQUIRED)
add_executable(consumer main.cpp)
target_link_libraries(consumer PRIVATE KF6WindowSystem)
CMAKE
printf 'extern int framework(); int main() { return framework() == 42 ? 0 : 1; }\n' >"$PROBE/consumer/main.cpp"
cmake -S "$PROBE/consumer" -B "$PROBE/consumer-build" -G Ninja \
    -DCMAKE_PREFIX_PATH="$PROBE/install"
cmake --build "$PROBE/consumer-build"
"$PROBE/consumer-build/consumer"
# Shared configuration still owns its backend and preserves header installs.
cmake -S "$PROBE/source" -B "$PROBE/shared" -G Ninja -DBUILD_SHARED_LIBS=ON
printf 'KWindowSystem boundary: PASS (pinned patch, idempotence, unique ownership, installed static closure)\n'
