#!/usr/bin/env bash
# Regression test for relocated KDE MODULE plugin discovery.
# KWindowSystem asks Qt for libraryPaths() and searches each one for
# kf6/kwindowsystem. The launcher must make the copied bundle's plugin root
# authoritative while retaining an inherited path for ordinary integrations.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT

mkdir -p "$PROBE/runtime/bin"
cp "$REPO_ROOT/contrib/konsole/konsole-launcher.sh" "$PROBE/runtime/konsole"
chmod 755 "$PROBE/runtime/konsole"
cat >"$PROBE/runtime/bin/konsole" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${KONSOLE_LAUNCHER_PROBE:?}"
{
    printf 'QT_PLUGIN_PATH=%s\n' "${QT_PLUGIN_PATH-}"
    printf 'XDG_DATA_DIRS=%s\n' "${XDG_DATA_DIRS-}"
    printf 'LD_LIBRARY_PATH=%s\n' "${LD_LIBRARY_PATH-}"
    printf 'argv=%s\n' "$*"
} >"$KONSOLE_LAUNCHER_PROBE"
EOF
chmod 755 "$PROBE/runtime/bin/konsole"

KONSOLE_LAUNCHER_PROBE="$PROBE/environment" \
QT_PLUGIN_PATH=/inherited/qt \
XDG_DATA_DIRS=/inherited/data \
LD_LIBRARY_PATH=/inherited/lib \
    "$PROBE/runtime/konsole" --separate --hold

expected_root=$PROBE/runtime
grep -Fxq "QT_PLUGIN_PATH=$expected_root/lib/plugins:/inherited/qt" \
    "$PROBE/environment" || {
    printf 'launcher did not prepend its relocated Qt plugin root\n' >&2
    cat "$PROBE/environment" >&2
    exit 1
}
grep -Fxq "XDG_DATA_DIRS=$expected_root/share:/inherited/data" \
    "$PROBE/environment" || {
    printf 'launcher changed the XDG data path contract\n' >&2
    cat "$PROBE/environment" >&2
    exit 1
}
grep -Fxq "LD_LIBRARY_PATH=$expected_root/lib:/inherited/lib" \
    "$PROBE/environment" || {
    printf 'launcher changed the library path contract\n' >&2
    cat "$PROBE/environment" >&2
    exit 1
}
grep -Fxq 'argv=--separate --hold' "$PROBE/environment" || {
    printf 'launcher did not preserve Konsole arguments\n' >&2
    cat "$PROBE/environment" >&2
    exit 1
}

printf 'Konsole relocated KDE plugin path: PASS (launcher and inherited paths)\n'
