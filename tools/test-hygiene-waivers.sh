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

# The wrapper reads the audited file (for OB0061 classification it runs
# `strings` on it) and writes <file>.audit.txt beside it, so the argument
# must be a real file. Its contents matter only for the OB0061 cases,
# which set them explicitly.
: >"$PROBE/fake-bin"

ob() {  # $1 = subject
    printf '{"id":"OB0060","check":"hygiene.buildpath","severity":"warn","subject":"%s"}' "$1"
}

# shellcheck disable=SC2317  # used by the OB0061 cases below
ob61() {  # $1 = subject
    printf '{"id":"OB0061","check":"hygiene.toolchainpath","severity":"warn","subject":"%s"}' "$1"
}
ob61() {  # a toolchain-path finding; subject is truncated/garbage by design
    printf '{"id":"OB0061","check":"hygiene.toolchainpath","severity":"warn","subject":"MediaInfo: ...garbage..."}'
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

# 3c. OB0061 whose toolchain substrings in the BINARY are all .so load
# paths (goffi's dlopen targets) is waived: the binary really loads those
# libraries by those paths, so they are functional, not build leaks. The
# wrapper reads the binary itself rather than the finding's subject,
# which onebin truncates out of Go's glued string pool -- so the stub
# binary has to carry the strings for this to mean anything.
printf 'random padding /usr/lib/x86_64-linux-gnu/libX11.so.6 more padding\n' \
    >"$PROBE/fake-bin"
printf '[%s]' "$(ob61 'glued go string pool with a load path inside')" \
    | write_report 0
run >/dev/null 2>&1 || { printf 'a functional dlopen path in OB0061 was not waived\n' >&2; exit 1; }

# 3d. ...but a toolchain substring that is NOT a shared object -- an -L
# directory, a compiler prefix -- is a genuine leak and must still fail.
printf 'padding /usr/lib/x86_64-linux-gnu/../include and /opt/rh/devtoolset/root\n' \
    >"$PROBE/fake-bin"
printf '[%s]' "$(ob61 'glued go string pool with a toolchain dir inside')" \
    | write_report 0
if leak_out=$(run 2>&1); then
    printf 'a real toolchain leak in OB0061 was wrongly waived\n' >&2
    exit 1
fi
# And it must fail for the RIGHT reason. Failing as "STALE WAIVER" would
# be the same exit code pointing at the opposite diagnosis, sending
# whoever reads the log to delete a waiver instead of fixing a leak.
printf '%s' "$leak_out" | grep -Fq 'not library-load paths' \
    || { printf 'the OB0061 leak failed for the wrong reason:\n%s\n' "$leak_out" >&2; exit 1; }
: >"$PROBE/fake-bin"

# 3e. the wrapper must leave a readable report next to the audited file,
# because CI does not capture its stderr -- without this a failing audit
# says only that it failed.
rm -f "$PROBE/fake-bin.audit.txt"
printf '[%s]' "$(ob '/home/runner/.conan2/p/q/s/src/qtbase/x.cpp')" | write_report 0
run >/dev/null 2>&1 || true
[ -s "$PROBE/fake-bin.audit.txt" ] \
    || { printf 'no .audit.txt report was written beside the binary\n' >&2; exit 1; }
grep -q 'OB0060' "$PROBE/fake-bin.audit.txt" \
    || { printf 'the report does not list the findings\n' >&2; exit 1; }

# 4. no OB0060 at all -> STALE WAIVER
printf '[]' | write_report 0
if out=$(run 2>&1); then
    printf 'a stale waiver was not reported; the tolerance would live forever\n' >&2
    exit 1
fi
printf '%s' "$out" | grep -Fq 'STALE WAIVER' \
    || { printf 'stale waiver did not name itself\n' >&2; exit 1; }

# 5. OB0061 whose real occurrence in the binary IS a .so load path ->
#    tolerated. The subject is garbage (truncated), so the wrapper must
#    decide from the binary, not the subject.
printf '/usr/lib/x86_64-linux-gnu/libX11.so.6 goffi-loads-this' >"$PROBE/fake-bin"
printf '[%s]' "$(ob61)" | write_report 0
run >/dev/null 2>&1 || {
    printf 'an OB0061 that is a real .so load path was not tolerated\n' >&2; exit 1; }

# 6. OB0061 whose real occurrence is NOT a .so path (a genuine -L / .o
#    leak) -> must fail, even though the finding id is the same.
printf '/usr/lib/x86_64-linux-gnu/gcc/12/crtbegin.o a real leak' >"$PROBE/fake-bin"
printf '[%s]' "$(ob61)" | write_report 0
if run >/dev/null 2>&1; then
    printf 'a genuine toolchain leak was waived as if it were a load path\n' >&2
    exit 1
fi
: >"$PROBE/fake-bin"  # restore empty for any later use

printf 'hygiene waivers: OB0060 + OB0061 scoped to third-party, leaks fail, stale caught\n'
