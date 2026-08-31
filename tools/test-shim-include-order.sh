#!/usr/bin/env bash
# A force-included shim that overrides a libc header must be included
# AFTER that header, not instead of it.
#
# Why this exists
# ---------------
# Profile U far2l force-includes SoLo's lib/dlfcn.h to redirect dlopen
# and friends to SoLo's static loader. Included on its own it came first,
# so the libc header had not yet defined _DLFCN_H, SoLo defined Dl_info,
# and far2l's utils/include/debug.h then pulled in <dlfcn.h>, which
# defined the same typedef again:
#
#   generic-musl/dlfcn.h:33:3: error: typedef redefinition with different
#                              types ('struct Dl_info' vs 'struct Dl_info')
#
# SoLo's header says plainly how it expects to be used: it opens with
# `#undef RTLD_LAZY` and friends before redefining them, and guards its
# own Dl_info with `#if !defined(_DLFCN_H)`. Both are only meaningful if
# the libc header was read first. The fix is ordering, not a new guard.
#
# This is a class, not one bug: any shim that redefines libc macros or
# types has the same requirement, and the failure always surfaces in
# whichever unrelated source file happens to include the real header.
set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
HOOK="${REPO_ROOT}/onebin/toolchain/onebin-profile-u-far2l.cmake"
CXX="${REPO_ROOT}/onebin/toolchain/zig-c++"

# 1. Structural: the hook must force-include the libc header before the
#    SoLo one. Checked on the file because the ordering is the fix.
python3 - "$HOOK" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r'target_compile_options\([^)]*?-include[^)]*?\)', text, re.S)
if not m:
    sys.exit('the far2l hook no longer force-includes anything')
block = m.group(0)
libc = block.find('"dlfcn.h"')
solo = block.find('_solo_header')
if libc == -1:
    sys.exit('the libc <dlfcn.h> is not force-included before the SoLo shim;\n'
             'SoLo will define Dl_info first and the next translation unit\n'
             'that includes <dlfcn.h> will fail to compile')
if solo == -1:
    sys.exit('the SoLo shim is no longer force-included')
if libc > solo:
    sys.exit('the SoLo shim is force-included before the libc header;\n'
             'that is the ordering that caused the Dl_info redefinition')
PY

# 2. Behavioural: reproduce the failure and the fix against the real
#    compiler. Uses a stand-in with SoLo's documented shape when the real
#    SoLo tree is not present, since this must run without network.
if ! command -v zig >/dev/null 2>&1; then
    printf 'zig unavailable; structural check only\n'
    exit 0
fi

PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT

SHIM="${ONEBIN_SOLO_ROOT:-}/lib/dlfcn.h"
if [ ! -f "$SHIM" ]; then
    SHIM="$PROBE/shim.h"
    cat >"$SHIM" <<'EOF'
#pragma once
/* Same shape as SoLo's lib/dlfcn.h: undef the libc macros, redefine
   them, and only declare Dl_info when the libc header has not. */
#undef RTLD_LAZY
#undef RTLD_NOW
#define RTLD_LAZY 1
#define RTLD_NOW 2
#if !defined(COMPILE_DLOPEN)
#  define dlopen stub_dlopen
#  define dlsym  stub_dlsym
#endif
#if defined(__cplusplus)
extern "C" {
#endif
#if !defined(_DLFCN_H)
typedef struct {
    const char *dli_fname;
    void *dli_fbase;
    const char *dli_sname;
    void *dli_saddr;
} Dl_info;
#endif
void *stub_dlopen(const char *, int);
void *stub_dlsym(void *, const char *);
#if defined(__cplusplus)
}
#endif
EOF
fi

# A translation unit shaped like far2l's: it includes <dlfcn.h> itself,
# exactly as utils/include/debug.h does.
cat >"$PROBE/tu.cpp" <<'EOF'
#include <dlfcn.h>
int main() {
    Dl_info info;
    void *h = dlopen("libc.so.6", RTLD_LAZY);
    (void)info; (void)h;
    return 0;
}
EOF

# The correct order compiles.
"$CXX" -target x86_64-linux-musl \
    -include dlfcn.h -include "$SHIM" \
    -c "$PROBE/tu.cpp" -o "$PROBE/tu.o" 2>"$PROBE/ok.log" \
    || { printf 'the libc-first ordering does not compile:\n' >&2
         sed 's/^/  /' "$PROBE/ok.log" >&2; exit 1; }

# And the shim still wins: the call must go to the stub, not to libc.
if command -v nm >/dev/null 2>&1; then
    nm -u "$PROBE/tu.o" 2>/dev/null | grep -q 'stub_dlopen' \
        || { printf 'the shim no longer redirects dlopen; ordering fixed the\n' >&2
             printf 'collision but defeated the point of the shim\n' >&2; exit 1; }
fi

# Negative control: the shim-first order must fail, or this test proves
# nothing about the ordering it just asserted.
if "$CXX" -target x86_64-linux-musl \
        -include "$SHIM" \
        -c "$PROBE/tu.cpp" -o "$PROBE/bad.o" 2>/dev/null; then
    printf 'the shim-first ordering compiled; this test can no longer tell\n' >&2
    printf 'the two orderings apart and would not have caught the CI failure\n' >&2
    exit 1
fi

printf 'shim ordering: libc header first, shim second, redirection intact\n'
