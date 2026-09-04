#!/usr/bin/env bash
# The KPackage block the project hook removes must still look the way the
# hook expects.
#
# Why this exists
# ---------------
# kpackage's src/kpackage/CMakeLists.txt installs a target that its own
# sources never create:
#
#   install TARGETS given target "kpackage_common_STATIC" which does not exist
#
# guarded by `if (NOT BUILD_SHARED_LIBS)`, so only a static build reaches
# it and upstream never does. project-include.cmake deletes that block,
# and -- correctly -- raises FATAL_ERROR if it no longer matches, rather
# than silently doing nothing. But that error arrives mid-build, two
# hours in. The block is a public file; checking it takes a second.
set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
HOOK="${REPO_ROOT}/contrib/konsole/project-include.cmake"

grep -q 'kpackage_common_STATIC' "$HOOK" || {
    printf 'the hook no longer mentions kpackage_common_STATIC; if the\n' >&2
    printf 'workaround was removed, remove this check with it\n' >&2
    exit 1
}

command -v curl >/dev/null 2>&1 || { printf 'curl unavailable; skipping\n'; exit 0; }

PROBE=$(mktemp -d); trap 'rm -rf "$PROBE"' EXIT
curl -fsSL --max-time 20 \
    "https://invent.kde.org/frameworks/kpackage/-/raw/master/src/kpackage/CMakeLists.txt" \
    -o "$PROBE/upstream.txt" 2>/dev/null || {
    printf 'could not fetch kpackage CMakeLists.txt; skipping\n'; exit 0; }

# The hook matches this exact three-line block. Compare against upstream.
if ! grep -Pzoq 'if \(NOT BUILD_SHARED_LIBS\)\n    install\(TARGETS kpackage_common_STATIC EXPORT KF6PackageTargets \$\{KF_INSTALL_TARGETS_DEFAULT_ARGS\}\)\nendif\(\)' \
        "$PROBE/upstream.txt"; then
    if grep -q 'kpackage_common_STATIC' "$PROBE/upstream.txt"; then
        printf 'kpackage still references kpackage_common_STATIC, but not in the\n' >&2
        printf 'exact block the hook removes. The hook will FATAL_ERROR two hours\n' >&2
        printf 'into the build; update the block text in project-include.cmake.\n' >&2
        exit 1
    fi
    printf 'kpackage no longer references kpackage_common_STATIC upstream;\n'
    printf 'the workaround in project-include.cmake can be retired.\n'
    exit 0
fi

printf 'kpackage: the stale install block still matches what the hook removes\n'
