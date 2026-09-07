#!/usr/bin/env bash
# Regression test for target-level runtime RPATH configuration.
# It builds three tiny loadable target kinds because the real Konsole tree
# uses all three: executable, shared library and MODULE plugin.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT

mkdir -p "$PROBE/source"
cat >"$PROBE/source/probe.c" <<'C'
int probe_value(void) { return 0; }
C
cat >"$PROBE/source/main.c" <<'C'
extern int probe_value(void);
int main(void) { return probe_value(); }
C
cat >"$PROBE/source/CMakeLists.txt" <<CMAKE
cmake_minimum_required(VERSION 3.16)
project(konsole_runtime_rpath_probe C)

set(CMAKE_SKIP_RPATH OFF)
set(CMAKE_SKIP_INSTALL_RPATH OFF)
set(CMAKE_INSTALL_RPATH_USE_LINK_PATH ON)
include("$REPO_ROOT/contrib/konsole/export-static-helpers.cmake")
include("$REPO_ROOT/contrib/konsole/runtime-rpath.cmake")

add_library(konsoleapp SHARED probe.c)
add_executable(konsole main.c)
add_library(konsolepart MODULE probe.c)
add_library(static_probe STATIC probe.c)
target_link_libraries(konsole PRIVATE konsoleapp)
target_link_libraries(konsolepart PRIVATE konsoleapp)
install(TARGETS konsoleapp konsole konsolepart static_probe
    RUNTIME DESTINATION bin
    LIBRARY DESTINATION lib
    ARCHIVE DESTINATION lib)

cmake_language(DEFER DIRECTORY "\${CMAKE_CURRENT_SOURCE_DIR}"
    CALL _se_konsole_set_runtime_rpath)
CMAKE

cmake -S "$PROBE/source" -B "$PROBE/build" -G Ninja \
    >"$PROBE/configure.log" 2>&1 || {
    sed -n '1,200p' "$PROBE/configure.log" >&2
    exit 1
}
cmake --build "$PROBE/build" >"$PROBE/build.log" 2>&1 || {
    cat "$PROBE/build.log" >&2
    exit 1
}
cmake --install "$PROBE/build" --prefix "$PROBE/install" \
    >"$PROBE/install.log" 2>&1 || {
    cat "$PROBE/install.log" >&2
    exit 1
}

for binary in "$PROBE/install/bin/konsole" \
             "$PROBE/install/lib/libkonsoleapp.so" \
             "$PROBE/install/lib/libkonsolepart.so"; do
    readelf -d "$binary" | grep -Fq '[$ORIGIN/../lib]' || {
        printf 'missing origin-relative install RPATH in %s\n' "$binary" >&2
        readelf -d "$binary" >&2
        exit 1
    }
done

printf 'Konsole target runtime RPATH: PASS (executable, shared and MODULE)\n'
