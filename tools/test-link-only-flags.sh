#!/usr/bin/env bash
# Link-only flags must not change what a compile can include.
#
# Why this exists
# ---------------
# vte builds vte-urlencode-cwd with -nostdlib, which is a request about
# the *link*. gcc and clang both document it that way and ignore it when
# the driver is only compiling. zig 0.13 additionally removes the C++
# standard library include path, so:
#
#   vte/src/urlencode.cc:22:10: fatal error: 'cstdio' file not found
#
# on a translation unit that includes <cstdio> and links fine everywhere
# else. The wrappers therefore drop -nostdlib and -nodefaultlibs from
# compile-only invocations and keep them for links.
#
# Two properties, because dropping the flag everywhere would be just as
# wrong as keeping it: the compile must find its headers, and a
# freestanding link must still get no standard libraries.
set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
CC="${REPO_ROOT}/onebin/toolchain/zig-cc"
CXX="${REPO_ROOT}/onebin/toolchain/zig-c++"

if ! command -v zig >/dev/null 2>&1; then
    printf 'zig unavailable; skipping\n'
    exit 0
fi

PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT

# 1. Compiling with a link-only flag must still find standard headers.
printf '#include <cstdio>\nint probe(){ return 0; }\n' >"$PROBE/p.cc"
printf '#include <stdio.h>\nint probe(void){ return 0; }\n' >"$PROBE/p.c"

for flag in -nostdlib -nodefaultlibs; do
    "$CXX" -target x86_64-linux-gnu.2.28 "$flag" -c "$PROBE/p.cc" \
        -o "$PROBE/p.o" 2>"$PROBE/err.log" \
        || { printf 'C++ compile with %s cannot find its headers:\n' "$flag" >&2
             sed 's/^/  /' "$PROBE/err.log" >&2
             printf '  (that flag is about linking; the compile should ignore it)\n' >&2
             exit 1; }
    "$CC" -target x86_64-linux-gnu.2.28 "$flag" -c "$PROBE/p.c" \
        -o "$PROBE/pc.o" 2>"$PROBE/err.log" \
        || { printf 'C compile with %s cannot find its headers:\n' "$flag" >&2
             sed 's/^/  /' "$PROBE/err.log" >&2; exit 1; }
done

# 2. ...and the flag must still take effect when linking, or the project
#    asked for a freestanding binary and quietly got a hosted one.
printf 'void _start(void){}\n' >"$PROBE/free.c"
"$CC" -target x86_64-linux-gnu.2.28 -nostdlib "$PROBE/free.c" \
    -o "$PROBE/free" 2>"$PROBE/link.log" \
    || { printf 'a freestanding link with -nostdlib failed:\n' >&2
         sed 's/^/  /' "$PROBE/link.log" >&2; exit 1; }

if command -v readelf >/dev/null 2>&1; then
    if readelf -d "$PROBE/free" 2>/dev/null | grep -q 'Shared library'; then
        printf '-nostdlib was dropped from the LINK as well: the binary has\n' >&2
        printf 'shared library dependencies it explicitly asked not to have\n' >&2
        exit 1
    fi
fi

printf 'link-only flags: compiles keep their headers, links stay freestanding\n'
