#!/usr/bin/env bash
# Restore cached kde-builder source checkouts before the updater sees them.
# CMake source overlays intentionally edit tracked files while configuring a
# project. Those edits must never be mistaken for a developer worktree on the
# next run, especially when the cache restores a checkout on detached HEAD.
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'usage: %s SOURCE_ROOT\n' "$0" >&2
    exit 2
fi

SOURCE_ROOT=$1
if [[ ! -d $SOURCE_ROOT ]]; then
    printf 'error: KDE source root is not a directory: %s\n' "$SOURCE_ROOT" >&2
    exit 1
fi
SOURCE_ROOT=$(CDPATH= cd -- "$SOURCE_ROOT" && pwd -P)

found=0
while IFS= read -r -d '' git_marker; do
    repository=${git_marker%/.git}
    [[ -n $repository && -d $repository ]] || {
        printf 'error: invalid Git repository marker: %s\n' "$git_marker" >&2
        exit 1
    }
    top_level=$(git -C "$repository" rev-parse --show-toplevel)
    [[ $top_level == "$repository" ]] || {
        printf 'error: Git repository root mismatch: %s != %s\n' \
            "$top_level" "$repository" >&2
        exit 1
    }
    git -C "$repository" rev-parse --verify HEAD >/dev/null
    git -C "$repository" reset --quiet --hard HEAD >&2
    git -C "$repository" clean -fdx >&2
    found=1
done < <(find "$SOURCE_ROOT" -mindepth 1 \( -type d -o -type f \) \
    -name .git -print0)

if [[ $found -eq 0 ]]; then
    printf 'KDE source cache cleanup: no Git checkouts under %s\n' "$SOURCE_ROOT"
else
    printf 'KDE source cache cleanup: restored Git checkouts under %s\n' "$SOURCE_ROOT"
fi
