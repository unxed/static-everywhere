#!/usr/bin/env bash
# quickstart-f4-qt.sh — fully automated: clone/update static-everywhere,
# fetch/update f4, build f4-qt via the container-free zig toolchain.
#
# Everything lives under one working directory (default: a fixed path
# under /tmp, so re-running this script finds what a previous run left
# behind instead of redownloading every time). Nothing is installed
# system-wide, no root, no container. To remove everything this script
# ever touches: `rm -rf "$WORKDIR"` (printed at the end of every run).
#
# Usage:
#   ./quickstart-f4-qt.sh                 # interactive: asks what to do
#   ./quickstart-f4-qt.sh --update        # non-interactive: update + rebuild
#   ./quickstart-f4-qt.sh --fresh         # non-interactive: wipe + start over
#   ./quickstart-f4-qt.sh --rebuild       # non-interactive: rebuild only, no update
#   ./quickstart-f4-qt.sh --dir DIR       # use DIR instead of the default workdir
#
set -euo pipefail

ZIG_VERSION="0.13.0"
STATIC_EVERYWHERE_URL="https://github.com/unxed/static-everywhere.git"
F4_URL="https://github.com/Zoinen/f4"
WORKDIR="${TMPDIR:-/tmp}/static-everywhere-f4qt-build"
MODE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --update)  MODE=update; shift ;;
        --fresh)   MODE=fresh; shift ;;
        --rebuild) MODE=rebuild; shift ;;
        --dir)     WORKDIR=${2:?--dir needs a path}; shift 2 ;;
        -h|--help)
            sed -n '2,20p' "$0"
            exit 0
            ;;
        *)
            echo "error: unknown option '$1' (see --help)" >&2
            exit 2
            ;;
    esac
done

log() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

# ---------------------------------------------------------------- prompt

if [ -z "$MODE" ]; then
    if [ -d "$WORKDIR/static-everywhere" ]; then
        echo "Existing checkout found at: $WORKDIR"
        echo
        echo "What would you like to do?"
        echo "  1) Update from git and rebuild (recommended)"
        echo "  2) Rebuild only, no update (fast, if nothing upstream changed)"
        echo "  3) Start completely fresh (delete everything, redownload)"
        echo "  q) Quit without doing anything"
        printf 'Choice [1/2/3/q]: '
        read -r choice
        case "$choice" in
            1) MODE=update ;;
            2) MODE=rebuild ;;
            3) MODE=fresh ;;
            q|Q) echo "Nothing done."; exit 0 ;;
            *) echo "Unrecognized choice, defaulting to update."; MODE=update ;;
        esac
    else
        MODE=fresh
    fi
fi

if [ "$MODE" = "fresh" ] && [ -d "$WORKDIR" ]; then
    log "Removing $WORKDIR (fresh start requested)"
    rm -rf "$WORKDIR"
fi

mkdir -p "$WORKDIR"
cd "$WORKDIR"

# ------------------------------------------------------- prerequisites

for tool in git curl tar make cc; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: '$tool' not found. Install it with your host's package manager first." >&2
        exit 1
    fi
done

# --------------------------------------------------------- zig, per-user

ZIGDIR="$WORKDIR/zig-linux-x86_64-${ZIG_VERSION}"
if [ ! -x "$ZIGDIR/zig" ]; then
    log "Downloading zig ${ZIG_VERSION}"
    curl -LO "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz"
    tar xf "zig-linux-x86_64-${ZIG_VERSION}.tar.xz"
    rm -f "zig-linux-x86_64-${ZIG_VERSION}.tar.xz"
fi
export PATH="$ZIGDIR:$PATH"
log "Using $(command -v zig): $(zig version)"

# ---------------------------------------------------------- uv, per-user

if ! command -v uv >/dev/null 2>&1; then
    log "Installing uv (Python package manager; used only for an isolated Conan venv)"
    curl -LsSf https://astral.sh/uv/install.sh | sh
fi
export PATH="$HOME/.local/bin:$PATH"

# ------------------------------------------------- static-everywhere repo

if [ ! -d static-everywhere ]; then
    log "Cloning static-everywhere"
    git clone "$STATIC_EVERYWHERE_URL" static-everywhere
elif [ "$MODE" = "update" ]; then
    log "Updating static-everywhere from origin/main"
    git -C static-everywhere fetch origin
    git -C static-everywhere reset --hard origin/main
else
    log "Reusing existing static-everywhere checkout as-is (no update requested)"
fi

# ------------------------------------------------------------- build onebin

log "Building onebin (the ELF auditor)"
make -C static-everywhere/onebin

# ---------------------------------------------------------------- f4 source

# Read the pinned commit from build-f4-qt.sh itself, so this script never
# drifts out of sync with whatever static-everywhere actually expects.
PIN=$(grep -m1 '^PIN=' static-everywhere/tools/build-f4-qt.sh | sed -E 's/^PIN="([^"]+)"/\1/')
if [ -z "$PIN" ]; then
    echo "error: could not read the pinned f4 commit from build-f4-qt.sh" >&2
    exit 1
fi

if [ ! -d f4-src ]; then
    log "Cloning f4"
    git clone "$F4_URL" f4-src
    git -C f4-src checkout "$PIN"
elif [ "$MODE" = "update" ]; then
    log "Updating f4 to the pinned commit ($PIN)"
    git -C f4-src fetch origin "$PIN"
    git -C f4-src checkout "$PIN"
else
    log "Reusing existing f4 checkout as-is (no update requested)"
fi

# --------------------------------------------------------------- build f4-qt

log "Building f4-qt via the container-free zig toolchain (this is the slow part)"
static-everywhere/tools/build-f4-qt.sh \
    --config linux \
    --toolchain zig \
    --gallery off \
    --src "$WORKDIR/f4-src" \
    --out "$WORKDIR/out/f4-qt" \
    --no-fetch

log "Done"
BIN="$WORKDIR/out/f4-qt/f4"
if [ -x "$BIN" ]; then
    echo "Binary: $BIN"
else
    echo "Build finished but no binary found at the expected path -- check the log above."
fi
echo "To remove everything this script downloaded or built: rm -rf '$WORKDIR'"
