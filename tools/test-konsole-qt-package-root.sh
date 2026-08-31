#!/usr/bin/env bash
# Regression test for Conan CMakeDeps data files whose names include the
# package spelling and host architecture.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
PROBE=$(mktemp -d /tmp/static-everywhere-konsole-qt-root.XXXXXX)
trap 'rm -rf "$PROBE"' EXIT

mkdir -p "$PROBE/qt-generators"
printf 'set(qt_PACKAGE_FOLDER_RELEASE "%s")\n' "$PROBE/qt-package"     >"$PROBE/qt-generators/Qt6-release-x86_64-data.cmake"
printf 'set(other_PACKAGE_FOLDER_RELEASE "%s")\n' "$PROBE/other"     >"$PROBE/qt-generators/other-release-x86_64-data.cmake"

# The real Conan output is Qt6-release-x86_64-data.cmake, not
# qt-release-*-data.cmake. The helper must inspect the variable, not guess
# the package filename.
# shellcheck disable=SC1091
source "$REPO_ROOT/contrib/konsole/qt-package-root.sh"
root=$(konsole_qt_package_root "$PROBE/qt-generators")
if [[ "$root" != "$PROBE/qt-package" ]]; then
    printf 'FAIL: expected %s, got %s\n' "$PROBE/qt-package" "$root" >&2
    exit 1
fi
printf 'Konsole Qt package-root regression: PASS\n'
