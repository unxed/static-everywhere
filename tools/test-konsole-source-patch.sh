#!/usr/bin/env bash
# Verify that every source patch is applicable to the exact pinned Konsole
# checkout. This is deliberately a source-only gate: it runs before CMake and
# prevents a patch from silently targeting a moved tag or a different source
# revision after an upstream update.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
SOURCE_DIR=${1:-}
PATCH="$REPO_ROOT/contrib/konsole/patches/0001-use-portable-home-placeholder.patch"

[[ -n $SOURCE_DIR ]] || {
    printf 'usage: %s KONSOLE_SOURCE_DIR\n' "$0" >&2
    exit 2
}
git -C "$SOURCE_DIR" rev-parse --git-dir >/dev/null 2>&1 || {
    printf 'error: Konsole source checkout is not a git repository: %s\n' \
        "$SOURCE_DIR" >&2
    exit 1
}
[[ -s $PATCH ]] || {
    printf 'error: Konsole source patch is missing or empty: %s\n' "$PATCH" >&2
    exit 1
}

expected=$(awk '$1 == "konsole" { print $3 }' "$REPO_ROOT/contrib/konsole/deps.lock")
actual=$(git -C "$SOURCE_DIR" rev-parse HEAD)
[[ -n $expected && $actual == "$expected" ]] || {
    printf 'error: Konsole source is %s, expected pinned %s\n' \
        "$actual" "$expected" >&2
    exit 1
}

git -C "$SOURCE_DIR" apply --check --whitespace=error "$PATCH"
printf 'Konsole pinned source patch: PASS (%s)\n' "$actual"
