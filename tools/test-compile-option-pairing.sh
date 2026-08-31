#!/usr/bin/env bash
# Paired compile options must be passed as SHELL: units.
#
# Why this exists
# ---------------
# CMake de-duplicates compile options. Written as four plain arguments,
#
#     target_compile_options(t PRIVATE "-include" "a.h" "-include" "b.h")
#
# the second "-include" is dropped as a repeat and its filename is left
# behind as a bare argument, which the driver then treats as an input
# file. Verified against cmake 3.31, which generates exactly:
#
#     CXX_FLAGS = -include /tmp/dedup/a.h /tmp/dedup/b.h
#
# A .h input is a C header, so a C++ compile then dies with
#
#     error: invalid argument '-std=c++17' not allowed with 'C'
#
# which names neither the option that was dropped nor the file that
# became an input. That is what makes this class worth a test: the
# symptom points at an unrelated flag, in an unrelated target, and the
# cause is invisible in the source that caused it.
#
# `SHELL:` exists for exactly this: it keeps an option and its argument
# together as one unit and exempts the pair from de-duplication.
set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

# 1. Static sweep: no cmake file in this repository may pass a repeated
#    separate-argument option to target_compile_options. Checked over the
#    sources rather than one known site, because the next one will be
#    written somewhere else.
python3 - "$REPO_ROOT" <<'PY'
import pathlib, re, sys

root = pathlib.Path(sys.argv[1])
# Options that take a separate argument and are therefore lost to
# de-duplication when repeated.
PAIRED = ('-include', '-isystem', '-Xclang', '-imacros', '-idirafter', '-U')
bad = []

for path in list(root.rglob('*.cmake')) + list(root.rglob('CMakeLists.txt')):
    if '/.git/' in str(path) or '/far2l-src/' in str(path):
        continue
    text = path.read_text(errors='replace')
    for call in re.finditer(r'target_compile_options\s*\((.*?)\)', text, re.S):
        body = call.group(1)
        for opt in PAIRED:
            # A bare "-include" argument, i.e. not inside a SHELL: unit.
            bare = re.findall(r'"' + re.escape(opt) + r'"', body)
            if len(bare) > 1:
                bad.append((path.relative_to(root), opt, len(bare)))

if bad:
    print('paired compile options passed as separate arguments and repeated;')
    print('CMake will de-duplicate the option and turn its argument into an')
    print('input file. Use "SHELL:<opt> <arg>" for each pair instead:')
    for path, opt, n in bad:
        print(f'  {path}: {opt} appears {n} times as a bare argument')
    sys.exit(1)
PY

# 2. Behavioural: prove the claim against the real cmake, so the rule
#    above is not folklore. Skips if cmake or a compiler is unavailable.
if ! command -v cmake >/dev/null 2>&1 || ! command -v zig >/dev/null 2>&1; then
    printf 'cmake or zig unavailable; static sweep only\n'
    exit 0
fi

PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT
printf '#pragma once\n' >"$PROBE/a.h"
printf '#pragma once\n' >"$PROBE/b.h"
printf 'int main(){return 0;}\n' >"$PROBE/m.cpp"

emit_project() {  # $1 = the target_compile_options body
    cat >"$PROBE/CMakeLists.txt" <<EOF
cmake_minimum_required(VERSION 3.16)
project(dedup CXX)
add_executable(app m.cpp)
target_compile_options(app PRIVATE $1)
EOF
}

flags_of() {  # configure and print the generated CXX_FLAGS line
    rm -rf "$PROBE/build"
    cmake -S "$PROBE" -B "$PROBE/build" \
        -DCMAKE_CXX_COMPILER="${REPO_ROOT}/onebin/toolchain/zig-c++" \
        >/dev/null 2>&1 || return 1
    grep -h '^CXX_FLAGS' "$PROBE/build/CMakeFiles/app.dir/flags.make" 2>/dev/null
}

# The broken form must lose one option.
emit_project '"-include" "'"$PROBE"'/a.h" "-include" "'"$PROBE"'/b.h"'
plain=$(flags_of) || { printf 'the probe project did not configure\n' >&2; exit 1; }
if [ "$(printf '%s' "$plain" | grep -o -- '-include' | wc -l)" -ne 1 ]; then
    printf 'cmake no longer de-duplicates repeated compile options.\n' >&2
    printf 'That is good news, but this test now proves nothing; check\n' >&2
    printf 'whether SHELL: is still required before relaxing the sweep.\n' >&2
    printf '  got: %s\n' "$plain" >&2
    exit 1
fi

# The SHELL: form must keep both.
emit_project '"SHELL:-include '"$PROBE"'/a.h" "SHELL:-include '"$PROBE"'/b.h"'
shell=$(flags_of) || { printf 'the SHELL: probe did not configure\n' >&2; exit 1; }
if [ "$(printf '%s' "$shell" | grep -o -- '-include' | wc -l)" -ne 2 ]; then
    printf 'SHELL: did not preserve both option pairs:\n  %s\n' "$shell" >&2
    exit 1
fi

printf 'compile-option pairing: SHELL: used everywhere, and it is still needed\n'
