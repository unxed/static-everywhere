#!/usr/bin/env bash
# A static build's private STATIC helpers must end up in the export set
# of the target that links them -- for every module, without naming any.
#
# Why this exists
# ---------------
# knewstuff:
#   install(EXPORT "KF6NewStuffCoreTargets" ...) includes target
#   "KF6NewStuffCore" which requires target "knscore_jobs_static" that is
#   not in any export set.
#
# KF6NewStuffCore links knscore_jobs_static PRIVATE. Shared, that is
# absorbed; static, CMake records $<LINK_ONLY:knscore_jobs_static> in the
# exported interface and demands the helper be exported too. Upstream
# builds shared and never sees it. The hook exports such helpers at the
# end of configure, reading the export set from the module's own
# install(TARGETS ... EXPORT ...) line.
#
# Checked on a minimal project of exactly that shape: it must fail without
# the hook (or the test proves nothing), configure with it, stay inert for
# a shared build, and not double-install a helper upstream already exports.
set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
HOOK="${REPO_ROOT}/contrib/konsole/project-include.cmake"
CXX="${REPO_ROOT}/onebin/toolchain/zig-c++"

if ! command -v cmake >/dev/null 2>&1 || ! command -v zig >/dev/null 2>&1; then
    printf 'cmake or zig unavailable; skipping\n'
    exit 0
fi

PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT

make_project() {  # $1 = dir, $2 = BUILD_SHARED_LIBS, $3 = extra install line
    mkdir -p "$1"
    printf 'int helper(){ return 1; }\n' >"$1/h.cpp"
    printf 'int helper(); int lib(){ return helper(); }\n' >"$1/l.cpp"
    cat >"$1/CMakeLists.txt" <<EOF
cmake_minimum_required(VERSION 3.19)
project(KNewStuffLike CXX)
set(BUILD_SHARED_LIBS $2)
add_library(knscore_jobs_static STATIC h.cpp)
add_library(KF6NewStuffCore l.cpp)
target_link_libraries(KF6NewStuffCore PRIVATE knscore_jobs_static)
install(TARGETS KF6NewStuffCore EXPORT KF6NewStuffCoreTargets DESTINATION lib)
$3
install(EXPORT KF6NewStuffCoreTargets DESTINATION lib/cmake/KF6NewStuffCore)
EOF
}

configure() {  # $1 = src, $2 = build, $3... = extra args
    local src=$1 build=$2; shift 2
    cmake -S "$src" -B "$build" -DCMAKE_CXX_COMPILER="$CXX" "$@" 2>&1 || true
}

make_project "$PROBE/static" OFF ""
out=$(configure "$PROBE/static" "$PROBE/b0")
printf '%s' "$out" | grep -q 'not in any export set' \
    || { printf 'the probe configures without the hook; it does not reproduce\n' >&2
         printf 'the knewstuff failure and proves nothing\n' >&2; exit 1; }

out=$(configure "$PROBE/static" "$PROBE/b1" -DCMAKE_PROJECT_INCLUDE="$HOOK")
if printf '%s' "$out" | grep -q 'not in any export set'; then
    printf 'the hook did not export the private static helper:\n' >&2
    printf '%s\n' "$out" | grep -E 'export set|static-everywhere' | sed 's/^/  /' >&2
    exit 1
fi
printf '%s' "$out" | grep -q 'exported private static helper knscore_jobs_static' \
    || { printf 'configure passed but the hook did not report its action;\n' >&2
         printf 'a silent mechanism is one whose evidence cannot be found later\n' >&2
         exit 1; }

make_project "$PROBE/shared" ON ""
out=$(configure "$PROBE/shared" "$PROBE/b2" -DCMAKE_PROJECT_INCLUDE="$HOOK")
if printf '%s' "$out" | grep -q 'exported private static helper'; then
    printf 'the hook exported a helper in a SHARED build, where none is needed\n' >&2
    exit 1
fi

make_project "$PROBE/upstream" OFF \
    'install(TARGETS knscore_jobs_static EXPORT KF6NewStuffCoreTargets DESTINATION lib)'
out=$(configure "$PROBE/upstream" "$PROBE/b3" -DCMAKE_PROJECT_INCLUDE="$HOOK")
if printf '%s' "$out" | grep -qE 'exported private static helper|Error'; then
    printf 'the hook re-exported a helper the module already installs\n' >&2
    exit 1
fi

printf 'static helper export: reproduced, fixed, inert for shared and for already-exported\n'
