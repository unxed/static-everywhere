#!/usr/bin/env bash
# The introspection commands build systems run must actually produce
# output through these wrappers.
#
# Why this exists
# ---------------
# CMake asks the compiler for its predefined macros with
# `-dM -E -c <empty file>` and captures stdout into moc_predefs.h. That
# file is how moc learns the platform. gcc treats -E as dominant and
# prints the macros; zig 0.13 lets -c win, writes an object and prints
# nothing.
#
# Nothing complains about the resulting zero-byte moc_predefs.h. moc then
# runs without __linux__, so Q_OS_LINUX is undefined, and solid's
# fstabwatcher.h -- which declares one slot under #ifdef Q_OS_LINUX and a
# different one under #else -- got moc output calling the slot that was
# never compiled:
#
#   moc_fstabwatcher.cpp:86:21: error: no member named 'onFileChanged'
#
# Forty minutes in, in a generated file, about a macro nobody mentioned.
# This is the shape worth testing for: not a command that fails, but one
# that succeeds and returns nothing.
set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

if ! command -v zig >/dev/null 2>&1; then
    printf 'zig unavailable; skipping\n'
    exit 0
fi

PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT
: >"$PROBE/empty.cxx"
: >"$PROBE/empty.c"

for tool_lang in "zig-cc:c" "zig-c++:cxx"; do
    tool="${REPO_ROOT}/onebin/toolchain/${tool_lang%:*}"
    src="$PROBE/empty.${tool_lang##*:}"
    [ -f "$src" ] || src="$PROBE/empty.cxx"

    # Exactly CMake's CMAKE_<LANG>_COMPILER_PREDEFINES_COMMAND.
    macros=$("$tool" -target x86_64-linux-gnu.2.28 -dM -E -c "$src" 2>/dev/null \
             | wc -l)
    if [ "$macros" -lt 100 ]; then
        printf '%s -dM -E -c produced %s lines of predefined macros.\n' \
            "${tool_lang%:*}" "$macros" >&2
        printf 'CMake writes that output to moc_predefs.h; empty means moc\n' >&2
        printf 'runs with no platform macros and silently generates code for\n' >&2
        printf 'the wrong branch of a #ifdef Q_OS_LINUX.\n' >&2
        exit 1
    fi

    # The specific macro whose absence produced the solid failure.
    "$tool" -target x86_64-linux-gnu.2.28 -dM -E -c "$src" 2>/dev/null \
        | grep -q '__linux__' \
        || { printf '%s does not report __linux__; Qt derives Q_OS_LINUX\n' \
                 "${tool_lang%:*}" >&2
             printf 'from it, and moc will take the wrong branch without it\n' >&2
             exit 1; }
done

# Dropping -c must not have broken the two ordinary paths it borders on.
printf 'int probe(void){ return 0; }\n' >"$PROBE/probe.c"
"${REPO_ROOT}/onebin/toolchain/zig-cc" -target x86_64-linux-gnu.2.28 \
    -c "$PROBE/probe.c" -o "$PROBE/probe.o" 2>/dev/null \
    || { printf 'a plain -c compile no longer produces an object\n' >&2; exit 1; }
[ -s "$PROBE/probe.o" ] \
    || { printf 'a plain -c compile produced an empty object\n' >&2; exit 1; }

preprocessed=$("${REPO_ROOT}/onebin/toolchain/zig-cc" \
               -target x86_64-linux-gnu.2.28 -E "$PROBE/probe.c" 2>/dev/null \
               | wc -l)
[ "$preprocessed" -gt 0 ] \
    || { printf 'a plain -E no longer preprocesses to stdout\n' >&2; exit 1; }

printf 'compiler introspection: -dM -E -c reports macros, -c and -E still work\n'
