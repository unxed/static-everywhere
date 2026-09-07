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

add_library(OpenGL::GL UNKNOWN IMPORTED)
set_target_properties(OpenGL::GL PROPERTIES
  IMPORTED_LOCATION "$LIBGL")
set_property(TARGET Qt6::Gui PROPERTY INTERFACE_LINK_LIBRARIES OpenGL::GL)

add_executable(optional-gl-probe main.cpp)
target_link_libraries(optional-gl-probe PRIVATE Qt6::Gui)
add_library(optional-gl-shared SHARED shared.cpp)
target_link_libraries(optional-gl-shared PRIVATE Qt6::Gui)
target_link_options(optional-gl-shared PRIVATE -Wl,--no-as-needed)
add_library(optional-gl-module MODULE module.cpp)
target_link_libraries(optional-gl-module PRIVATE Qt6::Gui)
target_link_options(optional-gl-module PRIVATE -Wl,--no-as-needed)
CMAKE
printf '%s\n' 'int main(void) { return 0; }' >"$PROBE/src/main.cpp"
printf '%s\n' 'int optional_gl_shared(void) { return 0; }' >"$PROBE/src/shared.cpp"
printf '%s\n' 'int optional_gl_module(void) { return 0; }' >"$PROBE/src/module.cpp"

cmake -S "$PROBE/src" -B "$PROBE/build" -G Ninja \
    >"$PROBE/configure.log" 2>&1 \
    || { sed 's/^/  /' "$PROBE/configure.log" >&2; exit 1; }
cmake --build "$PROBE/build" \
    >"$PROBE/build.log" 2>&1 \
    || { sed 's/^/  /' "$PROBE/build.log" >&2; exit 1; }

loadable_count=0
while IFS= read -r loadable; do
  [ -n "$loadable" ] || continue
  loadable_count=$((loadable_count + 1))
  needed=$(readelf -d "$loadable" 2>/dev/null \
    | grep -oE '\[lib[^]]*\]' | tr -d '[]' | tr '\n' ' ')
  case "$needed" in
    *libGL*)
      printf 'loadable optional-GL consumer still depends on libGL: %s -> %s\n' \
        "$loadable" "$needed" >&2
      exit 1
      ;;
  esac
  { nm -D --defined-only "$loadable" || true; } | grep -Eq '[[:space:]]glColor4f$' || {
    printf 'loadable optional-GL consumer lacks the generated forwarder: %s\n' \
      "$loadable" >&2
    exit 1
  }
done < <(find "$PROBE/build" -type f \
  \( -name 'liboptional-gl-shared.so' -o -name 'liboptional-gl-module.so' \) \
  -print | sort)
[ "$loadable_count" -eq 2 ] || {
  printf 'expected both shared and MODULE optional-GL consumers, got %s\n' \
    "$loadable_count" >&2
  exit 1
}

printf 'optional GL hook: CXX-only configure and build: pass\n'
