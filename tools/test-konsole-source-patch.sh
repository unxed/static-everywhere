#!/usr/bin/env bash
# Verify that every source patch is applicable to the exact pinned Konsole
# checkout. This is deliberately a source-only gate: it runs before CMake and
# prevents a patch from silently targeting a moved tag or a different source
# revision after an upstream update.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
SOURCE_DIR=${1:-}
PATCH_DIR="$REPO_ROOT/contrib/konsole/patches"
PATCH_PROBE=$(mktemp -d /tmp/static-everywhere-konsole-source.XXXXXX)
trap 'rm -rf "$PATCH_PROBE"' EXIT

[[ -n $SOURCE_DIR ]] || {
    printf 'usage: %s KONSOLE_SOURCE_DIR\n' "$0" >&2
    exit 2
}
git -C "$SOURCE_DIR" rev-parse --git-dir >/dev/null 2>&1 || {
    printf 'error: Konsole source checkout is not a git repository: %s\n' \
        "$SOURCE_DIR" >&2
    exit 1
}
mapfile -t patches < <(find "$PATCH_DIR" -maxdepth 1 -type f -name '*.patch' -print | sort)
(( ${#patches[@]} > 0 )) || {
    printf 'error: no Konsole source patches found: %s\n' "$PATCH_DIR" >&2
    exit 1
}
for patch in "${patches[@]}"; do
    [[ -s $patch ]] || {
        printf 'error: Konsole source patch is empty: %s\n' "$patch" >&2
        exit 1
    }
done

expected=$(awk '$1 == "konsole" { print $3 }' "$REPO_ROOT/contrib/konsole/deps.lock")
actual=$(git -C "$SOURCE_DIR" rev-parse HEAD)
[[ -n $expected && $actual == "$expected" ]] || {
    printf 'error: Konsole source is %s, expected pinned %s\n' \
        "$actual" "$expected" >&2
    exit 1
}

git -C "$SOURCE_DIR" archive "$actual" | tar -x -C "$PATCH_PROBE"
for patch in "${patches[@]}"; do
    git -C "$PATCH_PROBE" apply --check --whitespace=error "$patch"
    git -C "$PATCH_PROBE" apply --whitespace=error "$patch"
    printf 'Konsole pinned source patch: PASS (%s, %s)\n' \
        "$actual" "${patch##*/}"
done

main_source="$PATCH_PROBE/src/main.cpp"
[[ -r $main_source ]] || {
    printf 'error: patched Konsole main source is missing: %s\n' "$main_source" >&2
    exit 1
}
app_line=$(awk '/new QApplication\(argc, argv\)/ { print NR; exit }' "$main_source")
[[ -n $app_line ]] || {
    printf 'error: patched Konsole main has no QApplication construction\n' >&2
    exit 1
}
icon_line=$(awk '/KIconTheme::initTheme\(\)/ { print NR; exit }' "$main_source")
[[ -n $icon_line ]] || {
    printf 'error: patched Konsole main has no KIconTheme::initTheme() call\n' >&2
    exit 1
}
if (( icon_line >= app_line )); then
    printf 'error: KIconTheme::initTheme() must precede QApplication\n' >&2
    exit 1
fi
for gui_helper in \
    'KStyleManager::initStyle()' \
    'QApplication::setStyle'; do
    helper_line=$(awk -v token="$gui_helper" 'index($0, token) { print NR; exit }' "$main_source")
    if [[ -n $helper_line && $helper_line -lt $app_line ]]; then
        printf 'error: patched Konsole GUI helper precedes QApplication: %s\n' \
            "$gui_helper" >&2
        exit 1
    fi
done
printf 'Konsole GUI startup order: PASS (KIconTheme bootstrap precedes QApplication; remaining helpers follow)\n'
