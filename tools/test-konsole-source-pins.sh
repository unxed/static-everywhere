#!/usr/bin/env bash
# Regression guard for tools/konsole-source-pins.py clone/verify.
#
# kde-builder checks out a `commit:` pin only in an existing clone, so the
# build clones missing projects first and verifies every tree afterwards.
# This fixture uses a local repository with two commits: the pin is the
# older one, the default branch has moved on -- the situation the pins exist
# for. clone must keep a cached checkout, verify must reject a tree at the
# branch head and accept it at the pin.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TOOL="$SCRIPT_DIR/konsole-source-pins.py"
PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT
fail() { printf 'test-konsole-source-pins: FAIL: %s\n' "$*" >&2; exit 1; }

export GIT_AUTHOR_NAME=probe GIT_AUTHOR_EMAIL=probe@example.invalid
export GIT_COMMITTER_NAME=probe GIT_COMMITTER_EMAIL=probe@example.invalid
git init --quiet -b master "$PROBE/upstream"
git -C "$PROBE/upstream" commit --quiet --allow-empty -m pinned
pinned=$(git -C "$PROBE/upstream" rev-parse HEAD)
git -C "$PROBE/upstream" commit --quiet --allow-empty -m later
later=$(git -C "$PROBE/upstream" rev-parse HEAD)

printf '# fixture\nkfake %s file://%s\n' "$pinned" "$PROBE/upstream" >"$PROBE/lock"
export KONSOLE_SOURCE_PINS_LOCK="$PROBE/lock"

python3 "$TOOL" clone "$PROBE/src" >/dev/null
[[ -d $PROBE/src/kfake/.git ]] || fail 'clone did not create the missing checkout'
git -C "$PROBE/src/kfake" cat-file -e "$pinned^{commit}" || fail 'the clone lacks the pinned commit'

marker="$PROBE/src/kfake/cached-marker"
: >"$marker"
python3 "$TOOL" clone "$PROBE/src" >/dev/null
[[ -e $marker ]] || fail 'clone replaced a cached checkout'
rm -f "$marker"

[[ $(git -C "$PROBE/src/kfake" rev-parse HEAD) == "$later" ]] || fail 'fixture: clone is not at the branch head'
if python3 "$TOOL" verify "$PROBE/src" 2>/dev/null; then
    fail 'verify accepted a tree built at the branch head instead of the pin'
fi
git -C "$PROBE/src/kfake" checkout --quiet --detach "$pinned"
python3 "$TOOL" verify "$PROBE/src" >/dev/null || fail 'verify rejected a tree at its pin'

printf 'Konsole source pins: PASS (clone keeps caches, verify enforces the pin)\n'
