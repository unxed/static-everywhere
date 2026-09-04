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
    "$REPO_ROOT/tools/run-konsole-smoke.sh" "$REPO_ROOT/tools/verify-konsole-artifact.sh" \
    "$REPO_ROOT/contrib/konsole/qt-package-root.sh" "$REPO_ROOT/tools/test-konsole-qt-package-root.sh" \
    "$REPO_ROOT/tools/test-konsole-cmake-find-mode.sh" \
    "$REPO_ROOT/tools/test-konsole-qt-cmake-component-shims.sh" \
    "$REPO_ROOT/tools/test-konsole-host-cmake-discovery.sh" \
    "$REPO_ROOT/tools/test-konsole-host-build-tool-discovery.sh" \
    "$REPO_ROOT/tools/test-linker-arg-compat.sh" \
    "$REPO_ROOT/tools/test-konsole-host-python-modules.sh" \
    "$REPO_ROOT/tools/test-konsole-host-perl-modules.sh" \
    "$REPO_ROOT/tools/test-konsole-host-docbook-tools.sh" \
    "$REPO_ROOT/tools/test-konsole-static-qt-plugins.sh"
pass 'Konsole shell scripts parse'

bash "$REPO_ROOT/tools/test-konsole-cmake-package-prefixes-regression.sh"
pass 'Conan CMake package prefixes are available to CONFIG-mode find_package'

bash "$REPO_ROOT/tools/test-konsole-cmake-find-mode.sh"
pass 'legacy-variable consumers receive complete Conan CONFIG adapters'

bash "$REPO_ROOT/tools/test-konsole-host-cmake-discovery.sh"
pass 'host CMake module discovery survives Zig ABI-probe metadata loss'

bash "$REPO_ROOT/tools/test-konsole-host-build-tool-discovery.sh"
pass 'host build tools survive CONFIG-mode package lookup'

bash "$REPO_ROOT/tools/test-linker-arg-compat.sh"
pass 'Zig accepts KDE linker policy flags through the wrappers'

bash "$REPO_ROOT/tools/test-konsole-qt-package-root.sh"
pass 'Qt package roots are discovered from CMakeDeps metadata'

bash "$REPO_ROOT/tools/test-konsole-qt-cmake-component-shims.sh"
pass 'Qt component-style CONFIG packages resolve through Conan aggregate metadata'

bash "$REPO_ROOT/tools/test-konsole-static-qt-plugins.sh"
pass 'Konsole static Qt plugin imports are configure-time and Conan-safe'

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
    'CMAKE_DISABLE_FIND_PACKAGE_ACL=ON' \
    'CMAKE_DISABLE_FIND_PACKAGE_OpenMP=ON' \
    'CMAKE_DISABLE_FIND_PACKAGE_UTEMPTER=ON' \
    'CMAKE_DISABLE_FIND_PACKAGE_UDev=ON' \
    'CMAKE_PROJECT_INCLUDE' \
    'verify-konsole-artifact.sh' \
    'audit-with-hygiene-waivers.sh' \
    'BUILD_KSECRETD=OFF' \
    'BUILD_KWALLETD=OFF' \
    'BUILD_KWALLET_QUERY=OFF' \
    'BUILD_PLUGINS=none'; do
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
    -e "s|@INSTALL_PREFIX_CMD@|$REPO_ROOT/tools/kde-install-and-reconcile.sh|g" \
    -e "s|@QT_PACKAGE_ROOT@|$REPO_ROOT/.konsole-preflight-qt|g" \
    -e "s|@KONSOLE_REF@|$(awk '$1 == "konsole" { print $2 }' "$REPO_ROOT/contrib/konsole/deps.lock")|g" \
    "$REPO_ROOT/contrib/konsole/kde-builder.yaml.in" >"$RENDERED"
python3 - "$RENDERED" "$workflow" <<'PY'
import pathlib
import shlex
import sys
import yaml

config = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())
assert config["config-version"] == 2
assert config["global"]["include-dependencies"] is True
assert config["global"]["num-cores"] == "2"
cmake_options = config["global"]["cmake-options"]
assert "BUILD_SHARED_LIBS=OFF" in cmake_options
assert "CMAKE_IGNORE_PREFIX_PATH=" in cmake_options
assert "CMAKE_IGNORE_PREFIX_PATH=/usr" not in cmake_options
assert "WITH_X11=ON" in cmake_options
assert config["override konsole"]["revision"]
assert "#" not in cmake_options
shlex.split(cmake_options)
workflow = yaml.safe_load(pathlib.Path(sys.argv[2]).read_text())
assert set(workflow["jobs"]) == {"preflight", "build"}
print("YAML config/workflow parse: PASS")
PY
pass 'rendered kde-builder YAML and workflow parse'
pass 'folded cmake-options scalar is free of comments and shlex-safe'

