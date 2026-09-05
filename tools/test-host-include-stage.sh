#!/usr/bin/env bash
# With a staged host-include directory, a vendored header must win however
# the compile line is arranged, and a missing vendored dir must fail loudly.
#
# Why this exists
# ---------------
# konsole compiled against the host's ICU 74 and linked Conan's ICU 78.
# Reproduced: when the vendored include is ABSENT from the compile line,
# the wrapper's own -idirafter /usr/include supplies the host header
# silently. With the stage, the same compile fails loudly, and with the
# vendored dir present the vendored header wins regardless of a leading
# -I/usr/include or -isystem /usr/include. Needs the host's libicu-dev to
# stand in for "a host library the recipe never asked for".
set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

if ! command -v zig >/dev/null 2>&1; then printf 'zig unavailable; skipping\n'; exit 0; fi
if [ ! -f /usr/include/unicode/uvernum.h ]; then printf 'host libicu-dev absent; skipping\n'; exit 0; fi

PROBE=$(mktemp -d); trap 'rm -rf "$PROBE"' EXIT
mkdir -p "$PROBE/vendored/include/unicode" "$PROBE/stage"
printf '#define U_ICU_VERSION_MAJOR_NUM 7800\n' >"$PROBE/vendored/include/unicode/uvernum.h"
printf '#include <unicode/uvernum.h>\nint v = U_ICU_VERSION_MAJOR_NUM;\n' >"$PROBE/t.cpp"
cp "$PROBE/t.cpp" "$PROBE/t.c"

major() {  # $1 wrapper, $2 stage-or-empty, rest flags
    local w=$1 stage=$2; shift 2
    local src="$PROBE/t.cpp"
    if [ "$w" = zig-cc ]; then src="$PROBE/t.c"; fi   # not `&&`: under set -e a false test would abort the subshell
    # Captured first, then searched: the compile is EXPECTED to fail in the
    # missing-vendored case, and under pipefail a failing producer would
    # abort the whole subshell before grep reports what it saw.
    local out
    out=$(ONEBIN_HOST_INCLUDE_DIR="$stage" "${REPO_ROOT}/onebin/toolchain/$w" \
        -target x86_64-linux-gnu.2.28 "$@" -E -P "$src" 2>&1 || true)
    printf '%s' "$out" | grep -oE 'int v = [0-9]+|file not found' | head -1 || true
}

for w in zig-cc zig-c++; do
    # Control: without a stage the host header IS reachable via the fallback.
    r=$(major "$w" "")
    [[ $r == "int v = 7"* && $r != "int v = 7800" ]] \
        || { printf '%s no-stage control: expected the host ICU, got "%s"; the probe does not reproduce the shadowing\n' "$w" "$r" >&2; exit 1; }
    # Stage, vendored present, host first in both spellings: vendored wins.
    for first in "-I/usr/include" "-isystem /usr/include"; do
        # shellcheck disable=SC2086
        r=$(major "$w" "$PROBE/stage" $first -isystem "$PROBE/vendored/include")
        [ "$r" = "int v = 7800" ] \
            || { printf '%s with stage and %s first: expected vendored 7800, got "%s"\n' "$w" "$first" "$r" >&2; exit 1; }
    done
    # Stage, vendored absent: loud failure, not the host header.
    r=$(major "$w" "$PROBE/stage")
    [ "$r" = "file not found" ] \
        || { printf '%s with stage and no vendored dir: expected "file not found", got "%s"\n' "$w" "$r" >&2; exit 1; }
done
printf 'host include stage: both wrappers -- vendored wins with the stage, missing vendored fails loudly\n'
