#!/usr/bin/env bash
# `-o -` must write to standard output, and no invocation may leave
# stray files in the caller's directory.
#
# Why this exists
# ---------------
# zig 0.13 produces output atomically: a temporary file renamed onto the
# -o path. Given `-o -` it therefore creates a literal file named "-" in
# the current directory, and given `-o /dev/stdout` it renames over the
# device and the caller reads nothing. gcc and clang both write to
# standard output.
#
# CMake's CXX-DetectStdlib step preprocesses with `-o -`, so every
# configure through these wrappers dropped a file called "-" wherever it
# ran. One of them landed in this repository and was committed. The
# caller also got empty output where it expected a preprocessed source,
# which is the quieter half of the bug.
#
# Two properties are checked, because either alone would have missed it:
# the output has to arrive on stdout, and the directory has to stay
# clean.
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
printf 'int probe_value(void){ return 7; }\n' >"$PROBE/probe.c"
cp "$PROBE/probe.c" "$PROBE/probe.cpp"

for tool_lang in "zig-cc:c" "zig-c++:cpp"; do
    tool="${REPO_ROOT}/onebin/toolchain/${tool_lang%:*}"
    ext="${tool_lang##*:}"

    for mode in -E -S; do
        # Run from inside the probe directory: a stray file appears in
        # the *current* directory, so the test has to have one of its own
        # to watch.
        out=$(cd "$PROBE" && "$tool" "$mode" "probe.$ext" -o - 2>/dev/null)

        if [ -z "$out" ]; then
            printf '%s %s -o - produced nothing on stdout\n' \
                "${tool_lang%:*}" "$mode" >&2
            exit 1
        fi

        if [ -e "$PROBE/-" ]; then
            printf '%s %s -o - created a file named "-" instead of writing\n' \
                "${tool_lang%:*}" "$mode" >&2
            printf 'to stdout. That file follows the working directory, and\n' >&2
            printf 'one of them has already been committed to this repo.\n' >&2
            rm -f "$PROBE/-"
            exit 1
        fi
    done
done

# The repository itself must be free of one, since that is how the last
# one was noticed: by a human reading the file list, long after.
if [ -e "${REPO_ROOT}/-" ]; then
    printf 'a file named "-" exists at the repository root\n' >&2
    exit 1
fi

printf 'compiler wrappers: -o - reaches stdout and leaves no stray file\n'
