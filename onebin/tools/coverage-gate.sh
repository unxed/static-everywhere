#!/bin/sh
# tools/coverage-gate.sh — 00-AGENT-TASK.md Task 11's gate:
# line coverage >= 90% and branch coverage >= 85% over src/, with 100%
# line coverage on util/buf.c and util/ver.c. Exits non-zero below
# threshold — this is a gate, not a report.
#
# Run by `make coverage` after build/cov/tests has executed (which is what
# produces the .gcda files this script reads via gcov).
set -eu

cd "$(dirname "$0")/.."

COVDIR=build/cov
LINE_THRESHOLD=90
BRANCH_THRESHOLD=85

# Every src/ source compiled into build/cov/tests, named the way GCC names
# gcno/gcda files for a multi-source single-invocation build: "tests-<source
# basename, minus .c>.gcno". Keep this list in sync with Makefile's LIB_SRC
# (minus tests/mkelf.c, which is test infrastructure, not src/).
SOURCES="
src/util/buf.c
src/util/ver.c
src/util/str.c
src/util/json.c
src/util/vec.c
src/elf/image.c
src/elf/dynamic.c
src/elf/verneed.c
src/elf/symbols.c
src/elf/strings.c
src/audit/finding.c
src/audit/baseline.c
src/audit/report.c
src/audit/report_text.c
src/audit/report_json.c
src/audit/checks_common.c
src/audit/checks/c_needed.c
src/audit/checks/c_profile.c
src/audit/checks/c_glibc.c
src/audit/checks/c_rpath.c
src/audit/checks/c_harden.c
src/audit/checks/c_hygiene.c
src/audit/checks/c_host.c
src/audit/checks/c_meta.c
src/audit/audit.c
"

total_lines=0
total_lines_hit=0
total_branches=0
total_branches_hit=0
fail=0

echo "coverage: per-file line / branch %"

for src in $SOURCES; do
    base=$(basename "$src" .c)
    gcno="$COVDIR/tests-$base.gcno"
    if [ ! -f "$gcno" ]; then
        echo "  FATAL: no coverage data for $src (expected $gcno) — is it in Makefile's LIB_SRC and this script's SOURCES list?"
        fail=1
        continue
    fi

    out=$(gcov -b -o "$COVDIR" "$gcno" 2>/dev/null || true)

    line_pct=$(printf '%s\n' "$out" | grep '^Lines executed:' | head -1 | sed -E 's/Lines executed:([0-9.]+)% of ([0-9]+)/\1 \2/')
    branch_line=$(printf '%s\n' "$out" | grep '^Branches executed:' | head -1)

    line_frac=$(printf '%s\n' "$line_pct" | cut -d' ' -f1)
    line_total=$(printf '%s\n' "$line_pct" | cut -d' ' -f2)
    line_hit=$(awk -v p="$line_frac" -v n="$line_total" 'BEGIN{printf "%d", (p/100.0)*n + 0.5}')

    if [ -n "$branch_line" ]; then
        branch_pct=$(printf '%s\n' "$branch_line" | sed -E 's/Branches executed:([0-9.]+)% of ([0-9]+)/\1 \2/')
        branch_frac=$(printf '%s\n' "$branch_pct" | cut -d' ' -f1)
        branch_total=$(printf '%s\n' "$branch_pct" | cut -d' ' -f2)
        branch_hit=$(awk -v p="$branch_frac" -v n="$branch_total" 'BEGIN{printf "%d", (p/100.0)*n + 0.5}')
    else
        branch_frac="0.00"
        branch_total=0
        branch_hit=0
    fi

    printf "  %-40s lines %6s%% (%s/%s)   branches %6s%% (%s/%s)\n" \
        "$src" "$line_frac" "$line_hit" "$line_total" "$branch_frac" "$branch_hit" "$branch_total"

    total_lines=$((total_lines + line_total))
    total_lines_hit=$((total_lines_hit + line_hit))
    total_branches=$((total_branches + branch_total))
    total_branches_hit=$((total_branches_hit + branch_hit))

    case "$base" in
        buf|ver)
            if [ "$line_hit" -ne "$line_total" ]; then
                echo "  FATAL: $src requires 100% line coverage, got $line_frac% ($line_hit/$line_total)"
                fail=1
            fi
            ;;
    esac
done

rm -f ./*.c.gcov

overall_line_pct=$(awk -v h="$total_lines_hit" -v t="$total_lines" 'BEGIN{ if (t==0) print 0; else printf "%.2f", (h/t)*100 }')
overall_branch_pct=$(awk -v h="$total_branches_hit" -v t="$total_branches" 'BEGIN{ if (t==0) print 0; else printf "%.2f", (h/t)*100 }')

echo ""
echo "overall: lines $total_lines_hit/$total_lines ($overall_line_pct%), branches $total_branches_hit/$total_branches ($overall_branch_pct%)"

if awk -v p="$overall_line_pct" -v t="$LINE_THRESHOLD" 'BEGIN{exit !(p+0 < t)}'; then
    echo "FATAL: line coverage $overall_line_pct% is below the $LINE_THRESHOLD% threshold"
    fail=1
fi
if awk -v p="$overall_branch_pct" -v t="$BRANCH_THRESHOLD" 'BEGIN{exit !(p+0 < t)}'; then
    echo "FATAL: branch coverage $overall_branch_pct% is below the $BRANCH_THRESHOLD% threshold"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo ""
    echo "COVERAGE GATE FAILED"
    exit 1
fi
echo "coverage gate passed"
