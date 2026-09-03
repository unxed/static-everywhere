#!/usr/bin/env bash
# Run a module's `make install`, then reconcile the CMake package configs
# it just installed against the targets they export.
#
# Why this exists
# ---------------
# kde-builder builds the KF6 chain in one invocation, and kio configures
# in the middle of it -- long before the chain ends. kio consumes
# KF6JobWidgets, whose installed config forgets to declare its own
# KF6Notifications dependency (upstream's KF6JobWidgetsConfig.cmake.in
# lists Qt6Widgets and KF6CoreAddons but not KF6Notifications, while
# CMakeLists.txt:53 requires it and the export references
# KF6::Notifications). So kio stopped on a target nobody had declared.
#
# There is no point "after the whole build" to repair this, because the
# failure is mid-chain. The one moment that works is immediately after
# each module installs and before the next configures -- which is exactly
# where kde-builder's make-install-prefix runs. This wrapper is that
# prefix: it performs the install it was handed, then reconciles.
#
# It takes the install command as its arguments (make-install-prefix
# precedes `make install` with it) and needs the install prefix and the
# reconciler passed through the environment, since the prefix has no way
# to add its own options.
set -euo pipefail

# Do the install first: a reconcile before it would have nothing to fix.
"$@"
install_status=$?

# Then reconcile, if we were told where and how. Absence is not an error:
# a build that has not set these simply installs as before.
if [ -n "${SE_RECONCILE_TOOL:-}" ] && [ -n "${SE_RECONCILE_PREFIX:-}" ]; then
    if [ -x "$SE_RECONCILE_TOOL" ] && [ -d "$SE_RECONCILE_PREFIX" ]; then
        # A reconcile failure must not mask a successful install, but it
        # must be visible: report it and carry the install's status.
        "$SE_RECONCILE_TOOL" "$SE_RECONCILE_PREFIX" \
            || printf 'kde-install-and-reconcile: reconcile reported an issue\n' >&2
    fi
fi

exit "$install_status"
