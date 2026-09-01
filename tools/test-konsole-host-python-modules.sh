#!/usr/bin/env bash
# Verify Python modules used by KDE dependency build-time generators.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
MANIFEST="$REPO_ROOT/contrib/konsole/host-python-modules.txt"
PYTHON=${KONSOLE_HOST_PYTHON:-/usr/bin/python3}

[[ -r "$MANIFEST" ]] || {
    printf 'error: host Python module manifest is missing: %s\n' "$MANIFEST" >&2
    exit 1
}
[[ -x "$PYTHON" ]] || {
    printf 'error: host Python interpreter is missing: %s\n' "$PYTHON" >&2
    exit 1
}

checked=0
while read -r apt_package python_module extra; do
    [[ -z "${apt_package:-}" || "$apt_package" == \#* ]] && continue
    [[ -n "${python_module:-}" && -z "${extra:-}" ]] || {
        printf 'error: malformed host Python module manifest entry\n' >&2
        exit 1
    }
    "$PYTHON" - "$python_module" <<'PY'
import importlib
import sys

importlib.import_module(sys.argv[1])
PY
    printf 'PASS: %s provides Python module %s\n' "$apt_package" "$python_module"
    checked=$((checked + 1))
done < "$MANIFEST"

(( checked > 0 )) || {
    printf 'error: host Python module manifest is empty\n' >&2
    exit 1
}
