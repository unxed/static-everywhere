#!/usr/bin/env bash
# The Qt edge repair must make a MODULE linked with --no-undefined resolve
# symbols from a dependency the Conan recipe omits.
set -euo pipefail
# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
CC="${REPO_ROOT}/onebin/toolchain/zig-cc"
if ! command -v zig >/dev/null 2>&1 || ! command -v cmake >/dev/null 2>&1; then printf 'zig or cmake unavailable; skipping\n'; exit 0; fi
P=$(mktemp -d); trap 'rm -rf "$P"' EXIT
printf 'int dep(void){ return 7; }\n' >"$P/dep.c"
printf 'int dep(void); int mm(void){ return dep(); }\n' >"$P/mm.c"
printf 'int mm(void); int plug(void){ return mm(); }\n' >"$P/plug.c"
"$CC" -target x86_64-linux-gnu.2.28 -fPIC -c "$P/dep.c" -o "$P/dep.o"; ar rcs "$P/libQt6Concurrent.a" "$P/dep.o"
"$CC" -target x86_64-linux-gnu.2.28 -fPIC -c "$P/mm.c" -o "$P/mm.o";   ar rcs "$P/libQt6Multimedia.a" "$P/mm.o"
cat >"$P/CMakeLists.txt" <<EOF
cmake_minimum_required(VERSION 3.19)
project(konsole C)
foreach(m Core Concurrent DBus)
  add_library(Qt6::\${m} STATIC IMPORTED)
  set_target_properties(Qt6::\${m} PROPERTIES IMPORTED_LOCATION $P/libQt6Concurrent.a)
endforeach()
add_library(Qt6::Multimedia STATIC IMPORTED)
set_target_properties(Qt6::Multimedia PROPERTIES IMPORTED_LOCATION $P/libQt6Multimedia.a)
add_library(part MODULE plug.c)
target_link_libraries(part PRIVATE Qt6::Multimedia)
target_link_options(part PRIVATE -Wl,--no-undefined)
EOF
printf 'include(%s/contrib/konsole/link-qt6-orphan-modules.cmake)\n' "$REPO_ROOT" >"$P/pi.cmake"
cmake -S "$P" -B "$P/b0" -DCMAKE_C_COMPILER="$CC" >/dev/null 2>&1
if cmake --build "$P/b0" >/dev/null 2>&1; then printf 'the probe links without the repair; it reproduces nothing\n' >&2; exit 1; fi
cmake -S "$P" -B "$P/b1" -DCMAKE_C_COMPILER="$CC" -DCMAKE_PROJECT_INCLUDE="$P/pi.cmake" >/dev/null 2>&1
cmake --build "$P/b1" >"$P/build.log" 2>&1 \
    || { printf 'the MODULE still fails with the edge repair:\n' >&2; grep -E 'undefined' "$P/build.log" | head -3 | sed 's/^/  /' >&2; exit 1; }
printf 'qt edge repair: Multimedia -> Concurrent resolved in a --no-undefined MODULE link\n'
