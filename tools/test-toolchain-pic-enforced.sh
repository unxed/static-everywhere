#!/usr/bin/env bash
# Non-PIC code must be impossible for the glibc target, so that a shared
# MODULE (konsolepart.so) can link the static KF6 archives without
# "relocation R_X86_64_32 cannot be used when making a shared object".
#
# Why this exists
# ---------------
# BUILD-FAILURE-CLASSES.md 3.6 was closed by pinning
# CMAKE_POSITION_INDEPENDENT_CODE=ON and by the absence of relocation
# errors in one log -- an inference. The fact is stronger: zig 0.13
# refuses to compile non-PIC for x86_64-linux-gnu at all ("the selected
# target requires position independent code"), so no archive in the graph
# can contain a non-PIC object however a module's CMake is written. This
# pins that property, since a zig upgrade could silently relax it.
set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
if ! command -v zig >/dev/null 2>&1; then printf 'zig unavailable; skipping\n'; exit 0; fi

PROBE=$(mktemp -d); trap 'rm -rf "$PROBE"' EXIT
printf 'int g = 1; int f(void){ return g; }\n' >"$PROBE/np.c"

out=$("${REPO_ROOT}/onebin/toolchain/zig-cc" -target x86_64-linux-gnu.2.28 \
        -fno-pic -fno-pie -c "$PROBE/np.c" -o "$PROBE/np.o" 2>&1 || true)
if [ -f "$PROBE/np.o" ]; then
    # zig now allows it: fall back to checking the object is still PIC-safe.
    if readelf -r "$PROBE/np.o" | grep -qE 'R_X86_64_(32|32S)\b'; then
        printf 'the toolchain produced a non-PIC object for x86_64-linux-gnu; a shared\n' >&2
        printf 'MODULE linking static archives built this way will fail with\n' >&2
        printf '"relocation R_X86_64_32 cannot be used when making a shared object"\n' >&2
        exit 1
    fi
    printf 'pic: -fno-pic accepted but the object carries no absolute relocations\n'
    exit 0
fi
printf '%s' "$out" | grep -q 'requires position independent code' \
    || { printf 'expected zig to refuse non-PIC for this target; got:\n%s\n' "$out" >&2; exit 1; }
printf 'pic: zig refuses non-PIC code for x86_64-linux-gnu; class 3.6 is closed by the toolchain\n'
