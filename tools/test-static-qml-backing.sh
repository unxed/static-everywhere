#!/usr/bin/env bash
# Regression test for contrib/f4-qt/force-static-qml-backing.cmake.
#
# Three things must hold, and each has already gone wrong or would fail
# silently:
#
#   1. the named target becomes STATIC -- a shared QML plugin cannot
#      register into a static binary, which cost run 2026-08-27/night2;
#   2. every OTHER library is left alone -- a blanket SHARED->STATIC
#      rewrite would break the MODULE libraries Qt creates on purpose,
#      and would do so quietly;
#   3. EVERY generated companion joins the export set exactly once,
#      found by walking the target's interface rather than by name --
#      a static Qt plugin has one and a shared one does not, so exporting
#      the plugin started failing the moment the rewrite worked; and
#      because targets are global while the deferred call is per
#      directory, the naive fix added it twice;
#   4. configure completes at all -- the file is included from every
#      project() scope, and overriding a command twice makes the saved
#      `_add_library` point at the previous override instead of the
#      builtin. The first version of this file recursed infinitely, which
#      only showed up because the probe ran it in a nested project.
set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT

mkdir -p "$PROBE/src/nested"
cat >"$PROBE/src/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.21)
project(outer CXX)
add_subdirectory(nested)
CMAKE
# The rewrite has to happen inside a NESTED project(), because that is
# where ZoinGallery declares the target.
cat >"$PROBE/src/nested/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.21)
project(ZoinGallery CXX)
file(WRITE "${CMAKE_BINARY_DIR}/a.cpp" "int f(){return 0;}\n")
add_library(ZoinGalleryQml SHARED "${CMAKE_BINARY_DIR}/a.cpp")
add_library(SomethingElse SHARED "${CMAKE_BINARY_DIR}/a.cpp")

# A static Qt plugin comes with a <plugin>_init OBJECT library in its
# interface; a shared one does not. Exporting the plugin without it fails
# the generate step, which is what the rewrite above uncovered -- so the
# probe carries that shape too, and the export must complete.
add_library(ZoinGalleryQmlplugin STATIC "${CMAKE_BINARY_DIR}/a.cpp")
add_library(ZoinGalleryQmlplugin_init OBJECT "${CMAKE_BINARY_DIR}/a.cpp")
target_link_libraries(ZoinGalleryQmlplugin INTERFACE ZoinGalleryQmlplugin_init)

# A second companion, on the BACKING target and wrapped in the genex Qt
# uses. Naming _init alone was right for exactly one run; the next
# failure was ZoinGalleryQml_resources_5, so the probe now carries both
# shapes and a companion reachable only through a generator expression.
add_library(ZoinGalleryQml_resources_5 OBJECT "${CMAKE_BINARY_DIR}/a.cpp")
target_link_libraries(ZoinGalleryQml INTERFACE
                      "$<LINK_ONLY:ZoinGalleryQml_resources_5>")

# Exported by the project itself: must NOT be added again, or CMake fails
# with "includes target ... more than once in the export set".
add_library(ZoinGalleryCore STATIC "${CMAKE_BINARY_DIR}/a.cpp")
target_link_libraries(ZoinGalleryQml INTERFACE ZoinGalleryCore)

install(TARGETS ZoinGalleryQml ZoinGalleryQmlplugin ZoinGalleryCore
        EXPORT ZoinGalleryTargets
        ARCHIVE DESTINATION lib LIBRARY DESTINATION lib)
install(EXPORT ZoinGalleryTargets DESTINATION lib/cmake NAMESPACE ZoinGallery::)
get_target_property(_t1 ZoinGalleryQml TYPE)
get_target_property(_t2 SomethingElse TYPE)
message(STATUS "PROBE ZoinGalleryQml=${_t1} SomethingElse=${_t2}")
CMAKE

if ! cmake -S "$PROBE/src" -B "$PROBE/build" -G Ninja \
        -DCMAKE_PROJECT_INCLUDE="$REPO_ROOT/contrib/f4-qt/force-static-qml-backing.cmake" \
        >"$PROBE/configure.log" 2>&1; then
    printf 'configure failed (infinite recursion is the usual cause)\n' >&2
    tail -5 "$PROBE/configure.log" | sed 's/^/  /' >&2
    exit 1
fi

grep -Fq -- 'PROBE ZoinGalleryQml=STATIC_LIBRARY' "$PROBE/configure.log" \
    || { printf 'the QML backing target was not made static\n' >&2; exit 1; }

grep -Fq -- 'SomethingElse=SHARED_LIBRARY' "$PROBE/configure.log" \
    || { printf 'the rewrite widened beyond its named target\n' >&2; exit 1; }

for _companion in ZoinGalleryQmlplugin_init ZoinGalleryQml_resources_5; do
    grep -Fq -- "added companion ${_companion} to the ZoinGalleryTargets export set" \
        "$PROBE/configure.log" \
        || { printf '%s was not added to the export set\n' "$_companion" >&2; exit 1; }
done

printf 'static QML backing: named target rewritten, others untouched: pass\n'
