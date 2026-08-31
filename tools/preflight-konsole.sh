#!/usr/bin/env bash
# Fast, no-build assertions for the Konsole workflow.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
PLAN=$(mktemp)
RENDERED=$(mktemp)
trap 'rm -f "$PLAN" "$RENDERED"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

bash -n "$REPO_ROOT/tools/build-konsole.sh" "$REPO_ROOT/tools/preflight-konsole.sh" \
    "$REPO_ROOT/tools/run-konsole-smoke.sh" "$REPO_ROOT/tools/verify-konsole-artifact.sh"
pass 'Konsole shell scripts parse'

"$REPO_ROOT/tools/test-konsole-cmake-package-prefixes.sh"
pass 'Conan CMake package prefixes are available to CONFIG-mode find_package'

for tool in msgmerge msgfmt flex bison; do
    command -v "$tool" >/dev/null 2>&1 || fail "Gettext tool is missing: $tool"
done
pass 'Gettext and parser-generator tools required by KF6 are available'

"$REPO_ROOT/tools/build-konsole.sh" --kde-builder "$REPO_ROOT" --print-plan >"$PLAN" || \
    fail '--print-plan failed'

for needle in \
    'x86_64-linux-gnu.2.27' \
    'CMAKE_SIZEOF_VOID_P' \
    'CMAKE_LIBRARY_ARCHITECTURE' \
    'CMAKE_C_IMPLICIT_INCLUDE_DIRECTORIES' \
    'CMAKE_CXX_IMPLICIT_INCLUDE_DIRECTORIES' \
    'CMAKE_SKIP_RPATH' \
    'CMAKE_C_COMPILER' \
    'CMAKE_CXX_COMPILER' \
    'compat-glibc-shims.o' \
    'fontconfig/2.15.0' \
    '--remote=conancenter' \
    'tools.build:sharedlinkflags' \
    'tools.build:exelinkflags' \
    'GIT_CONFIG_GLOBAL' \
    'ccache' \
    '-vv' \
    'core.sources:download_cache' \
    'core.sources:download_urls' \
    'conan cache clean' \
    'setproctitle' \
    'qtmultimedia=True' \
    'qtdeclarative=True' \
    'qttools=True' \
    'qtwayland=False' \
    'with_egl=True' \
    'with_x11=True' \
    'with_dbus=True' \
    'BUILD_SHARED_LIBS=OFF' \
    'KCONFIG_USE_QML=OFF' \
    'BUILD_WITH_QML=OFF' \
    'KCOREADDONS_USE_QML=OFF' \
    'KICONTHEMES_USE_QTQUICK=OFF' \
    'KWINDOWSYSTEM_QML=OFF' \
    'KWINDOWSYSTEM_X11=ON' \
    'KWINDOWSYSTEM_WAYLAND=OFF' \
    'WITH_WAYLAND=OFF' \
    'with_dbus=True' \
    'BUILD_DESIGNERPLUGIN=OFF' \
    'WITH_TEXT_TO_SPEECH=OFF' \
    'SONNET_USE_QML=OFF' \
    'WITH_BZIP2=ON' \
    'WITH_LIBLZMA=ON' \
    'WITH_OPENSSL=OFF' \
    'WITH_LIBZSTD=OFF' \
    'UDEV_DISABLED=ON' \
    'ATTICA_STATIC_BUILD=ON' \
    'CMAKE_PROJECT_INCLUDE' \
    'verify-konsole-artifact.sh' \
    'audit-with-hygiene-waivers.sh'; do
    if ! grep -Fq -- "$needle" "$PLAN" &&
       ! grep -Fq -- "$needle" "$REPO_ROOT/contrib/konsole/kde-builder.yaml.in"; then
        fail "plan/config is missing: $needle"
    fi
done
pass 'Zig baseline, static Qt, cache, hook and artifact gates are in the plan'

if grep -Eq 'go( |$)|setup-go|go build|go test' "$PLAN"; then
    fail 'Konsole plan unexpectedly contains a Go step'
fi
pass 'Konsole plan has no Go dependency'

if grep -Eiq 'qt-install-dir|find_package\(Qt6' \
    "$REPO_ROOT/contrib/konsole/kde-builder.yaml.in" "$PLAN"; then
    fail 'configuration appears to opt into host Qt/KF6'