grep -Fq 'libGL.so*' "$REPO_ROOT/tools/verify-konsole-artifact.sh" || \
    fail 'artifact verifier does not reject a hard libGL dependency'
grep -Fq 'libcanberra.so.0' "$REPO_ROOT/tools/verify-konsole-artifact.sh" || \
    fail 'artifact verifier does not allow the declared Canberra runtime dependency'
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
    'liburi-perl' \
    'libdbus-1-dev' \
    'python3-lxml' \
    'libxml2-dev' \
    'libxml2-utils' \
    'libxslt1-dev' \
    'xsltproc' \
    'docbook-xml' \
    'docbook-xsl' \
    'test-konsole-host-docbook-tools.sh' \
    'test-konsole-host-perl-modules.sh' \
    'run-konsole-smoke.sh' \
    'Scan Konsole sources for newer glibc symbols'; do
    grep -Fq "$needle" "$workflow" || fail "workflow is missing: $needle"
done
if grep -Eiq 'setup-go|go build|go test' "$workflow"; then
    fail 'workflow unexpectedly contains a Go step'
fi
pass 'workflow preserves f4 CI gates and has no Go setup'

while read -r apt_package probe_type probe extra; do
    [[ -z "${apt_package:-}" || "$apt_package" == \#* ]] && continue
    [[ -n "${probe_type:-}" && -n "${probe:-}" && -z "${extra:-}" ]] || \
        fail 'DocBook host-tool manifest has a malformed entry'
    grep -Fq "$apt_package" "$workflow" || \
        fail "workflow does not install DocBook host package: $apt_package"
done < "$REPO_ROOT/contrib/konsole/host-docbook-tools.txt"
pass 'workflow installs declared DocBook host build tools'

while read -r apt_package python_module extra; do
    [[ -z "${apt_package:-}" || "$apt_package" == \#* ]] && continue
    [[ -n "${python_module:-}" && -z "${extra:-}" ]] || \
        fail 'host Python module manifest has a malformed entry'
    grep -Fq "$apt_package" "$workflow" || \
        fail "workflow does not install host Python package: $apt_package"
done < "$REPO_ROOT/contrib/konsole/host-python-modules.txt"
pass 'workflow installs declared host Python build modules'

while read -r apt_package perl_module extra; do
    [[ -z "${apt_package:-}" || "$apt_package" == \#* ]] && continue
    [[ -n "${perl_module:-}" && -z "${extra:-}" ]] || \
        fail 'host Perl module manifest has a malformed entry'
    grep -Fq "$apt_package" "$workflow" || \
        fail "workflow does not install host Perl package: $apt_package"
done < "$REPO_ROOT/contrib/konsole/host-perl-modules.txt"
pass 'workflow installs declared host Perl build modules'

for needle in \
    'exports = "qt_cmake_components.py"' \
    'self.dependencies["qt"].cpp_info.components' \
    'component_shim_names(' \
    'component_config(module)' \
    'component_version_config()' \
    'legacy_package_config' \
    '"qt/*:qt5compat": True' \
    '"qt/*:qtsvg": True' \
    '"hunspell/1.7.2"' \
    '"bzip2/1.0.8"' \
    '"xz_utils/5.8.3"' \
    '"zlib/1.3.2"' \
    '"libxml2/2.15.3"' \
    '"libmount/2.39.2"' \
    'cmake_deps.set_property' \
    '"libmount::libmount"' \
    '"cmake_target_aliases"' \
    '"LibMount::LibMount"'; do
    grep -Fq "$needle" "$REPO_ROOT/contrib/konsole/qt-host/conanfile.py" || \
        fail "Conan recipe is missing CMake dependency compatibility metadata: $needle"
done
grep -Fq '"HUNSPELLConfig.cmake"' "$REPO_ROOT/contrib/konsole/qt-host/conanfile.py" || \
    fail 'legacy Hunspell CONFIG adapter is missing'
# The needle above used to be the literal '"GuiPrivate"', which pinned the
# hand written private-component list in place: the recipe was required to
# name the components it happened to need. That is the habit the
# derivation replaced, so the check now requires the derivation instead.
# Keeping the old needle would have demanded exactly what
# test-konsole-qt-component-derivation.sh forbids -- and it did, until
# this run failed on the contradiction.
pass 'Conan recipe carries component and target compatibility metadata'

grep -Fq 'konsole_conan_package_roots' "$REPO_ROOT/tools/build-konsole.sh" || \
    fail 'CMake MODULE finders cannot see Conan package roots'
grep -Fq -- "--build='hunspell/*'" "$REPO_ROOT/tools/build-konsole.sh" || \
    fail 'Sonnet spellchecker backend is not forced through the target compiler'
grep -Fq 'hunspell 1.7.2 - -' "$REPO_ROOT/contrib/konsole/deps.lock" || \
    fail 'Sonnet spellchecker backend is missing from the dependency lock'
pass 'Sonnet always has a source-built Hunspell backend'

grep -Fq 'Qt6GuiPrivate' "$REPO_ROOT/tools/test-konsole-qt-cmake-component-shims.sh" || \
    fail 'Qt private-component adapter regression is missing'
pass 'Conan recipe covers standalone Qt private-component lookups'

for needle in \
    'override qca:' \
    '-DBUILD_WITH_QT6=ON' \
    '-DBUILD_TESTS=OFF' \
    '-DBUILD_TOOLS=OFF' \
    '-DBUILD_PLUGINS=none'; do
    grep -Fq -- "$needle" "$REPO_ROOT/contrib/konsole/kde-builder.yaml.in" || \
        fail "kde-builder recipe is missing qca Qt6 option: $needle"
done
pass 'qca is configured for the Qt6 graph without optional test tools'

grep -Fq -- "-o:h 'qt/*:qtsvg=True'" "$REPO_ROOT/tools/build-konsole.sh" || \
    fail 'build-konsole.sh does not enable QtSvg required by KDE Frameworks'
pass 'Conan build enables Qt modules required by KDE Frameworks'

python3 -m py_compile "$REPO_ROOT/contrib/konsole/qt-host/conanfile.py" \
    "$REPO_ROOT/contrib/konsole/qt-host/qt_cmake_components.py"
pass 'Conan recipe parses as Python'

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$REPO_ROOT/tools/build-konsole.sh" "$REPO_ROOT/tools/run-konsole-smoke.sh" \
        "$REPO_ROOT/tools/verify-konsole-artifact.sh"
    pass 'shellcheck passed'
else
    printf 'SKIP: shellcheck is not installed\n'
fi

# The zig wrappers offer host headers and libraries as a last resort,
# which is right for Profile H and wrong for Profile S/U. far2l's musl
# build died on the host's glibc <execinfo.h> because of it. The
# toolchain is shared, so this is checked from every preflight.
"$REPO_ROOT/tools/test-toolchain-host-isolation.sh" \
    || { printf 'FAIL: toolchain host isolation regression\n' >&2; exit 1; }

# ki18n compiles src/i18n-qml against Qt6::Qml, whose headers include
# <qqmlintegration.h> -- a header of the separate QtQmlIntegration
# module. Upstream Qt propagates that include directory through
# Qt6::Qml; this Conan package does not, so the directory has to be
# injected. Both halves are asserted: the template must carry the
# placeholder, and the script must know how to fill it.
grep -q 'QtQmlIntegration' "$REPO_ROOT/contrib/konsole/kde-builder.yaml.in" \
    || { printf 'FAIL: the QtQmlIntegration include directory is no longer injected;\n' >&2
         printf '      ki18n will fail on "qqmlintegration.h file not found"\n' >&2
         exit 1; }
grep -q 'qt_package_root' "$REPO_ROOT/tools/build-konsole.sh" \
    || { printf 'FAIL: build-konsole.sh no longer resolves the Qt package root\n' >&2
         exit 1; }
pass 'the QtQmlIntegration include directory is injected'

# Every placeholder in the template must have a substitution, or the
# rendered config silently keeps a literal @NAME@ and the option becomes
# a nonsense path.
python3 - "$REPO_ROOT" <<'PYEOF'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
tpl = (root / 'contrib/konsole/kde-builder.yaml.in').read_text()
script = (root / 'tools/build-konsole.sh').read_text()
missing = sorted({m for m in re.findall(r'@[A-Z_]+@', tpl)
                  if m not in script})
if missing:
    print('FAIL: placeholders with no substitution in build-konsole.sh:')
    for m in missing:
        print('  ' + m)
    sys.exit(1)
PYEOF
pass 'every template placeholder has a substitution'


# A legacy-variable adapter must point at the directory holding the
# header, not an ancestor of it. sonnet includes <hunspell.hxx>
# unqualified while the package installs it under include/hunspell/,
# and the build died on "file not found" with the package found.
"$REPO_ROOT/tools/test-legacy-finder-header-dir.sh" \
    || { printf 'FAIL: legacy finder adapter regression\n' >&2; exit 1; }

# Qt6 component adapters must be derived from the package rather than
# listed. The private family was grown one CI round at a time -- a
# framework asks for Qt6GuiPrivate, the build fails two hours in, the
# name gets appended -- and a list maintained that way is only ever
# correct about the past.
"$REPO_ROOT/tools/test-konsole-qt-component-derivation.sh" \
    || { printf 'FAIL: Qt component derivation regression\n' >&2; exit 1; }

# An exported CMake target must not name a package its config leaves
# undeclared. kjobwidgets did, and kio stopped on a target nobody had
# defined.
"$REPO_ROOT/tools/test-cmake-target-dep-reconcile.sh" \
    || { printf 'FAIL: cmake target dependency reconciler regression\n' >&2
         exit 1; }

# A consumer must be able to include an export naming a target the
# exporting package forgot to declare, and the required dependency must
# stay enabled.
"$REPO_ROOT/tools/test-konsole-export-target-predefine.sh" \
    || { printf 'FAIL: export target predefinition regression\n' >&2; exit 1; }

# Every KF6 module must share one install libdir, or a dependency
# installed by one is invisible to find_package in another. kjobwidgets
# split off into lib/cmake while its dependency went to
# lib/<arch>/cmake, and kio could not resolve KF6::Notifications.
"$REPO_ROOT/tools/test-konsole-uniform-libdir.sh" \
    || { printf 'FAIL: KDE install libdir is not pinned uniformly\n' >&2
         exit 1; }

# The install-and-reconcile wrapper must install first and reconcile
# after, so kjobwidgets' under-declared config is repaired before kio
# configures against it.
"$REPO_ROOT/tools/test-kde-install-reconcile-wrapper.sh" \
    || { printf 'FAIL: install-and-reconcile wrapper regression\n' >&2; exit 1; }

# Both renderers must substitute every template placeholder, and
# top-level placeholders must be quoted -- an unquoted make-install-prefix
# placeholder broke the YAML parse, and the preflight missed it because
# its own substitution list had drifted from the build script's.
"$REPO_ROOT/tools/test-konsole-placeholder-sync.sh" \
    || { printf 'FAIL: template placeholder sync regression\n' >&2; exit 1; }

# Forward scan: no module in the resolved KF6 graph may REQUIRE a project
# the config ignores. Reads each module's own CMakeLists.txt from
# invent.kde.org -- nine seconds for the whole graph -- instead of letting
# a two-hour build discover it. kdoctools is ignored because its meinproc6
# segfaults on DocBook; this proves dropping it moves nothing.
"$REPO_ROOT/tools/scan-kde-graph-requirements.sh" \
    || { printf 'FAIL: an ignored project is required somewhere in the graph\n' >&2
         exit 1; }

# kde-builder type-checks a few option values and rejects the rest of the
# config outright. ignore-projects must be a list -- a space-separated
# string fails with "has invalid value type", which is how the last run
# died half an hour in. Checked against the rendered config here.
python3 - "$RENDERED" <<'TYPES'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
g = cfg.get("global", {})
v = g.get("ignore-projects")
if v is not None and not isinstance(v, list):
    sys.exit("FAIL: ignore-projects must be a YAML list; kde-builder rejects "
             f"a {type(v).__name__} with 'has invalid value type'")
TYPES
pass 'kde-builder option value types are valid'

# Qt must be built with a TLS backend: kio's KIOCore uses
# QSslError::SslError unconditionally, and without OpenSSL Qt stubs
# QSslError out under QT_NO_SSL. Both places that state the option are
# checked, since it is spelled in the recipe and on the conan command line.
for f in contrib/konsole/qt-host/conanfile.py tools/build-konsole.sh; do
    grep -qE "qt/\*:openssl['\"]?[=:] ?['\"]?True" "$REPO_ROOT/$f" \
        || { printf 'FAIL: %s does not build Qt with openssl; kio needs QSslError\n' "$f" >&2
             exit 1; }
done
pass 'Qt is built with OpenSSL, as kio requires'

# The KPackage block the hook deletes must still match upstream. The hook
# raises FATAL_ERROR when it does not -- correctly, but two hours in.
"$REPO_ROOT/tools/check-kpackage-stale-target.sh" \
    || { printf 'FAIL: the kpackage workaround no longer matches upstream\n' >&2
         exit 1; }

# Private STATIC helpers must be exported alongside the targets that link
# them, for every module: knewstuff stopped on knscore_jobs_static, and
# the shape recurs wherever a static build meets a shared-only upstream.
"$REPO_ROOT/tools/test-konsole-static-helper-export.sh" \
    || { printf 'FAIL: static helper export regression\n' >&2; exit 1; }

# The konsole pin must be a ref kde-builder can resolve. It validates the
# pin with `git ls-remote --exit-code <repo> <ref>`, which sees ref names
# only -- branches and tags, never a bare commit -- so a sha fails with
# "repository has no ref" after the whole KF6 graph has built. This runs
# the identical command against the repository kde-builder fetches from
# (invent.kde.org, not the GitHub mirror), so a bad pin fails in seconds.
konsole_ref=$(awk '$1 == "konsole" { print $2 }' "$REPO_ROOT/contrib/konsole/deps.lock")
konsole_repo=$(awk '$1 == "konsole" { print $4 }' "$REPO_ROOT/contrib/konsole/deps.lock")
if [[ $konsole_ref =~ ^[0-9a-f]{40}$ ]]; then
    fail "konsole is pinned to a commit sha ($konsole_ref); kde-builder resolves pins with ls-remote and cannot see bare commits -- pin a tag"
fi
if command -v git >/dev/null 2>&1; then
    if timeout 30 git ls-remote --exit-code "$konsole_repo" "$konsole_ref" >/dev/null 2>&1; then
        pass "konsole pin $konsole_ref resolves on $konsole_repo, as kde-builder will check"
    else
        fail "konsole pin $konsole_ref is not a ref on $konsole_repo; kde-builder will report 'has no ref'"
    fi
    # The lock's third field must be the COMMIT the tag points at -- what
    # rev-parse HEAD yields after checkout and what the workflow compares
    # against. For an annotated tag a plain ls-remote returns the tag
    # object instead, and the first repin recorded exactly that; the
    # workflow's provenance check then failed before any artifact existed.
    konsole_sha=$(awk '$1 == "konsole" { print $3 }' "$REPO_ROOT/contrib/konsole/deps.lock")
    peeled=$(timeout 30 git ls-remote "$konsole_repo" "refs/tags/${konsole_ref}^{}" 2>/dev/null | cut -c1-40)
    [ -n "$peeled" ] || peeled=$(timeout 30 git ls-remote "$konsole_repo" "$konsole_ref" 2>/dev/null | cut -c1-40)
    if [ -n "$peeled" ] && [ "$peeled" = "$konsole_sha" ]; then
        pass "konsole $konsole_ref points at $konsole_sha, matching deps.lock"
    elif [ -n "$peeled" ]; then
        fail "konsole $konsole_ref points at $peeled but deps.lock records $konsole_sha (tag object instead of commit, or the tag moved)"
    fi
fi

# Two f4-qt fixes that konsole's kde-builder side lacked, each verified
# on a minimal project before being wired in. Both are asserted here so
# neither can quietly fall out of the config.
#
# (1) /usr/include must be declared implicit for every module, or FindX11's
# X11_INCLUDE_DIR=/usr/include is emitted as -I ahead of the Conan paths
# and konsole compiles against the host's ICU 74 while linking ICU 78.
for lang in C CXX; do
    grep -qE "^\s*-DCMAKE_${lang}_IMPLICIT_INCLUDE_DIRECTORIES=/usr/include" \
        "$REPO_ROOT/contrib/konsole/kde-builder.yaml.in" \
        || fail "CMAKE_${lang}_IMPLICIT_INCLUDE_DIRECTORIES is not set for kde-builder modules; host /usr/include will shadow the Conan ICU headers"
done
pass 'kde-builder modules declare /usr/include implicit (host ICU cannot shadow Conan ICU)'
# (2) the Qt6::Quick -> Qt6::OpenGL edge must be repaired for konsole's link.
grep -q 'link-qt6-opengl.cmake' "$REPO_ROOT/contrib/konsole/project-include.cmake" \
    || fail 'project-include.cmake no longer includes link-qt6-opengl.cmake; konsolepart.so will miss QOpenGL* symbols'
pass 'the Qt6::Quick -> Qt6::OpenGL edge is repaired for konsole'

printf 'Konsole preflight: PASS\n'
