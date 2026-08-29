#!/usr/bin/env bash
# Build gt-probe -- the GNOME Terminal dependency load probe.
#
# Deliberately separate from any GNOME Terminal build. The probe exists to be
# runnable in seconds against whatever GTK/VTE is available, so that the
# expensive build is only ever started once the cheap question has an answer.
#
# --toolchain host   (default) build against the machine's own dev packages.
#                    This is the measurement mode: it tells you what a GNOME
#                    Terminal *does* pull in, which is the input to a bundled
#                    build, not its output.
# --toolchain zig    build against the pinned glibc baseline through
#                    onebin/toolchain/zig-cc. Same source, Profile H flags.
#
# --print-plan prints every command without running any, which is what
# tools/preflight-gnome-terminal.sh asserts against -- same contract as
# tools/build-f4-qt.sh, for the same reason: mistakes in the command line are
# findable in one second instead of at minute ninety.

set -uo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

SRC="${REPO_ROOT}/contrib/gnome-terminal/probe/gt-probe.c"
OUT="${REPO_ROOT}/out/gnome-terminal"
TOOLCHAIN=host
BASELINE=2.28
PRINT_PLAN=0

# The pkg-config modules are GNOME Terminal's own, taken from the DT_NEEDED of
# the shipped gnome-terminal-server rather than from its meson.build: the
# meson file lists what upstream asks for, the binary shows what it got.
PC_MODULES=(vte-2.91 gtk+-3.0 libhandy-1 gio-2.0 pangocairo uuid)

while [ $# -gt 0 ]; do
    case "$1" in
        --toolchain) TOOLCHAIN="$2"; shift 2 ;;
        --out)       OUT="$2"; shift 2 ;;
        --baseline)  BASELINE="$2"; shift 2 ;;
        --print-plan) PRINT_PLAN=1; shift ;;
        --help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "build-gt-probe.sh: unknown argument: $1" >&2; exit 2 ;;
    esac
done

case "$TOOLCHAIN" in
    host|zig) ;;
    *) echo "build-gt-probe.sh: --toolchain must be host or zig" >&2; exit 2 ;;
esac

# Fail fast, and say exactly which module is missing and what provides it.
# A pkg-config failure buried in a compiler error is the single most common
# way this kind of script wastes somebody's afternoon.
if [ "$PRINT_PLAN" = 0 ]; then
    MISSING=()
    for m in "${PC_MODULES[@]}"; do
        pkg-config --exists "$m" 2>/dev/null || MISSING+=("$m")
    done
    if [ "${#MISSING[@]}" -gt 0 ]; then
        echo "build-gt-probe.sh: missing pkg-config modules: ${MISSING[*]}" >&2
        echo "  on Debian/Ubuntu: apt-get install libvte-2.91-dev libgtk-3-dev \\" >&2
        echo "                                    libhandy-1-dev uuid-dev" >&2
        exit 2
    fi
fi

CFLAGS_PKG=$(pkg-config --cflags "${PC_MODULES[@]}" 2>/dev/null)
LIBS_PKG=$(pkg-config --libs "${PC_MODULES[@]}" 2>/dev/null)

if [ "$TOOLCHAIN" = zig ]; then
    CC="${REPO_ROOT}/onebin/toolchain/zig-cc"
    TARGET_FLAGS=(-target "x86_64-linux-gnu.${BASELINE}")
else
    CC="${CC:-cc}"
    TARGET_FLAGS=()
fi

# -rdynamic is NOT passed, and that is a decision rather than an omission.
# probe report I §A2: an executable that exports its own symbols has host
# modules bind to its statically linked copies, sharing mutable state. GNOME
# Terminal has no plugin ABI, so it never needs to export anything, and the
# probe should be built the way the real thing should be.
CMD=("$CC" "${TARGET_FLAGS[@]}"
     -O2 -g0 -Wall -Wextra
     -fPIE -pie
     -Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack
     -Wl,--as-needed
     $CFLAGS_PKG
     "$SRC"
     -o "${OUT}/gt-probe"
     $LIBS_PKG)

if [ "$PRINT_PLAN" = 1 ]; then
    echo "mkdir -p ${OUT}"
    # The module list, printed as itself. The compile line below carries only
    # pkg-config's *expanded* output, so asserting "the probe still links GTK3"
    # against it matched -I/usr/include/libhandy-1 and missed gtk+-3.0
    # entirely -- caught by tools/preflight-gnome-terminal.sh on its first run,
    # which is exactly the class of mistake --print-plan exists to surface.
    echo "pkg-config --cflags --libs ${PC_MODULES[*]}"
    echo "${CMD[*]}"
    echo "${OUT}/gt-probe --contract ${REPO_ROOT}/contrib/gnome-terminal/probe/host-contract.txt --report ${OUT}/gt-probe-report.txt"
    echo "${REPO_ROOT}/tools/audit.sh ${OUT}/gt-probe ${BASELINE}"
    exit 0
fi

mkdir -p "$OUT"
echo "== building gt-probe (--toolchain ${TOOLCHAIN}) =="
if ! "${CMD[@]}"; then
    echo "build-gt-probe.sh: compile failed" >&2
    exit 1
fi
echo "  -> ${OUT}/gt-probe"
