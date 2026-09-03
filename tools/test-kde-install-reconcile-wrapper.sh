#!/usr/bin/env bash
# The install-and-reconcile wrapper must install first, reconcile after,
# and do nothing extra when not asked to.
set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WRAP="${SCRIPT_DIR}/kde-install-and-reconcile.sh"
RECON="${SCRIPT_DIR}/reconcile-cmake-target-deps.sh"
PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT

# An "install" that records when it ran and lays down an under-declared
# config, exactly the kjobwidgets shape.
mkdir -p "$PROBE/prefix/lib/cmake/KF6Notifications"
: >"$PROBE/prefix/lib/cmake/KF6Notifications/KF6NotificationsConfig.cmake"
cat >"$PROBE/install.sh" <<INNER
#!/usr/bin/env bash
mkdir -p "$PROBE/prefix/lib/cmake/KF6JobWidgets"
cat > "$PROBE/prefix/lib/cmake/KF6JobWidgets/KF6JobWidgetsTargets.cmake" <<'T'
add_library(KF6::JobWidgets INTERFACE IMPORTED)
set_target_properties(KF6::JobWidgets PROPERTIES INTERFACE_LINK_LIBRARIES "KF6::Notifications")
T
printf 'include(CMakeFindDependencyMacro)\n' \
  > "$PROBE/prefix/lib/cmake/KF6JobWidgets/KF6JobWidgetsConfig.cmake"
INNER
chmod +x "$PROBE/install.sh"

# With the env set, the config must gain its missing find_dependency.
SE_RECONCILE_TOOL="$RECON" SE_RECONCILE_PREFIX="$PROBE/prefix" \
    "$WRAP" "$PROBE/install.sh" >/dev/null 2>&1
grep -q 'find_dependency(KF6Notifications)' \
    "$PROBE/prefix/lib/cmake/KF6JobWidgets/KF6JobWidgetsConfig.cmake" \
    || { printf 'the wrapper did not reconcile the installed config\n' >&2; exit 1; }

# The reconcile must happen AFTER the install: reset, and prove the
# wrapper does not reconcile a config that the install has not written
# yet. If it ran the tool first, there would be nothing to fix and the
# marker below would be absent; running the install first is the whole
# point.
rm -rf "$PROBE/prefix/lib/cmake/KF6JobWidgets"
SE_RECONCILE_TOOL="$RECON" SE_RECONCILE_PREFIX="$PROBE/prefix" \
    "$WRAP" "$PROBE/install.sh" >/dev/null 2>&1
[ -f "$PROBE/prefix/lib/cmake/KF6JobWidgets/KF6JobWidgetsConfig.cmake" ] \
    || { printf 'the install did not run through the wrapper\n' >&2; exit 1; }
grep -q 'find_dependency(KF6Notifications)' \
    "$PROBE/prefix/lib/cmake/KF6JobWidgets/KF6JobWidgetsConfig.cmake" \
    || { printf 'install ran but reconcile did not follow it\n' >&2; exit 1; }

# Without the env, the wrapper must be a transparent pass-through: the
# install still happens, and nothing is reconciled.
rm -rf "$PROBE/prefix/lib/cmake/KF6JobWidgets"
"$WRAP" "$PROBE/install.sh" >/dev/null 2>&1
[ -f "$PROBE/prefix/lib/cmake/KF6JobWidgets/KF6JobWidgetsConfig.cmake" ] \
    || { printf 'the wrapper swallowed the install when no env was set\n' >&2; exit 1; }
if grep -q 'find_dependency(KF6Notifications)' \
    "$PROBE/prefix/lib/cmake/KF6JobWidgets/KF6JobWidgetsConfig.cmake"; then
    printf 'the wrapper reconciled without being asked to\n' >&2
    exit 1
fi

# A failing install must fail the wrapper, since make-install-prefix must
# not turn a broken install into a green one.
printf '#!/usr/bin/env bash\nexit 3\n' >"$PROBE/fail.sh"
chmod +x "$PROBE/fail.sh"
if "$WRAP" "$PROBE/fail.sh" >/dev/null 2>&1; then
    printf 'the wrapper hid a failing install\n' >&2
    exit 1
fi

printf 'install-and-reconcile: installs then reconciles, transparent without env, honest on failure\n'
