#!/usr/bin/env bash
# Regression test for the declared host GUI contract.
#
# Profile H lets a binary be static in everything except a small, named
# set of host libraries. The list lives in tools/build-f4-qt.sh as
# F4_QT_HOST_CONTRACT and is passed to the auditor as --allow flags.
#
# Two things are checked, and the second matters more than the first:
#
#   1. the mechanism works -- a real dynamic dependency is reported by
#      the auditor and cleared by naming it;
#   2. the list stays a LIST. If it ever grows a wildcard, or the audit
#      stops being --strict, the contract silently becomes "anything the
#      binary happened to need", which is the opposite of the point.
#
# What it deliberately does NOT do is assert the exact 18 sonames. That
# set legitimately shifts with Qt's xcb plugin dependencies, and pinning
# it here would turn every upstream change into a failure in the wrong
# file. The audit itself is the check on membership: a soname that
# appears without being declared fails there, loudly, which is the
# behaviour worth keeping.
set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT

ONEBIN="${REPO_ROOT}/onebin/build/onebin"
ZIGCC="${REPO_ROOT}/onebin/toolchain/zig-cc"

if ! command -v zig >/dev/null 2>&1 || [ ! -x "$ONEBIN" ]; then
    printf 'zig or onebin unavailable; skipping\n'
    exit 0
fi
if [ ! -e /usr/lib/x86_64-linux-gnu/libX11.so ]; then
    printf 'libx11-dev not installed; skipping\n'
    exit 0
fi

# A genuine dynamic dependency: the symbol has to be used, or the linker
# drops the library and the probe proves nothing.
printf 'extern void *XOpenDisplay(const char *);\nint main(void){ return XOpenDisplay(0) == 0; }\n' \
    >"$PROBE/x.c"
"$ZIGCC" -target x86_64-linux-gnu.2.27 -pie "$PROBE/x.c" -o "$PROBE/xapp" -lX11 \
    2>"$PROBE/link.log"

if ! readelf -d "$PROBE/xapp" 2>/dev/null | grep -Fq 'libX11.so.6'; then
    printf 'the probe did not end up depending on libX11 -- it proves nothing\n' >&2
    exit 1
fi

undeclared=$("$ONEBIN" audit --profile hybrid --glibc-max 2.27 --level 1 \
             --strict "$PROBE/xapp" 2>&1 | grep -c 'OB0010' || true)
if [ "$undeclared" -eq 0 ]; then
    printf 'an undeclared host dependency was not reported\n' >&2
    exit 1
fi

declared=$("$ONEBIN" audit --profile hybrid --glibc-max 2.27 --allow libX11.so.6 \
           --level 1 --strict "$PROBE/xapp" 2>&1 | grep -c 'OB0010' || true)
if [ "$declared" -ne 0 ]; then
    printf 'naming the dependency did not clear the finding\n' >&2
    exit 1
fi

# The contract must remain an enumeration, and the audit must stay strict.
if grep -q 'F4_QT_HOST_CONTRACT=.*\*' "$REPO_ROOT/tools/build-f4-qt.sh"; then
    printf 'the host contract contains a wildcard; it must name each soname\n' >&2
    exit 1
fi
# Only real plan steps: a prose mention of the command in a comment is
# not an invocation, and counting it made this check fail on its own
# documentation.
#
# EVERY hybrid audit, not merely one of them. The first version of this
# check asked whether a strict invocation existed, and there are two --
# so dropping --strict from the one that matters passed unnoticed.
total=$(grep -c 'plan_step .*audit --profile hybrid' "$REPO_ROOT/tools/build-f4-qt.sh" || true)
strict=$(grep 'plan_step .*audit --profile hybrid' "$REPO_ROOT/tools/build-f4-qt.sh" \
         | grep -c -- '--strict' || true)
if [ "$total" -eq 0 ] || [ "$total" -ne "$strict" ]; then
    printf '%s of %s hybrid audits are --strict\n' "$strict" "$total" >&2
    exit 1
fi

# And every one of them must carry the declared contract, or the audit
# would fail on libraries the project has already accounted for.
allowed=$(grep 'plan_step .*audit --profile hybrid' "$REPO_ROOT/tools/build-f4-qt.sh" \
          | grep -c 'f4_qt_allow_flags' || true)
if [ "$total" -ne "$allowed" ]; then
    printf '%s of %s hybrid audits pass the host contract\n' "$allowed" "$total" >&2
    exit 1
fi

printf 'host contract: undeclared deps fail, declared ones pass, list has no wildcard\n'
