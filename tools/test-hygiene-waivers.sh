#!/usr/bin/env bash
# Regression test for tools/audit-with-hygiene-waivers.sh.
#
# The wrapper tolerates OB0060 build-path warnings that come from
# third-party prebuilt code, and only those. That is defensible only if
# five things hold, each checked here against a stub onebin that prints a
# JSON report the case dictates:
#
#   1. a third-party OB0060 path is tolerated and the run continues;
#   2. an OB0060 path from OUR code (matching no third-party origin) is
#      NOT tolerated -- it is the regression --strict exists to catch;
#   3. any error, or any non-OB0060 warning, still fails -- the waiver is
#      scoped to third-party hygiene, nothing else;
#   4. when there are no OB0060 findings at all, the wrapper FAILS with
#      STALE WAIVER, so the tolerance cannot outlive the problem;
#   5. tolerated runs are not silent.
set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT

# A stub onebin: it ignores its arguments except the trailing --format
# json we add, and prints whatever report the current case wrote to
# $PROBE/report.json.
mkdir -p "$PROBE/bin"
cat >"$PROBE/bin/onebin" <<EOF
#!/usr/bin/env bash
cat "$PROBE/report.json"
EOF
chmod +x "$PROBE/bin/onebin"

write_report() {  # stdin = findings JSON array; $1 = error count
    local errors="${1:-0}"
    cat >"$PROBE/report.json"
    python3 - "$PROBE/report.json" "$errors" <<'PY'
import json, sys
path, errors = sys.argv[1], int(sys.argv[2])
findings = json.load(open(path))
warns = sum(1 for f in findings if f.get("severity") == "warn")
report = {"result": "fail" if (errors or warns) else "pass",
          "counts": {"error": errors, "warn": warns, "info": 0},
          "findings": findings}
json.dump(report, open(path, "w"))
PY
}

run() { "$SCRIPT_DIR/audit-with-hygiene-waivers.sh" "$PROBE/bin/onebin" \
        --profile hybrid --glibc-max 2.27 --level 1 --strict "$PROBE/fake-bin"; }

ob() {  # $1 = subject
    printf '{"id":"OB0060","check":"hygiene.buildpath","severity":"warn","subject":"%s"}' "$1"
}

# 1. third-party path -> tolerated, and announced
printf '[%s]' "$(ob '/home/runner/.conan2/p/qtXXXX/s/src/qtbase/src/widgets/w.cpp')" \
    | write_report 0
out=$(run 2>&1) || { printf 'a third-party OB0060 path was not tolerated\n' >&2
                     printf '%s\n' "$out" | sed 's/^/  /' >&2; exit 1; }
printf '%s' "$out" | grep -Fq 'waiver, not a pass' \
    || { printf 'the waiver was applied silently\n' >&2; exit 1; }

# 1b. the bare "/tmp/" prefix is waived by EXACT match...
printf '[%s]' "$(ob '/tmp/')" | write_report 0
run >/dev/null 2>&1 || { printf 'the bare /tmp/ libheif prefix was not tolerated\n' >&2; exit 1; }

# ...but a real path UNDER /tmp is not: exact match must not become a
# blanket /tmp waiver, since our own build could emit one.
printf '[%s]' "$(ob '/tmp/our-build/foo.c')" | write_report 0
if run >/dev/null 2>&1; then
    printf 'a real path under /tmp was wrongly waived by the exact-match rule\n' >&2
    exit 1
fi

# 2. our own path -> NOT tolerated
printf '[%s]' "$(ob '/home/claude/se/contrib/f4-qt/compat/something.c')" \
    | write_report 0
if run >/dev/null 2>&1; then
    printf 'an OB0060 path from our own code was wrongly waived\n' >&2
    exit 1
fi

# 3a. a non-OB0060 warning present -> must fail even with a waivable path
printf '[%s,{"id":"OB0040","severity":"warn","subject":"/x"}]' \
    "$(ob '/home/runner/.conan2/p/q/s/src/qtbase/x.cpp')" | write_report 0
if run >/dev/null 2>&1; then
    printf 'a non-OB0060 warning was masked by the hygiene waiver\n' >&2
    exit 1
fi

# 3b. an error present -> must fail
printf '[%s]' "$(ob '/home/runner/.conan2/p/q/s/src/qtbase/x.cpp')" | write_report 1
if run >/dev/null 2>&1; then
    printf 'an error was masked by the hygiene waiver\n' >&2
    exit 1
fi

# 4. no OB0060 at all -> STALE WAIVER
printf '[]' | write_report 0
if out=$(run 2>&1); then
    printf 'a stale waiver was not reported; the tolerance would live forever\n' >&2
    exit 1
fi
printf '%s' "$out" | grep -Fq 'STALE WAIVER' \
    || { printf 'stale waiver did not name itself\n' >&2; exit 1; }

printf 'hygiene waivers: third-party tolerated, ours fails, others fail, stale caught\n'
