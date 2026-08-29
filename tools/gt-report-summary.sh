#!/usr/bin/env bash
# Summarise a gt-probe report for someone who has to act on a failure.
#
# Why this is its own script rather than a grep in the preflight
# ---------------------------------------------------------------
# tools/preflight-gnome-terminal.sh used to explain a failing probe with
#
#     grep -E 'FAIL|MISSING|undeclared' report.txt
#
# which prints the *count* line ("8 mapping(s) not in the contract file") and
# not one of the sonames, because gt-probe lists those indented and without any
# keyword. So the reader learned that the contract had drifted and not what it
# had drifted to, and had to re-run the job to find out -- on a run that is only
# ever triggered when something already went wrong.
#
# This is the same failure f4-qt hit when a failing audit reached us as the bare
# line "audit reports 2 error(s)" with the findings themselves lost, which is
# why the audit reports are copied into that workflow's artifact first.
#
# Sections are extracted whole, by their headings, rather than matched by
# keyword. That is the general fix: a keyword filter can only find what somebody
# thought to label, whereas gt-probe's own section structure already says which
# lines belong together.
#
# Usage: gt-report-summary.sh REPORT [--max N]
# Exit:  0 if the report was readable, 2 if it was not (fail fast).

set -uo pipefail

REPORT="${1:-}"
MAX=40
[ "${2:-}" = "--max" ] && MAX="${3:-40}"

if [ -z "$REPORT" ] || [ ! -r "$REPORT" ]; then
    echo "gt-report-summary: cannot read report: ${REPORT:-(none given)}" >&2
    exit 2
fi

# Every failing assertion, verbatim. These carry their own explanation.
if grep -qE '^  (FAIL|warn) ' "$REPORT"; then
    echo "--- failing assertions ---"
    grep -E '^  (FAIL|warn) ' "$REPORT" | head -n "$MAX"
fi

# The two sections whose content is indented and keyword-free, printed whole.
# awk rather than grep -A: the section length is not known in advance and a
# fixed -A is how you lose the tail of exactly the long list you needed.
for section in "undeclared mappings" "dlopen delta"; do
    awk -v want="$section" -v max="$MAX" '
        index($0, "== ") == 1 && index($0, want) > 0 { inside = 1; print "--- " want " ---"; next }
        inside && index($0, "== ") == 1 { inside = 0 }
        inside && NF && n < max { print; n++ }
    ' "$REPORT"
done

# The tally, always, so a summary is never silently empty.
grep -E '^== gt-probe: ' "$REPORT" | tail -1
exit 0