fi
pass 'kde-builder configuration does not opt into host Qt/KF6'

workflow="$REPO_ROOT/.github/workflows/konsole-zig-build.yml"
sed -e "s|@KDE_SOURCE_DIR@|$REPO_ROOT/.konsole-preflight-source|g" \
    -e "s|@KDE_BUILD_DIR@|$REPO_ROOT/.konsole-preflight-build|g" \
    -e "s|@KDE_INSTALL_DIR@|$REPO_ROOT/.konsole-preflight-install|g" \
    -e "s|@KDE_LOG_DIR@|$REPO_ROOT/.konsole-preflight-logs|g" \
    -e "s|@KDE_STATE_DIR@|$REPO_ROOT/.konsole-preflight-state|g" \
    -e "s|@KDE_JOBS@|2|g" \
    -e "s|@CONAN_TOOLCHAIN@|$REPO_ROOT/.konsole-preflight-qt/conan_toolchain.cmake|g" \
    -e "s|@ZIGCC@|$REPO_ROOT/onebin/toolchain/zig-cc|g" \
    -e "s|@ZIGCXX@|$REPO_ROOT/onebin/toolchain/zig-c++|g" \
    -e "s|@CMAKE_PREFIX_PATH@|$REPO_ROOT/.konsole-preflight-qt;$REPO_ROOT/.konsole-preflight-install|g" \
    -e "s|@PROJECT_INCLUDE@|$REPO_ROOT/contrib/konsole/project-include.cmake|g" \
    -e "s|@KONSOLE_REF@|$(awk '$1 == "konsole" { print $2 }' "$REPO_ROOT/contrib/konsole/deps.lock")|g" \
    "$REPO_ROOT/contrib/konsole/kde-builder.yaml.in" >"$RENDERED"
python3 - "$RENDERED" "$workflow" <<'PY'
import pathlib
import sys
import yaml

config = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())
assert config["config-version"] == 2
assert config["global"]["include-dependencies"] is True
assert config["global"]["num-cores"] == "2"
assert "BUILD_SHARED_LIBS=OFF" in config["global"]["cmake-options"]
assert "CMAKE_IGNORE_PREFIX_PATH=/usr;/lib;/lib64" in config["global"]["cmake-options"]
assert config["override konsole"]["revision"]
workflow = yaml.safe_load(pathlib.Path(sys.argv[2]).read_text())
assert set(workflow["jobs"]) == {"preflight", "build"}
print("YAML config/workflow parse: PASS")
PY
pass 'rendered kde-builder YAML and workflow parse'

grep -Fq 'libGL.so*' "$REPO_ROOT/tools/verify-konsole-artifact.sh" || \
    fail 'artifact verifier does not reject a hard libGL dependency'
pass 'artifact verifier rejects a hard libGL dependency'

for needle in \
    'workflow_dispatch:' \
    'timeout-minutes: 300' \
    'actions/cache/restore@v4' \
    'actions/cache/save@v4' \
    'actions/checkout@v4' \
    'make -C onebin' \
    'Free disk space on the runner' \
    'failure() || cancelled()' \
    'set -o pipefail' \
    'tee /tmp/build-output.log' \
    'xvfb' \
    'gettext' \
    'flex' \
    'bison' \
    'libmount-dev' \
    'libcanberra-dev' \
    'libdbus-1-dev' \
    'run-konsole-smoke.sh' \
    'Scan Konsole sources for newer glibc symbols'; do
    grep -Fq "$needle" "$workflow" || fail "workflow is missing: $needle"
done
if grep -Eiq 'setup-go|go build|go test' "$workflow"; then
    fail 'workflow unexpectedly contains a Go step'
fi
pass 'workflow preserves f4 CI gates and has no Go setup'

python3 -m py_compile "$REPO_ROOT/contrib/konsole/qt-host/conanfile.py"
pass 'Conan recipe parses as Python'

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$REPO_ROOT/tools/build-konsole.sh" "$REPO_ROOT/tools/run-konsole-smoke.sh" \
        "$REPO_ROOT/tools/verify-konsole-artifact.sh"
    pass 'shellcheck passed'
else
    printf 'SKIP: shellcheck is not installed\n'
fi
printf 'Konsole preflight: PASS\n'
