#!/usr/bin/env bash
# Every consumer of contrib/konsole/deps.lock, anywhere in the repository,
# must read it in the same field layout.
#
# Why this exists
# ---------------
# The lock's konsole line changed from `konsole <sha> - <url>` to
# `konsole <tag> <commit> <url>`. I updated the consumer I found by
# grepping tools/. The workflow had another, which compared
# `git rev-parse HEAD` to field 2 -- a commit hash to a tag name -- and
# the preflight died in 32 seconds. Then the recorded commit was the tag
# object rather than the peeled commit, and it died again.
#
# Both were one grep over the whole tree away. This is that grep, kept.
set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
cd "$REPO_ROOT"

# 1. Enumerate every consumer, repository-wide, not one directory.
mapfile -t consumers < <(grep -rl 'konsole/deps.lock' --include='*.sh' --include='*.yml' --include='*.yaml' --include='*.py' . | grep -v 'test-konsole-lock-consumers.sh' | sort)
[ "${#consumers[@]}" -gt 0 ] || { printf 'no consumers of konsole/deps.lock found; renamed?\n' >&2; exit 1; }

# 2. Each one that extracts the konsole ref must take field 2, and any
#    that compares a checkout to the lock must compare against field 3
#    (the commit), never field 2 (the tag).
status=0
# shellcheck disable=SC2016  # the $ signs are literal grep patterns
for f in "${consumers[@]}"; do
    if grep -qE '\$1 == "konsole"' "$f"; then
        if grep -qE 'rev-parse HEAD.*\$KONSOLE_REF|\$KONSOLE_REF.*rev-parse HEAD' "$f"; then
            printf '%s compares rev-parse HEAD to the tag (field 2); use the commit in field 3\n' "$f" >&2
            status=1
        fi
    fi
done

# 3. The lock itself: field 3 must be a 40-hex commit and field 2 must not be.
line=$(awk '$1 == "konsole"' contrib/konsole/deps.lock)
ref=$(printf '%s' "$line" | awk '{print $2}')
sha=$(printf '%s' "$line" | awk '{print $3}')
[[ $sha =~ ^[0-9a-f]{40}$ ]] \
    || { printf 'deps.lock field 3 for konsole is not a commit sha: %s\n' "$sha" >&2; status=1; }
[[ ! $ref =~ ^[0-9a-f]{40}$ ]] \
    || { printf 'deps.lock field 2 for konsole is a sha; kde-builder needs a tag or branch\n' >&2; status=1; }

[ "$status" -eq 0 ] && printf 'lock consumers: %s files read konsole/deps.lock, all agree on the field layout\n' "${#consumers[@]}"
exit "$status"
