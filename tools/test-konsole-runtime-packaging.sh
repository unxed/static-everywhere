#!/usr/bin/env bash
# Regression guard for install-prefix MODULE layout drift.
#
# KDE projects can install loadable modules below the prefix, below lib, or
# below a Qt-style plugins directory. The runtime packager must preserve all
# of them under the single relocatable plugin root consumed by the launcher.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT

mkdir -p \
    "$PROBE/prefix/bin" \
    "$PROBE/prefix/lib/plugins/platforms" \
    "$PROBE/prefix/kf6/kwindowsystem" \
    "$PROBE/build/kf6/kwindowsystem" \
    "$PROBE/prefix/share"
cp /bin/true "$PROBE/prefix/bin/konsole"
ln -s "$PROBE/build/kf6" "$PROBE/prefix/bin/kf6"
touch \
    "$PROBE/prefix/lib/libkonsoleapp.so.26.08.0" \
    "$PROBE/prefix/lib/plugins/platforms/libqxcb.so" \
    "$PROBE/prefix/kf6/kwindowsystem/KF6WindowSystemX11Plugin.so" \
    "$PROBE/build/kf6/kwindowsystem/KF6WindowSystemX11PluginBinLayout.so"

"$REPO_ROOT/tools/package-konsole-runtime.sh" \
    "$PROBE/prefix" "$PROBE/runtime" >/dev/null

[[ -x "$PROBE/runtime/bin/konsole" ]] || {
    printf 'packager omitted the installed executable\n' >&2
    exit 1
}
[[ -f "$PROBE/runtime/lib/libkonsoleapp.so.26.08.0" ]] || {
    printf 'packager omitted an install-lib shared object\n' >&2
    exit 1
}
[[ -f "$PROBE/runtime/lib/plugins/platforms/libqxcb.so" ]] || {
    printf 'packager omitted a lib/plugins MODULE\n' >&2
    exit 1
}
[[ -f "$PROBE/runtime/lib/plugins/kf6/kwindowsystem/KF6WindowSystemX11Plugin.so" ]] || {
    printf 'packager omitted a prefix-level KDE MODULE\n' >&2
    exit 1
}
[[ -f "$PROBE/runtime/lib/plugins/kf6/kwindowsystem/KF6WindowSystemX11PluginBinLayout.so" ]] || {
    printf 'packager retained the bin prefix for a KDE MODULE\n' >&2
    exit 1
}
[[ ! -L "$PROBE/runtime/lib/plugins/kf6/kwindowsystem/KF6WindowSystemX11PluginBinLayout.so" ]] || {
    printf 'packager preserved a build-tree symlink for a KDE MODULE\n' >&2
    exit 1
}
[[ ! -e "$PROBE/runtime/lib/plugins/libkonsoleapp.so.26.08.0" ]] || {
    printf 'packager misclassified an install-lib shared object as a plugin\n' >&2
    exit 1
}

printf 'Konsole runtime packaging: PASS (all install-prefix module layouts normalized)\n'
