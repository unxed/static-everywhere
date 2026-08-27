#!/usr/bin/env bash
# Regression test for tools/ctest-with-waivers.sh.
#
# The waiver exists so one upstream failure does not hide everything the
# build still has to prove. That is only defensible if four things hold,
# and each is checked here against a stand-in ctest:
#
#   1. an unrelated failure still fails -- the waiver must not become a
#      blanket "ignore ctest";
#   2. the waived case alone is tolerated, and the run continues;
#   3. a waived case that FAILS ALONGSIDE an unwaived one still fails;
#   4. when the waived case starts passing, the script FAILS with STALE
#      WAIVER. This is the property that matters most: a workaround
#      nobody is forced to revisit is permanent, so it is wired to
#      complain the moment upstream fixes the problem.
set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT

WAIVED='F4GalleryPointerTests::pixelWheelAndLoaderRecreationPreserveScroll'
OTHER='F4DocumentSurfaceTests::somethingElseEntirely'

# A stand-in ctest whose output and exit code the case file dictates.
make_ctest() {  # $1 = lines to print, $2 = exit code
    mkdir -p "$PROBE/bin"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'cat <<%s\n' 'CTESTEOF'
        printf '%s\n' "$1"
        printf 'CTESTEOF\n'
        printf 'exit %s\n' "$2"
    } >"$PROBE/bin/ctest"
    chmod +x "$PROBE/bin/ctest"
}

run() { PATH="$PROBE/bin:$PATH" "$SCRIPT_DIR/ctest-with-waivers.sh" --dummy; }

# 1. unrelated failure -> must fail
make_ctest "FAIL!  : ${OTHER}() Compared values are not the same" 1
if out=$(run 2>&1); then
    printf 'an unwaived failure was tolerated\n' >&2
    printf '%s\n' "$out" | sed 's/^/  /' >&2
    exit 1
fi
printf '%s' "$out" | grep -Fq 'Unwaived test failures' \
    || { printf 'unwaived failure was not reported as such\n' >&2; exit 1; }

# 2. only the waived case fails -> tolerated, and said out loud
make_ctest "FAIL!  : ${WAIVED}() Compared values are not the same" 1
out=$(run 2>&1) || { printf 'the waived case was not tolerated\n' >&2
                     printf '%s\n' "$out" | sed 's/^/  /' >&2; exit 1; }
printf '%s' "$out" | grep -Fq 'waiver, not a pass' \
    || { printf 'the waiver was applied silently\n' >&2; exit 1; }

# 3. waived AND unwaived together -> must still fail
make_ctest "FAIL!  : ${WAIVED}()
FAIL!  : ${OTHER}()" 1
if run >/dev/null 2>&1; then
    printf 'an unwaived failure was hidden by a waived one\n' >&2
    exit 1
fi

# 4. the waived case passes -> STALE WAIVER, and the run fails
make_ctest "PASS   : ${WAIVED}()
100% tests passed" 0
if out=$(run 2>&1); then
    printf 'a stale waiver was not reported -- the workaround would live forever\n' >&2
    exit 1
fi
printf '%s' "$out" | grep -Fq 'STALE WAIVER' \
    || { printf 'stale waiver did not name itself\n' >&2; exit 1; }

printf 'ctest waivers: unrelated fails, waived tolerated, stale waiver caught: pass\n'
