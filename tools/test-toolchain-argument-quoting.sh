#!/usr/bin/env bash
# Regression test for the zig compiler wrappers' argv filtering.
#
# The wrappers must remove a few linker flags, but must not turn one compiler
# argument containing spaces into several arguments. A fake zig executable
# makes the test independent of a local Zig installation.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT

printf '%s\n' '#!/bin/sh' 'printf "<%s>\n" "$@"' >"$PROBE/zig"
chmod +x "$PROBE/zig"

assert_line() {
    local expected=$1
    local output=$2
    if ! grep -Fqx -- "$expected" "$output"; then
        printf 'missing expected argv element: %s\n' "$expected" >&2
        sed 's/^/  /' "$output" >&2
        exit 1
    fi
}

assert_absent() {
    local unwanted=$1
    local output=$2
    if grep -Fqx -- "$unwanted" "$output"; then
        printf 'filtered argv element survived: %s\n' "$unwanted" >&2
        sed 's/^/  /' "$output" >&2
        exit 1
    fi
}

DESC='-DTOOL_DESC="QMSetup Core Utility Command, Version 1.1.1.0"'
COPYRIGHT='-DTOOL_COPYRIGHT="Copyright 2023-present Stdware Collections, checkout https://github.com/stdware/qmsetup"'

PATH="$PROBE:$PATH" "$REPO_ROOT/onebin/toolchain/zig-c++" \
    -target x86_64-linux-gnu.2.27 "$DESC" "$COPYRIGHT" \
    -shared -pie -Wl,--exclude-libs,ALL -Wl,-rpath-link,/tmp \
    >"$PROBE/cxx.out"
assert_line '<c++>' "$PROBE/cxx.out"
assert_line "<$DESC>" "$PROBE/cxx.out"
assert_line "<$COPYRIGHT>" "$PROBE/cxx.out"
assert_line '<-target>' "$PROBE/cxx.out"
assert_line '<x86_64-linux-gnu.2.27>' "$PROBE/cxx.out"
assert_absent '<-pie>' "$PROBE/cxx.out"
assert_absent '<-Wl,--exclude-libs,ALL>' "$PROBE/cxx.out"
assert_absent '<-Wl,-rpath-link,/tmp>' "$PROBE/cxx.out"

PATH="$PROBE:$PATH" "$REPO_ROOT/onebin/toolchain/zig-cc" \
    -target x86_64-linux-gnu.2.27 -E -c "$DESC" "$COPYRIGHT" \
    -shared -pie -Wl,--exclude-libs,ALL -Wl,-rpath-link,/tmp \
    >"$PROBE/cc.out"
assert_line '<cc>' "$PROBE/cc.out"
assert_line "<$DESC>" "$PROBE/cc.out"
assert_line "<$COPYRIGHT>" "$PROBE/cc.out"
assert_line '<-E>' "$PROBE/cc.out"
assert_absent '<-c>' "$PROBE/cc.out"
assert_absent '<-pie>' "$PROBE/cc.out"
assert_absent '<-Wl,--exclude-libs,ALL>' "$PROBE/cc.out"
assert_absent '<-Wl,-rpath-link,/tmp>' "$PROBE/cc.out"

PATH="$PROBE:$PATH" "$REPO_ROOT/onebin/toolchain/zig-c++" \
    -target x86_64-linux-gnu.2.27 -rdynamic "$DESC" \
    -Wl,--exclude-libs,ALL >"$PROBE/export.out"
assert_line '<-rdynamic>' "$PROBE/export.out"
assert_line '<-Wl,--exclude-libs,ALL>' "$PROBE/export.out"

printf 'toolchain wrapper argv quoting: pass\n'
