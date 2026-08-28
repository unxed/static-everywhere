#!/usr/bin/env bash
# Regression test for the optional-GL hook in a CXX-only project.
#
# f4's Qt host enables CXX, not C. The hook adds generated and compatibility
# sources through Qt6::Gui's INTERFACE_SOURCES, so those sources must stay in
# CMake's C++ language context. If they are left as .c sources, CMake tries to
# discover C after project() has already configured the project and fails at
# generate time with the misleading:
#
#   Missing variable is: CMAKE_C_COMPILE_OBJECT
#
# This deliberately configures and builds a tiny project, without Qt or a
# full f4 build. The real libGL is used only to give the generator its symbol
# list; the resulting executable does not link against libGL.
set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT

if ! command -v cmake >/dev/null 2>&1; then
    printf 'cmake not on PATH; skipping\n'
    exit 0
fi

LIBGL=''
for candidate in /usr/lib/x86_64-linux-gnu/libGL.so.1 /usr/lib64/libGL.so.1 /usr/lib/libGL.so.1; do
    if [ -e "$candidate" ]; then
        LIBGL="$candidate"
        break
    fi
done
if [ -z "$LIBGL" ]; then
    printf 'libGL not installed; skipping\n'
    exit 0
fi

mkdir -p "$PROBE/src"
cat >"$PROBE/src/CMakeLists.txt" <<CMAKE
cmake_minimum_required(VERSION 3.21)
project(optional_gl_cxx_only CXX)

add_library(Qt6::Gui INTERFACE IMPORTED)
set(_SE_REPO_ROOT "$REPO_ROOT")
include("$REPO_ROOT/contrib/f4-qt/optional-gl.cmake")

# The optional-GL hook is deferred because Qt6::Gui's final shape is not
# available at include time. Check the source language in a second deferred
# callback, after the hook has attached its sources. This catches the bug on
# older CMake versions too; CMake 3.31 turns the same missing property into
# the real build failure reported by CI.
function(_check_optional_gl_source_languages)
  foreach(source
      "\${CMAKE_BINARY_DIR}/static_everywhere_gl_forwarder.c"
      "$REPO_ROOT/contrib/f4-qt/compat/render-backend-fallback.c")
    get_source_file_property(language "\${source}" LANGUAGE)
    if(NOT language STREQUAL "CXX")
      message(FATAL_ERROR
        "optional-GL source is not forced into CXX: \${source} -> \${language}")
    endif()
  endforeach()
endfunction()
cmake_language(DEFER DIRECTORY "\${CMAKE_CURRENT_SOURCE_DIR}"
               CALL _check_optional_gl_source_languages)

add_executable(optional-gl-probe main.cpp)
target_link_libraries(optional-gl-probe PRIVATE Qt6::Gui \${CMAKE_DL_LIBS})
CMAKE
printf '%s\n' 'int main(void) { return 0; }' >"$PROBE/src/main.cpp"

cmake -S "$PROBE/src" -B "$PROBE/build" -G Ninja \
    >"$PROBE/configure.log" 2>&1 \
    || { sed 's/^/  /' "$PROBE/configure.log" >&2; exit 1; }
cmake --build "$PROBE/build" \
    >"$PROBE/build.log" 2>&1 \
    || { sed 's/^/  /' "$PROBE/build.log" >&2; exit 1; }

printf 'optional GL hook: CXX-only configure and build: pass\n'
