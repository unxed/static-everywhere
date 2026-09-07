#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export XDG_DATA_DIRS="$ROOT/share${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"
export LD_LIBRARY_PATH="$ROOT/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$ROOT/bin/konsole" "$@"
