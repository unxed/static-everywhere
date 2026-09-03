#!/usr/bin/env bash
# The reconciler must repair a config that under-declares its own export,
# and refuse to when the package is genuinely absent.
#
# Why this exists
# ---------------
# kjobwidgets records KF6::Notifications in KF6JobWidgetsTargets.cmake
# while KF6JobWidgetsConfig.cmake declares only Qt6Widgets and
# KF6CoreAddons. kio called find_package(KF6JobWidgets), got a targets
# file naming a target nobody defined, and stopped. Both modules had
# built, in the right order; the config simply never said it needed the
# other one.
set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TOOL="${SCRIPT_DIR}/reconcile-cmake-target-deps.sh"
PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT

mkdir -p "$PROBE/ok/lib/cmake/KF6JobWidgets" \
         "$PROBE/ok/lib/cmake/KF6Notifications" \
         "$PROBE/ok/lib/cmake/KF6CoreAddons"
cat >"$PROBE/ok/lib/cmake/KF6JobWidgets/KF6JobWidgetsTargets.cmake" <<'INNER'
add_library(KF6::JobWidgets STATIC IMPORTED)
set_target_properties(KF6::JobWidgets PROPERTIES
  INTERFACE_LINK_LIBRARIES "KF6::CoreAddons;KF6::Notifications")
INNER
cat >"$PROBE/ok/lib/cmake/KF6JobWidgets/KF6JobWidgetsConfig.cmake" <<'INNER'
include(CMakeFindDependencyMacro)
find_dependency(Qt6Widgets 6.9.0)
INNER
: >"$PROBE/ok/lib/cmake/KF6Notifications/KF6NotificationsConfig.cmake"
# CoreAddons is in the same export, so the prefix has to contain it too;
# the first version of this fixture did not, and the tool correctly
# objected rather than patching in a dependency that was not there.
: >"$PROBE/ok/lib/cmake/KF6CoreAddons/KF6CoreAddonsConfig.cmake"

"$TOOL" "$PROBE/ok" >/dev/null \
    || { printf 'the reconciler failed on a repairable prefix\n' >&2; exit 1; }
grep -q 'find_dependency(KF6Notifications)' \
    "$PROBE/ok/lib/cmake/KF6JobWidgets/KF6JobWidgetsConfig.cmake" \
    || { printf 'the missing find_dependency was not added\n' >&2; exit 1; }

# Idempotent: running twice must not duplicate the call.
"$TOOL" "$PROBE/ok" >/dev/null
count=$(grep -c 'find_dependency(KF6Notifications)' \
        "$PROBE/ok/lib/cmake/KF6JobWidgets/KF6JobWidgetsConfig.cmake")
[ "$count" -eq 1 ] \
    || { printf 'the reconciler is not idempotent: %s calls\n' "$count" >&2; exit 1; }

# Absent package: report, do not patch. Adding a find_dependency for
# something that is not installed only moves the error.
mkdir -p "$PROBE/bad/lib/cmake/KF6JobWidgets"
cat >"$PROBE/bad/lib/cmake/KF6JobWidgets/KF6JobWidgetsTargets.cmake" <<'INNER'
add_library(KF6::JobWidgets STATIC IMPORTED)
set_target_properties(KF6::JobWidgets PROPERTIES
  INTERFACE_LINK_LIBRARIES "KF6::Nowhere")
INNER
printf 'include(CMakeFindDependencyMacro)\n' \
    >"$PROBE/bad/lib/cmake/KF6JobWidgets/KF6JobWidgetsConfig.cmake"
if "$TOOL" "$PROBE/bad" >/dev/null 2>&1; then
    printf 'the reconciler accepted an export naming an absent package\n' >&2
    exit 1
fi
grep -q 'find_dependency(KF6Nowhere)' \
    "$PROBE/bad/lib/cmake/KF6JobWidgets/KF6JobWidgetsConfig.cmake" \
    && { printf 'it patched in a dependency that is not installed\n' >&2; exit 1; }

printf 'cmake target deps: under-declared exports repaired, absent ones reported\n'
