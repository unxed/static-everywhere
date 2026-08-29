#!/usr/bin/env bash
# Regression tests for gt-probe and its contract file.
#
# A probe that cannot fail is not a measurement. Every check here is a negative
# control: it breaks something on purpose and requires gt-probe to notice. The
# f4-qt preflight learned this the expensive way -- see the note there about
# grepping for "rev-parse HEAD" and happily accepting "rev-parse HEADX".
#
# Needs no display and no network: the two checks that would need a display are
# skipped rather than faked, because a check that silently passes without doing
# its work is worse than no check (tools/preflight-f4-qt.sh, same rule).

set -uo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
CONTRACT="${REPO_ROOT}/contrib/gnome-terminal/probe/host-contract.txt"
PROBE="${REPO_ROOT}/out/gnome-terminal/gt-probe"
FAILED=0
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

t_ok()   { printf '    ok   %s\n' "$1"; }
t_fail() { printf '    FAIL %s\n' "$1"; FAILED=$((FAILED+1)); }

# ---- static checks: no probe binary needed -------------------------------

# The contract file is the deliverable, not the probe. A malformed line is
# silently ignored by the parser, so check the shape here instead.
BADLINE=$(grep -vE '^[[:space:]]*(#|$)' "$CONTRACT" | grep -vE '^(require|allow)[[:space:]]+[A-Za-z0-9_.+-]+[[:space:]]*$' || true)
if [ -z "$BADLINE" ]; then
    t_ok "every contract line is 'require <soname>' or 'allow <soname>'"
else
    t_fail "malformed contract line(s):"
    printf '%s\n' "$BADLINE" | sed 's/^/         /'
fi

# The require list is what a bundled build must supply. If somebody deletes an
# entry to make a red build green, that is exactly the change we want visible,
# so the count is asserted rather than merely printed.
NREQ=$(grep -cE '^require ' "$CONTRACT")
if [ "$NREQ" -ge 16 ]; then
    t_ok "contract still requires ${NREQ} sonames"
else
    t_fail "contract requires only ${NREQ} sonames (was 16; did a failing entry get deleted?)"
fi

# libX11 must NOT be a require. It is a host-contract library; requiring it
# would make a Wayland-only run fail for no reason. Caught here rather than on
# a machine that has no X server.
if grep -qE '^require libX11' "$CONTRACT"; then
    t_fail "libX11 is listed as 'require' -- it is host contract, not our code"
else
    t_ok "libX11 stays in the host contract, not the require list"
fi

# The GPU stack must be allow-only. A 'require libGL' would turn every
# software-rendering machine into a failure, which is the exact mistake
# tools/test-optional-gl.sh exists to prevent on the f4-qt side.
if grep -qE '^require (libGL|libEGL|libgallium|libdrm)' "$CONTRACT"; then
    t_fail "a GPU library is listed as 'require'"
else
    t_ok "GPU libraries are allow-only"
fi

# ---- plan checks ---------------------------------------------------------

PLAN="${TMP}/plan.txt"
if ! "${REPO_ROOT}/tools/build-gt-probe.sh" --print-plan >"$PLAN" 2>&1; then
    t_fail "build-gt-probe.sh --print-plan failed"
    sed 's/^/         /' "$PLAN"
else
    t_ok "--print-plan renders without building"

    # probe report I §A2: exporting our own symbols is what makes host modules
    # bind to our static copies. GNOME Terminal has no plugin ABI, so there is
    # never a reason to pass -rdynamic, and its appearance would be a
    # regression with a silent, state-corrupting failure mode.
    if grep -q -- '-rdynamic' "$PLAN"; then
        t_fail "-rdynamic is back in the link line (see probe report I, A2)"
    else
        t_ok "the probe does not export its own symbols"
    fi

    for f in -z,relro -z,now -pie; do
        if grep -q -- "$f" "$PLAN"; then
            t_ok "hardening flag ${f} is in the plan"
        else
            t_fail "hardening flag ${f} missing -- audit Level 1 needs it"
        fi
    done

    if grep -q 'host-contract.txt' "$PLAN"; then
        t_ok "the plan runs the probe against the contract file"
    else
        t_fail "the plan builds the probe but never checks the contract"
    fi
fi

# --toolchain must reject anything it does not implement, rather than silently
# falling through to the host compiler and producing an artifact that looks
# baseline-pinned and is not.
if "${REPO_ROOT}/tools/build-gt-probe.sh" --toolchain nonsense --print-plan >/dev/null 2>&1; then
    t_fail "--toolchain accepts an unknown value"
