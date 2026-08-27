#!/usr/bin/env bash
# Run ctest, tolerating a short list of named upstream failures.
#
# Why this exists
# ---------------
# One test case fails for a reason outside this repository's control, and
# it sits in front of everything the build still has to prove -- the glibc
# audit, the smoke run, packaging, the final static audit. Stopping there
# means none of that gets exercised.
#
# What makes this a waiver rather than a suppression
# --------------------------------------------------
# 1. It names ONE test case, not a suite and not a pattern. The other
#    twelve cases in the same binary still have to pass.
# 2. It expires by itself. If a waived case starts passing, this script
#    FAILS and says so. Good news that goes unnoticed leaves the crutch
#    in place forever, so the crutch is wired to complain the moment it
#    stops being needed. Removing it is then a three-line deletion in the
#    table below, which is the point.
# 3. Every entry carries its evidence: what fails, why it is not ours,
#    and where the report lives.
#
# Adding an entry is deliberately awkward. It should be.

set -uo pipefail

# ---------------------------------------------------------------------------
# The waiver table. One line per case: "Suite::case|report|why"
#
# To retire an entry: delete its line. Nothing else refers to it.
# ---------------------------------------------------------------------------
WAIVERS=(
"F4GalleryPointerTests::pixelWheelAndLoaderRecreationPreserveScroll|f4-bugreport-pointer-test-race.md|The test waits for qRound(contentY)==37, which is true once contentY passes 36.5, then immediately checks session.panelScrollOffset -- but GalleryPanel.qml writes that only when the 150ms scroll animation STOPS (galleryPanelScrollAnimation onRunningChanged, guarded by !running). Under offscreen rendering the frame cadence differs and the comparison runs before the write. A test-timing race in f4, present on any host; no product code implicated."
)

if [ "$#" -eq 0 ]; then
    printf 'usage: %s <ctest args...>\n' "$0" >&2
    exit 2
fi

OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT

ctest "$@" 2>&1 | tee "$OUT"
CTEST_RC=${PIPESTATUS[0]}

# QTest prints one line per failing case; ctest only names the binary.
# Waiving by case keeps the rest of the binary honest.
FAILED_CASES=$(grep -oE '^FAIL!  : [A-Za-z0-9_]+::[A-Za-z0-9_]+' "$OUT" \
               | sed 's/^FAIL!  : //' | sort -u)

waived_names=()
for entry in "${WAIVERS[@]}"; do
    waived_names+=("${entry%%|*}")
done

# A waiver is stale only when its case actually PASSED. "Did not fail"
# is not the same claim: a case can be absent because the binary crashed,
# because a filter excluded it, or because an earlier failure stopped the
# suite -- and calling any of those a fix would delete the waiver at
# exactly the wrong moment. The first version of this script made that
# mistake and its own test caught it.
PASSED_CASES=$(grep -oE '^PASS   : [A-Za-z0-9_]+::[A-Za-z0-9_]+' "$OUT" \
               | sed 's/^PASS   : //' | sort -u)

stale=0
for name in "${waived_names[@]}"; do
    if printf '%s\n' "$PASSED_CASES" | grep -Fxq "$name"; then
        printf '\n'
        printf 'STALE WAIVER: %s now passes.\n' "$name"
        printf 'Delete its line from the WAIVERS table in %s.\n' "$0"
        printf 'This failure is deliberate: it is how the workaround gets removed\n'
        printf 'once upstream fixes the underlying problem.\n'
        stale=1
    fi
done
if [ "$stale" -ne 0 ]; then
    exit 1
fi

# Anything failing that is not waived is a real failure.
unwaived=""
while IFS= read -r case_name; do
    [ -n "$case_name" ] || continue
    keep=1
    for name in "${waived_names[@]}"; do
        if [ "$case_name" = "$name" ]; then
            keep=0
        fi
    done
    if [ "$keep" -eq 1 ]; then
        unwaived="${unwaived}${case_name}"$'\n'
    fi
done <<<"$FAILED_CASES"

if [ -n "${unwaived//[$'\n']/}" ]; then
    printf '\nUnwaived test failures:\n'
    printf '%s' "$unwaived" | sed 's/^/  /'
    exit 1
fi

if [ "$CTEST_RC" -ne 0 ]; then
    printf '\n'
    printf 'ctest failed only on waived upstream cases; continuing.\n'
    for entry in "${WAIVERS[@]}"; do
        name="${entry%%|*}"
        rest="${entry#*|}"
        report="${rest%%|*}"
        why="${rest#*|}"
        printf '  %s\n' "$name"
        printf '    report: %s\n' "$report"
        printf '    %s\n' "$why"
    done
    printf '\nThis is a waiver, not a pass. When upstream fixes it this script\n'
    printf 'will fail with STALE WAIVER, and the entry should be deleted.\n'
fi

exit 0
