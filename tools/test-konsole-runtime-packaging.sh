#!/usr/bin/env bash
# Regression guard for what the portable Konsole bundle carries.
#
# - Loadable modules are left out wherever the install put them (prefix
#   level, lib/plugins, a bin/ symlink into the build tree): Qt is static,
#   and a static QtCore cannot load any of them. The 36046810445 bundle
#   carried 123 MB of such modules.
# - Application shared objects at the install-lib root are kept.
# - share/ keeps relative in-tree symlinks (breeze-icons is 94% links;
#   dereferencing them made 470 MB of icons out of 9 MB), and replaces
#   absolute or escaping links by what they point at.
# - Build-time-only data in runtime-share-exclude.txt is left out.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT
fail() { printf 'Konsole runtime packaging: FAIL: %s\n' "$*" >&2; exit 1; }

share=$PROBE/prefix/share
mkdir -p \
    "$PROBE/prefix/bin" \
    "$PROBE/prefix/lib/plugins/platforms" \
    "$PROBE/prefix/kf6/kwindowsystem" \
    "$PROBE/build/kf6/kwindowsystem" \
    "$PROBE/outside" \
    "$share/icons/breeze/actions/16" \
    "$share/icons/breeze/actions/22" \
    "$share/ECM/modules" \
    "$share/dbus-1/interfaces" \
    "$share/dbus-1/services" \
    "$share/konsole"
cp /bin/true "$PROBE/prefix/bin/konsole"
ln -s "$PROBE/build/kf6" "$PROBE/prefix/bin/kf6"
touch \
    "$PROBE/prefix/lib/libkonsoleapp.so.26.08.0" \
    "$PROBE/prefix/lib/plugins/platforms/libqxcb.so" \
    "$PROBE/prefix/kf6/kwindowsystem/KF6WindowSystemX11Plugin.so" \
    "$PROBE/build/kf6/kwindowsystem/KF6WindowSystemX11PluginBinLayout.so" \
    "$share/ECM/modules/ECMFoo.cmake" \
    "$share/dbus-1/interfaces/org.kde.konsole.Window.xml" \
    "$share/dbus-1/services/org.kde.konsole.service" \
    "$share/konsole/default.keytab"
printf '<svg/>\n' >"$share/icons/breeze/actions/16/edit-copy.svg"
printf 'outside\n' >"$PROBE/outside/theme.svg"
ln -s edit-copy.svg "$share/icons/breeze/actions/16/edit-copy-alias.svg"
ln -s ../16 "$share/icons/breeze/actions/22/from16"
ln -s "$PROBE/outside/theme.svg" "$share/icons/breeze/actions/16/absolute.svg"
ln -s ../../../../../../outside/theme.svg "$share/icons/breeze/actions/16/escaping.svg"

"$REPO_ROOT/tools/package-konsole-runtime.sh" \
    "$PROBE/prefix" "$PROBE/runtime" >"$PROBE/package.log"

out=$PROBE/runtime
[[ -x $out/bin/konsole ]] || fail 'the installed executable is missing'
[[ -f $out/lib/libkonsoleapp.so.26.08.0 ]] || fail 'an install-lib shared object is missing'
modules=$(find "$out" -mindepth 2 -name '*.so*' ! -path "$out/lib/libkonsoleapp.so*")
[[ -z $modules ]] || fail "a loadable module was packaged: $modules"
grep -Fq 'kf6/kwindowsystem/KF6WindowSystemX11Plugin.so' "$PROBE/package.log" ||
    fail 'the left-out modules are not listed in the packaging log'

icons=$out/share/icons/breeze/actions
[[ -L $icons/16/edit-copy-alias.svg && $(readlink "$icons/16/edit-copy-alias.svg") == edit-copy.svg ]] ||
    fail 'a relative in-tree file symlink was dereferenced'
[[ -L $icons/22/from16 && -f $icons/22/from16/edit-copy.svg ]] ||
    fail 'a relative in-tree directory symlink was dereferenced or broken'
for name in absolute escaping; do
    [[ -f $icons/16/$name.svg && ! -L $icons/16/$name.svg ]] ||
        fail "the $name symlink was kept; it breaks once the bundle moves"
    grep -Fxq outside "$icons/16/$name.svg" || fail "the $name symlink was not replaced by its target"
done

[[ ! -e $out/share/ECM ]] || fail 'build-time share/ECM was packaged'
[[ ! -e $out/share/dbus-1/interfaces ]] || fail 'build-time D-Bus interface XML was packaged'
[[ -f $out/share/dbus-1/services/org.kde.konsole.service ]] || fail 'an exclusion removed a sibling runtime file'
[[ -f $out/share/konsole/default.keytab ]] || fail 'application data is missing'

printf 'Konsole runtime packaging: PASS (no dead modules, symlinks kept, build-time data left out)\n'
