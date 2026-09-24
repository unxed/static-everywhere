#!/usr/bin/env bash
# Regression test for source overlays left in the kde-builder cache.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
PROBE=$(mktemp -d /tmp/static-everywhere-konsole-source-cache.XXXXXX)
trap 'rm -rf "$PROBE"' EXIT

mkdir -p "$PROBE/sources/framework"
git -C "$PROBE/sources/framework" init --quiet
printf 'clean me\n' >"$PROBE/sources/framework/tracked.txt"
git -C "$PROBE/sources/framework" add tracked.txt
git -C "$PROBE/sources/framework" \
    -c user.name='static-everywhere preflight' \
    -c user.email='preflight@example.invalid' commit --quiet -m baseline
printf 'overlay edit\n' >"$PROBE/sources/framework/tracked.txt"
printf 'overlay generated file\n' >"$PROBE/sources/framework/untracked.txt"

"$REPO_ROOT/tools/clean-kde-builder-source-tree.sh" "$PROBE/sources" >/dev/null
git -C "$PROBE/sources/framework" diff --quiet
git -C "$PROBE/sources/framework" diff --cached --quiet
[[ ! -e "$PROBE/sources/framework/untracked.txt" ]]
[[ $(git -C "$PROBE/sources/framework" status --porcelain) == '' ]]

printf 'Konsole source cache cleanup regression: PASS\n'
