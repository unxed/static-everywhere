#!/usr/bin/env bash
# A consumer must be able to include an export that names a target the
# exporting package forgot to declare.
#
# Why this exists
# ---------------
# kjobwidgets requires KF6Notifications -- find_package(... REQUIRED) --
# and records KF6::Notifications in the link interface it exports. Its
# generated KF6JobWidgetsConfig.cmake declares only Qt6Widgets and
# KF6CoreAddons, so kio's find_package(KF6JobWidgets) pulled in a targets
# file naming a target nobody had defined:
#
#   The link interface of target "KF6::JobWidgets" contains:
#     KF6::Notifications
#   but the target was not found.
#
# The first attempt assumed the dependency was optional, since the config
# did not declare it, and disabled it. It is REQUIRED: that moved the
# failure one module earlier, to kjobwidgets itself. The dependency is
# real; only the declaration is missing.
#
# So the project hook defines the target ahead of any export that names
# it. This checks the property that matters -- a consumer configures --
# rather than the mechanism, so the fix can be replaced without the test
# needing to change.
set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

if ! command -v cmake >/dev/null 2>&1 || ! command -v zig >/dev/null 2>&1; then
    printf 'cmake or zig unavailable; skipping\n'
    exit 0
fi

PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT
CXX="${REPO_ROOT}/onebin/toolchain/zig-c++"

# A package that exports a reference to another package's target without
# declaring the dependency -- kjobwidgets' shape exactly.
mkdir -p "$PROBE/prefix/lib/cmake/KF6Notifications" \
         "$PROBE/prefix/lib/cmake/KF6JobWidgets" "$PROBE/proj"
printf 'add_library(KF6::Notifications INTERFACE IMPORTED)\n' \
    >"$PROBE/prefix/lib/cmake/KF6Notifications/KF6NotificationsConfig.cmake"
cat >"$PROBE/prefix/lib/cmake/KF6JobWidgets/KF6JobWidgetsTargets.cmake" <<'INNER'
add_library(KF6::JobWidgets INTERFACE IMPORTED)
set_target_properties(KF6::JobWidgets PROPERTIES
    INTERFACE_LINK_LIBRARIES "KF6::Notifications")
INNER
# shellcheck disable=SC2016  # CMake variable, must not expand in the shell
printf 'include("${CMAKE_CURRENT_LIST_DIR}/KF6JobWidgetsTargets.cmake")\n' \
    >"$PROBE/prefix/lib/cmake/KF6JobWidgets/KF6JobWidgetsConfig.cmake"

printf 'int main(){ return 0; }\n' >"$PROBE/proj/m.cpp"
cat >"$PROBE/proj/CMakeLists.txt" <<'INNER'
cmake_minimum_required(VERSION 3.16)
project(consumer CXX)
find_package(KF6JobWidgets REQUIRED CONFIG)
add_executable(app m.cpp)
target_link_libraries(app PRIVATE KF6::JobWidgets)
INNER

configure_with() {  # $1 = build dir, $2... = extra cmake args
    local build=$1; shift
    cmake -S "$PROBE/proj" -B "$build" \
        -DCMAKE_CXX_COMPILER="$CXX" \
        -DCMAKE_PREFIX_PATH="$PROBE/prefix" "$@" 2>&1
}

# Without the hook the consumer must fail, or this test cannot tell
# whether the hook is doing anything.
# Captured first: cmake exits non-zero here by design, and under
# pipefail a pipeline would report that failure rather than grep's result.
bare_out=$(configure_with "$PROBE/bare" || true)
if ! printf '%s' "$bare_out" | grep -q 'target was not found'; then
    printf 'the probe configured even without the hook, so it does not\n' >&2
    printf 'reproduce the failure it exists to guard against\n' >&2
    exit 1
fi

# With the project hook it must configure cleanly.
out=$(configure_with "$PROBE/hooked" \
      -DCMAKE_PROJECT_INCLUDE="${REPO_ROOT}/contrib/konsole/project-include.cmake" || true)
printf '%s' "$out" | grep -q 'target was not found' \
    && { printf 'the project hook does not predefine the exported target:\n' >&2
         printf '%s\n' "$out" | grep -A 3 'target was not found' | sed 's/^/  /' >&2
         exit 1; }

# And the dependency must not be disabled anywhere: it is REQUIRED, and
# disabling it broke kjobwidgets itself.
if grep -q 'CMAKE_DISABLE_FIND_PACKAGE_KF6Notifications' \
        "${REPO_ROOT}/contrib/konsole/kde-builder.yaml.in"; then
    printf 'KF6Notifications is disabled again; kjobwidgets requires it and\n' >&2
    printf 'fails with "A REQUIRED package cannot be disabled"\n' >&2
    exit 1
fi

printf 'export targets: predefined for consumers, dependency left enabled\n'
