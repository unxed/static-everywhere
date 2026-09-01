#!/usr/bin/env bash
# Regression test for the Profile U C++ shared/module linker rule.
#
# A bare -lc++ makes Zig 0.13 add its dynamic libc.so to a musl shared link.
# Profile U modules must instead carry the target C++ archives by absolute
# path, while leaving libc unresolved for SoLo/the exported executable.
# This test uses a fake Zig to exercise the wrapper's argv transformation
# without building a product or depending on a local Zig installation.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT

printf '%s\n' \
    '#!/bin/sh' \
    'if [ "${1-}" = cc ] && [ "${2-}" = -### ]; then' \
    '    printf "%s\\n" "ld.lld /opt/zig/libc++abi.a /opt/zig/libc++.a /opt/zig/libunwind.a /opt/zig/libc.so"' \
    '    exit 0' \
    'fi' \
    'printf "<%s>\\n" "$@"' >"$PROBE/zig"
chmod +x "$PROBE/zig"

PATH="$PROBE:$PATH" "$REPO_ROOT/onebin/toolchain/zig-c++" \
    -target x86_64-linux-musl -fPIC -shared -o module.so module.o \
    -lc++ -lc++abi -lunwind >"$PROBE/out"

assert_line() {
    local expected=$1
    if ! grep -Fqx -- "$expected" "$PROBE/out"; then
        printf 'missing expected transformed argv element: %s\n' "$expected" >&2
        sed 's/^/  /' "$PROBE/out" >&2
        exit 1
    fi
}

assert_absent() {
    local unwanted=$1
    if grep -Fqx -- "$unwanted" "$PROBE/out"; then
        printf 'implicit runtime argv element survived: %s\n' "$unwanted" >&2
        sed 's/^/  /' "$PROBE/out" >&2
        exit 1
    fi
}

assert_line '<cc>'
assert_line '<-target>'
assert_line '<x86_64-linux-musl>'
assert_line '<-nolibc>'
assert_line '<-nostdlib>'
assert_line '<-static>'
assert_line '</opt/zig/libc++abi.a>'
assert_line '</opt/zig/libc++.a>'
assert_line '</opt/zig/libunwind.a>'
assert_absent '<-lc++>'
assert_absent '<-lc++abi>'
assert_absent '<-lunwind>'

printf 'musl C++ module flags: target archives carried, libc driver injection avoided\n'
