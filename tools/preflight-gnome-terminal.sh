#!/usr/bin/env bash
# Fast invariant checks for the GNOME Terminal reference build.
#
# Same bargain as tools/preflight-f4-qt.sh: a full static GNOME stack is a
# multi-hour build, and almost everything that can go wrong with it is either
# an assertion about a command line or a question the probe can answer in
# thirty seconds. Both are cheaper to ask here.
#
# Order matters. Cheapest and most likely to fail first:
#   1. plan-shape assertions           (no compiler needed)
#   2. gt-probe builds                 (needs the dev packages)
#   3. gt-probe's own negative controls
#   4. the probe run itself, strict    (needs a display; xvfb is enough)
#   5. the audit of the probe binary   (proves the flags produce Level 1)
#
# Each check names the failure that motivated it, per the convention in
# tools/preflight-f4-qt.sh: a check whose reason is forgotten gets deleted the
# first time it is inconvenient.

set -uo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
OUT="${REPO_ROOT}/out/gnome-terminal"
CONTRACT="${REPO_ROOT}/contrib/gnome-terminal/probe/host-contract.txt"
BASELINE=2.28

FAILED=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=$((FAILED + 1)); }
skip() { printf '  --   %s (skipped: %s)\n' "$1" "$2"; }

echo "== plan shape =="
PLAN=$(mktemp); trap 'rm -f "$PLAN"' EXIT
if ! "${REPO_ROOT}/tools/build-gt-probe.sh" --print-plan >"$PLAN" 2>&1; then
    fail "build-gt-probe.sh --print-plan"
    sed 's/^/       /' "$PLAN"
else
    pass "$(wc -l <"$PLAN") plan steps render"
fi

# The pkg-config module list is derived from the shipped binary's DT_NEEDED,
# not from upstream's meson.build. If libhandy ever drops out of that list it
# means somebody assumed GNOME Terminal is a GTK4/libadwaita application --
# which it is not, as of 3.52. That assumption would silently build a probe
# that measures the wrong dependency graph.
if grep -q 'libhandy-1' "$PLAN"; then
    pass "the probe still links libhandy-1 (GNOME Terminal is GTK3, not GTK4)"
else
    fail "libhandy-1 dropped from the probe's link line -- see contrib/gnome-terminal/deps.lock"
fi
if grep -qE 'gtk\+-3\.0' "$PLAN"; then
    pass "the probe links GTK3, matching gnome-terminal-server"
else
    fail "the probe no longer links GTK3"
fi

echo
echo "== the probe's own tests =="
if PROBE_TEST=$("${REPO_ROOT}/tools/test-gt-probe.sh" 2>&1); then
    pass "gt-probe regression tests"
    printf '%s\n' "$PROBE_TEST" | grep -c '^    ok' | xargs printf '       %s checks\n'
else
    fail "gt-probe regression tests"
    printf '%s\n' "$PROBE_TEST" | sed 's/^/       /'
fi

echo
echo "== build and run the probe =="
if ! pkg-config --exists vte-2.91 2>/dev/null; then
    skip "gt-probe build" "libvte-2.91-dev not installed"
elif ! "${REPO_ROOT}/tools/build-gt-probe.sh" >"${PLAN}.build" 2>&1; then
    fail "gt-probe does not build"
    tail -20 "${PLAN}.build" | sed 's/^/       /'
else
    pass "gt-probe builds"

    if ! command -v xvfb-run >/dev/null 2>&1; then
        skip "gt-probe run" "no xvfb-run and probably no display"
    else
        # --strict here and nowhere else. In CI there is no host
        # gnome-terminal-server, so being answered on org.gnome.Terminal means
        # something is genuinely wrong rather than merely inconvenient; and an
        # undeclared mapping is exactly the news this whole exercise exists to
        # deliver, so it should stop the build rather than scroll past.
        if dbus-run-session -- xvfb-run -a "${OUT}/gt-probe" \
               --contract "$CONTRACT" \
               --report "${OUT}/gt-probe-report.txt" \
               --strict >"${OUT}/gt-probe-stdout.txt" 2>"${OUT}/gt-probe-stderr.txt"; then
            pass "$(grep -o '[0-9]* passed, [0-9]* failed, [0-9]* warnings' "${OUT}/gt-probe-report.txt" | tail -1)"
        else
            fail "gt-probe --strict"
            # Whole sections, not a keyword grep. gt-probe lists undeclared
            # sonames indented and without any keyword, so the grep this
            # replaced printed the count and none of the names -- leaving the
            # reader to re-run the job to find out what had drifted. See
            # tools/gt-report-summary.sh.
            "${REPO_ROOT}/tools/gt-report-summary.sh" \
                "${OUT}/gt-probe-report.txt" 2>&1 | sed 's/^/       /'
        fi
    fi

    # The probe is built with the flags a conforming binary needs, so it must
    # itself pass the audit. This is the cheapest possible end-to-end check
    # that the flag set in build-gt-probe.sh actually produces Level 1
    # hardening, rather than merely containing the right-looking strings --
    # which is all the plan-shape check above can prove.
    if [ ! -x "${REPO_ROOT}/tools/audit.sh" ]; then
        skip "audit of gt-probe" "tools/audit.sh not executable"
    else
        AUD=$("${REPO_ROOT}/tools/audit.sh" "${OUT}/gt-probe" "$BASELINE" 2>&1)
        # Profile H expects a GUI application to carry host libraries, so a
        # DT_NEEDED complaint here is expected and not a failure; RELRO,
        # BIND_NOW and PIE are not negotiable and are what we look at.
        if printf '%s\n' "$AUD" | grep -qiE 'no *relro|bind_now.*(missing|no)|not.*pie'; then
            fail "gt-probe misses a hardening property"
            printf '%s\n' "$AUD" | sed 's/^/       /' | head -20
        else
            pass "gt-probe is PIE with RELRO and BIND_NOW"
        fi
    fi
fi

echo
echo "== repository test suite =="
if make -sC "${REPO_ROOT}/onebin" test >/tmp/onebin-test-gt.log 2>&1; then
    pass "$(tail -n1 /tmp/onebin-test-gt.log | tr -d '\n')"
else
    fail "onebin test suite"
    grep -E '^\s+FAIL' /tmp/onebin-test-gt.log | sed 's/^/       /'
fi

echo
if [ "$FAILED" -eq 0 ]; then
    echo "preflight: all checks passed"
    exit 0
fi
echo "preflight: ${FAILED} check(s) failed -- not worth starting the GNOME stack build"
exit 1
