#!/usr/bin/env bash
# Regression test: the build must not embed build-machine paths in
# DT_RUNPATH.
#
# The first audit that could read the binary reported 48 errors, 47 of
# them OB0040 -- "search path component is not $ORIGIN-relative" -- one
# per Conan package directory. CMake records the directory of every
# shared library it links as a build rpath, so an artefact meant to run
# anywhere carried absolute paths from the machine that built it: a
# portability hazard and a leak of the build environment in one.
#
# The probe links a shared library from a non-standard directory, which
# is the shape that produces the entry, and checks both directions:
# without the setting the directory IS recorded (so the probe genuinely
# reproduces the problem), and with it the directory is gone.
set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT

ZIGCC="${REPO_ROOT}/onebin/toolchain/zig-cc"
if ! command -v zig >/dev/null 2>&1; then
    printf 'zig not on PATH; skipping\n'
    exit 0
fi

mkdir -p "$PROBE/ext" "$PROBE/src"
printf 'int ext(void){return 5;}\n' >"$PROBE/e.c"
"$ZIGCC" -target x86_64-linux-gnu.2.27 -shared -fPIC \
    "$PROBE/e.c" -o "$PROBE/ext/libext.so"

cat >"$PROBE/src/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.21)
project(rpath_probe C)
add_library(ext SHARED IMPORTED)
set_property(TARGET ext PROPERTY IMPORTED_LOCATION "${EXTDIR}/libext.so")
file(WRITE "${CMAKE_BINARY_DIR}/m.c"
     "int ext(void); int main(void){return ext()-5;}\n")
add_executable(app "${CMAKE_BINARY_DIR}/m.c")
target_link_libraries(app PRIVATE ext)
CMAKE

runpath_of() {  # $1 = binary
    readelf -d "$1" 2>/dev/null \
        | grep -E 'RUNPATH|RPATH' \
        | sed 's/.*\[\(.*\)\]/\1/' || true
}

build() {  # $1 = build dir, $2... = extra cmake args
    dir="$1"; shift
    cmake -S "$PROBE/src" -B "$dir" -G Ninja \
        -DEXTDIR="$PROBE/ext" -DCMAKE_C_COMPILER="$ZIGCC" "$@" \
        >"$dir.log" 2>&1
    cmake --build "$dir" >>"$dir.log" 2>&1
}

# Negative control: the probe must reproduce the defect when the setting
# is absent, or it proves nothing when the setting is present.
build "$PROBE/without"
if ! runpath_of "$PROBE/without/app" | grep -Fq "$PROBE/ext"; then
    printf 'the probe no longer reproduces the embedded dependency path\n' >&2
    printf '  RUNPATH was: %s\n' "$(runpath_of "$PROBE/without/app")" >&2
    exit 1
fi

build "$PROBE/with" -DCMAKE_SKIP_RPATH=ON
if runpath_of "$PROBE/with/app" | grep -Fq "$PROBE/ext"; then
    printf 'CMAKE_SKIP_RPATH did not remove the dependency directory\n' >&2
    printf '  RUNPATH was: %s\n' "$(runpath_of "$PROBE/with/app")" >&2
    exit 1
fi

printf 'rpath: dependency directories are not embedded: pass\n'
