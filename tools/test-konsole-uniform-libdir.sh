#!/usr/bin/env bash
# Every KF6 module must install its CMake package files under the same
# libdir, so find_package can see one module's dependency installed by
# another.
#
# Why this exists
# ---------------
# kio stopped on
#
#   The link interface of target "KF6::JobWidgets" contains
#     KF6::Notifications but the target was not found.
#
# not because knotifications was missing -- it was built and installed --
# but because the two modules installed to different places:
# kjobwidgets to lib/cmake, knotifications and kcoreaddons to
# lib/x86_64-linux-gnu/cmake. ECM defaults the libdir to
# lib/${CMAKE_LIBRARY_ARCHITECTURE} on a Debian host, unless
# CMAKE_INSTALL_LIBDIR is already set -- and the project hook's
# find_package(... CONFIG) pulls in Qt6, hence GNUInstallDirs, which sets
# it to lib before kjobwidgets reaches KDEInstallDirs. Include order
# decided the install path, and it differed per module.
#
# The recipe pins KDE_INSTALL_LIBDIR so the path no longer depends on
# what was included first. This asserts the pin is present, since the
# split cannot be reproduced without a full KDE build.
set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
CONFIG="${REPO_ROOT}/contrib/konsole/kde-builder.yaml.in"

# The pin must be in the global cmake-options, applying to every module.
grep -q -- '-DKDE_INSTALL_LIBDIR=' "$CONFIG" \
    || { printf 'KDE_INSTALL_LIBDIR is not pinned; module install paths will\n' >&2
         printf 'again depend on whether GNUInstallDirs was included first,\n' >&2
         printf 'and a dependency installed by one module will be invisible\n' >&2
         printf 'to another that installed elsewhere\n' >&2
         exit 1; }

# It must be a single value, not a per-module override that could drift
# back into two directories.
count=$(grep -c -- '-DKDE_INSTALL_LIBDIR=' "$CONFIG")
[ "$count" -eq 1 ] \
    || { printf 'KDE_INSTALL_LIBDIR is set %s times; a single global value is\n' \
             "$count" >&2
         printf 'what keeps every module in one libdir\n' >&2
         exit 1; }

# And it must sit in the global block, above the first per-module
# override, or it would not apply to every module.
pin_line=$(grep -n -- '-DKDE_INSTALL_LIBDIR=' "$CONFIG" | head -1 | cut -d: -f1)
override_line=$(grep -n '^override ' "$CONFIG" | head -1 | cut -d: -f1)
if [ -n "$override_line" ] && [ "$pin_line" -gt "$override_line" ]; then
    printf 'the KDE_INSTALL_LIBDIR pin is below the first per-module override,\n' >&2
    printf 'so it does not apply globally\n' >&2
    exit 1
fi

printf 'konsole libdir: pinned once, globally, so all modules share a libdir\n'