else
    t_ok "--toolchain rejects unknown values"
fi

# ---- runtime negative controls: need the probe and a display -------------

if [ ! -x "$PROBE" ]; then
    printf '    --   runtime negative controls (skipped: no %s)\n' "$PROBE"
elif ! command -v xvfb-run >/dev/null 2>&1; then
    printf '    --   runtime negative controls (skipped: no xvfb-run)\n'
else
    RUN=(dbus-run-session -- xvfb-run -a "$PROBE")

    # 1. A soname that cannot possibly be mapped must fail the probe. This is
    #    the control that proves the contract check does any work at all.
    printf 'require libdefinitely-not-here.so.0\n' >"${TMP}/impossible.txt"
    if "${RUN[@]}" --contract "${TMP}/impossible.txt" >/dev/null 2>&1; then
        t_fail "probe passes with an unsatisfiable 'require' line"
    else
        t_ok "an unsatisfiable 'require' fails the probe"
    fi

    # 2. An empty contract must fail under --strict, because then everything
    #    mapped is undeclared. Proves --strict is wired to the undeclared list
    #    and not merely accepted as a flag.
    : >"${TMP}/empty.txt"
    if "${RUN[@]}" --contract "${TMP}/empty.txt" --strict >/dev/null 2>&1; then
        t_fail "--strict passes with an empty contract"
    else
        t_ok "--strict rejects an empty contract"
    fi

    # 3. ...and the same empty contract must PASS without --strict. Otherwise
    #    the two modes are the same mode and one of them is a lie.
    if "${RUN[@]}" --contract "${TMP}/empty.txt" >/dev/null 2>&1; then
        t_ok "without --strict, undeclared mappings are a warning"
    else
        t_fail "undeclared mappings are fatal even without --strict"
    fi

    # 4. A missing contract file must fail fast with the environment code (2),
    #    not be silently treated as "no contract given".
    "${RUN[@]}" --contract "${TMP}/does-not-exist.txt" >/dev/null 2>&1
    if [ $? -eq 2 ]; then
        t_ok "a missing contract file fails fast with exit 2"
    else
        t_fail "a missing contract file does not fail fast"
    fi

    # 5. The real contract must pass strictly. If this breaks, the host grew a
    #    mapping we have not accounted for -- which is information, and the
    #    reason the contract file is checked in rather than generated.
    REPORT="${TMP}/report.txt"
    if "${RUN[@]}" --contract "$CONTRACT" --report "$REPORT" --strict >/dev/null 2>&1; then
        t_ok "the checked-in contract passes --strict on this host"
    else
        t_fail "the checked-in contract no longer passes --strict"
        grep -E 'FAIL|undeclared' -A20 "$REPORT" 2>/dev/null | sed 's/^/         /' | head -30
    fi

    # 6. The report file must actually contain the report. f4-diag lost its
    #    entire "f4 output" section to a formatting bug and nobody noticed
    #    until it was needed; a written-but-empty artifact is the same failure.
    if [ -s "$REPORT" ] && grep -q 'gt-probe:' "$REPORT"; then
        t_ok "--report writes a non-empty report ($(wc -l <"$REPORT") lines)"
    else
        t_fail "--report produced no usable file"
    fi

    # 7. The probe must not warn on stderr about its own API use. The VTE
    #    search-regex multiline flag was found exactly this way: everything
    #    passed while VTE printed a runtime-check warning that the regex was
    #    never actually installed.
    ERRS="${TMP}/stderr.txt"
    "${RUN[@]}" --contract "$CONTRACT" >/dev/null 2>"$ERRS"
    SELFWARN=$(grep -E 'VTE-WARNING|Gtk-WARNING|GLib-(GObject-)?(CRITICAL|WARNING)' "$ERRS" || true)
    if [ -z "$SELFWARN" ]; then
        t_ok "the probe drives every API without a runtime-check warning"
    else
        t_fail "the probe triggers library warnings of its own:"
        printf '%s\n' "$SELFWARN" | head -4 | sed 's/^/         /'
    fi
fi

echo
if [ "$FAILED" -eq 0 ]; then
    echo "test-gt-probe: all checks passed"
    exit 0
fi
echo "test-gt-probe: ${FAILED} check(s) failed"
exit 1
