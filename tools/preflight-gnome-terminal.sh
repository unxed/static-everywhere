#!/usr/bin/env bash
# Fast checks for the GNOME Terminal static GTK recipe.
set -uo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
BUILD_SCRIPT="${REPO_ROOT}/tools/build-gnome-terminal.sh"
DEPS_SCRIPT="${REPO_ROOT}/tools/build-gnome-terminal-deps.sh"
VERIFY_SCRIPT="${REPO_ROOT}/tools/verify-gnome-terminal-static.sh"
LOCK="${REPO_ROOT}/contrib/gnome-terminal/deps.lock"
ARTIFACT="${REPO_ROOT}/out/gnome-terminal/gnome-terminal-server"

FAILED=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=$((FAILED + 1)); }
skip() { printf '  --   %s (skipped: %s)\n' "$1" "$2"; }

echo '== recipe scripts and toolchain probes =='
if bash -n "$BUILD_SCRIPT" "$DEPS_SCRIPT" "$VERIFY_SCRIPT" "$0" \
    "$REPO_ROOT/tools/pkg-config-hybrid-host.sh" \
    "$REPO_ROOT/tools/test-meson-zig-linker.sh" \
    "$REPO_ROOT/tools/test-no-embedded-rpath.sh"; then
    pass 'GNOME recipe scripts parse'
else
    fail 'GNOME recipe scripts parse'
fi

for tool in meson ninja zig cmake; do
    if command -v "$tool" >/dev/null 2>&1; then
        pass "$tool is available for preflight"
    else
        fail "$tool is unavailable for preflight"
    fi
done

if "$REPO_ROOT/tools/test-meson-zig-linker.sh"; then
    pass 'Meson/Zig linker detection and build probe'
else
    fail 'Meson/Zig linker detection and build probe'
fi

if "$REPO_ROOT/tools/test-no-embedded-rpath.sh"; then
    pass 'CMake does not embed dependency RPATH'
else
    fail 'CMake embeds dependency RPATH'
fi

PLAN=$(mktemp)
DEPS_PLAN=$(mktemp)
trap 'rm -f "$PLAN" "$DEPS_PLAN"' EXIT

echo '== static build plan =='
if "$BUILD_SCRIPT" --print-plan >"$PLAN" 2>&1; then
    pass 'build-gnome-terminal.sh --print-plan'
else
    fail 'build-gnome-terminal.sh --print-plan'
    sed 's/^/       /' "$PLAN"
fi

for required in \
    '--prefer-static' \
    '-Ddefault_library=static' \
    'PKG_CONFIG_PATH=' \
    '--wrap-mode nodownload' \
    '-Ddocs=false' \
    '-Dnautilus_extension=false' \
    '-Dsearch_provider=false' \
    'gnome-terminal-server' \
    'package root (install with DESTDIR)' \
    '--profile hybrid' \
    '--strict' \
    'libGL.so.1' \
    '--libexecdir libexec' \
    'x86_64-linux-gnu.2.28' \
    '-Wl,-z,relro' \
    '-Wl,-z,now' \
    '-Wl,-z,noexecstack' \
    'meson install' \
    'verify-gnome-terminal-static.sh'; do
    if grep -Fq -- "$required" "$PLAN"; then
        pass "plan contains ${required}"
    else
        fail "plan is missing ${required}"
    fi
done

if "$DEPS_SCRIPT" --print-plan >"$DEPS_PLAN" 2>&1; then
    pass 'build-gnome-terminal-deps.sh --print-plan'
else
    fail 'build-gnome-terminal-deps.sh --print-plan'
    sed 's/^/       /' "$DEPS_PLAN"
fi

for required in \
    'commit verified' \
    'host contract: X11 client libraries plus the Profile H OpenGL/EGL runtime ABI' \
    'host library policy: pkg-config maps only X11/OpenGL -l arguments to shared objects' \
    'fontconfig install: manual copy' \
    'HAVE_XRENDERCREATESOLIDFILL' \
    'HAVE_XRENDERCREATELINEARGRADIENT' \
    'HAVE_XRENDERCREATERADIALGRADIENT' \
    'HAVE_XRENDERCREATECONICALGRADIENT' \
    'CMAKE_SIZEOF_VOID_P=8' \
    'CMAKE_LIBRARY_ARCHITECTURE=x86_64-linux-gnu' \
    'CMAKE_C_IMPLICIT_INCLUDE_DIRECTORIES=/usr/include' \
    'CMAKE_CXX_IMPLICIT_INCLUDE_DIRECTORIES=/usr/include' \
    'CMAKE_SKIP_RPATH=ON' \
    'zlib libffi pcre2 expat libpng pixman' \
    'util-linux-libuuid-only.patch' \
    'gdk-pixbuf-static-loader-deps.patch' \
    'gtk-no-host-atk-bridge.patch' \
    'vte-static-library.patch' \
    'libhandy-static-library.patch' \
    'dependency patch contract: every patch is a valid Git diff captured from its pinned checkout' \
    'VTE linker feature contract: _b_symbolic_functions=false for Zig 0.13 (unsupported -Bsymbolic-functions)' \
    'synthetic intl.pc' \
    'libuuid-only=true' \
    'uuid-only graph audit: reject util-linux libcommon and non-UUID lib/ sources before compile' \
    'source_tree contract: cleanup diagnostics never contaminate the returned source path' \
    'Meson option contract: every recipe -D option is declared by the pinned project or Meson core' \
    'cache identity: dependency commit plus recipe, patch and toolchain fingerprint' \
    'build-time tools: ' \
    'gtk lz4 vte libhandy'; do
    if grep -Fq -- "$required" "$DEPS_PLAN"; then
        pass "dependency plan contains ${required}"
    else
        fail "dependency plan is missing ${required}"
    fi
done

if grep -Fq -- 'export PATH="${PREFIX}/bin:${TOOLCHAIN}:${PATH}"' "$DEPS_SCRIPT" \
    && grep -Fq -- 'require_prefix_program()' "$DEPS_SCRIPT" \
    && grep -Fq -- 'require_prefix_program "${program}"' "$DEPS_SCRIPT"; then
    pass 'dependency build tools are resolved from the static prefix before host PATH'
else
    fail 'dependency build tools do not have a prefix-first resolution contract'
fi

if grep -Fq -- 'run git -C "${dir}" reset --quiet --hard "${commit}" >&2' "$DEPS_SCRIPT" \
    && grep -Fq -- 'run git -C "${dir}" clean -fdx >&2' "$DEPS_SCRIPT"; then
    pass 'source-tree cleanup output cannot corrupt command-substitution paths'
else
    fail 'source-tree cleanup output can corrupt command-substitution paths'
fi

if grep -Fq -- 'meson_core_option()' "$DEPS_SCRIPT" \
    && grep -Fq -- 'meson_source_option()' "$DEPS_SCRIPT" \
    && grep -Fq -- 'validate_meson_options "${source}"' "$DEPS_SCRIPT" \
    && grep -Fq -- 'RECIPE_FINGERPRINT=' "$DEPS_SCRIPT" \
    && grep -Fq -- 'RECIPE_FINGERPRINT}' "$DEPS_SCRIPT"; then
    pass 'Meson options and dependency cache markers are tied to pinned recipe inputs'
else
    fail 'Meson options or dependency cache markers are not tied to pinned recipe inputs'
fi

PATCH_DIR="${REPO_ROOT}/contrib/gnome-terminal/patches"
PATCH_COUNT=0
for patch in "${PATCH_DIR}"/*.patch; do
    if [ -f "${patch}" ]; then
        PATCH_COUNT=$((PATCH_COUNT + 1))
        if git apply --numstat "${patch}" >/dev/null 2>&1; then
            pass "captured dependency patch is a valid Git diff: $(basename "${patch}")"
        else
            fail "captured dependency patch is malformed: $(basename "${patch}")"
        fi
    fi
done
if [ "${PATCH_COUNT}" -gt 0 ]; then
    pass "validated ${PATCH_COUNT} captured dependency patch(es)"
else
    fail 'no captured dependency patches found'
fi

UUID_PATCH="${PATCH_DIR}/util-linux-libuuid-only.patch"
if git apply --numstat "$UUID_PATCH" >/dev/null 2>&1; then
    pass 'captured util-linux patch is a valid Git patch'
else
    fail 'captured util-linux patch is not a valid Git patch'
fi

for required in \
    'diff --git a/lib/meson.build b/lib/meson.build' \
    "if get_option('libuuid-only')" \
    "randutils_c = files('randutils.c')" \
    'subdir_done()'; do
    if grep -Fq -- "$required" "$UUID_PATCH"; then
        pass "captured util-linux patch contains ${required}"
    else
        fail "captured util-linux patch is missing ${required}"
    fi
done

GDK_PIXBUF_PATCH="${REPO_ROOT}/contrib/gnome-terminal/patches/gdk-pixbuf-static-loader-deps.patch"
if git apply --numstat "$GDK_PIXBUF_PATCH" >/dev/null 2>&1; then
    pass 'captured gdk-pixbuf patch is a valid Git patch'
else
    fail 'captured gdk-pixbuf patch is not a valid Git patch'
fi

for required in \
    'diff --git a/gdk-pixbuf/meson.build b/gdk-pixbuf/meson.build' \
    'dependencies: loaders_deps' \
    'dependencies: [ gdk_pixbuf_deps, loaders_deps ]'; do
    if grep -Fq -- "$required" "$GDK_PIXBUF_PATCH"; then
        pass "captured gdk-pixbuf patch contains ${required}"
    else
        fail "captured gdk-pixbuf patch is missing ${required}"
    fi
done

GTK_PATCH="${PATCH_DIR}/gtk-no-host-atk-bridge.patch"
for required in \
    'diff --git a/meson.build b/meson.build' \
    "-  atkbridge_dep  = dependency('atk-bridge-2.0'" \
    "-  atk_pkgs += ['atk-bridge-2.0']" \
    '-#include <atk-bridge.h>' \
    '-  atk_bridge_adaptor_init (NULL, NULL);'; do
    if grep -Fq -- "${required}" "${GTK_PATCH}"; then
        pass "captured GTK patch contains ${required}"
    else
        fail "captured GTK patch is missing ${required}"
    fi
done

for required in 'reset --quiet --hard' 'clean -fdx'; do
    if grep -Fq -- "$required" "$DEPS_SCRIPT"; then
        pass "dependency source cache cleanup contains ${required}"
    else
        fail "dependency source cache cleanup is missing ${required}"
    fi
done

if grep -Eiq 'dbus-1|atspi|atk-bridge' "$REPO_ROOT/tools/pkg-config-hybrid-host.sh" \
    || grep -Eiq 'libdbus|libatspi|libatk-bridge' "$REPO_ROOT/tools/build-gnome-terminal.sh"; then
    fail 'host contract contains a forbidden D-Bus/accessibility library'
else
    pass 'host contract excludes D-Bus and accessibility libraries'
fi

echo
echo '== hybrid pkg-config boundary =='
HOST_LIBS=$(bash "$REPO_ROOT/tools/pkg-config-hybrid-host.sh" --libs --static x11 2>/dev/null || true)
if grep -Fq -- '/usr/lib/x86_64-linux-gnu/libX11.so' <<<"$HOST_LIBS" \
    && ! grep -Eq -- '(^| )-l(X11|xcb|Xau|Xdmcp)( |$)' <<<"$HOST_LIBS"; then
    pass 'host X11 closure resolves to shared objects'
else
    fail 'host X11 closure still contains bare static -l arguments'
    printf '       %s\n' "$HOST_LIBS"
fi
echo
echo '== locked static stack =='
for dependency in gnome-terminal vte gtk libhandy glib gvdb pango cairo harfbuzz freetype fontconfig gdk-pixbuf pcre2 util-linux zlib libffi libpng pixman fribidi expat atk epoxy lz4; do
    if awk -v name="$dependency" '$1 == name && $3 ~ /^[0-9a-f]{40}$/ && $4 ~ /\.git$/ { found = 1 } END { exit !found }' "$LOCK"; then
        pass "lock contains ${dependency}"
    else
        fail "lock is missing ${dependency}"
    fi
done

if [ -x "$VERIFY_SCRIPT" ]; then
    pass 'static artifact verifier is executable'
else
    fail 'static artifact verifier is missing or not executable'
fi
echo
echo '== onebin regression suite =='
if make -sC "$REPO_ROOT/onebin" test >/tmp/onebin-test-gnome-terminal.log 2>&1; then
    pass "$(tail -n 1 /tmp/onebin-test-gnome-terminal.log | tr -d '\n')"
else
    fail 'onebin test suite'
    tail -30 /tmp/onebin-test-gnome-terminal.log | sed 's/^/       /'
fi

if [ -x "$ARTIFACT" ]; then
    echo
    echo '== static artifact =='
    if "$VERIFY_SCRIPT" "$ARTIFACT"; then
        pass 'GNOME Terminal has no dynamic GTK stack'
    else
        fail 'GNOME Terminal static GTK verification'
    fi
else
    skip 'static artifact verification' "no ${ARTIFACT}; run build-gnome-terminal.sh with a source checkout and static prefix"
fi

echo
if [ "$FAILED" -eq 0 ]; then
    echo 'preflight: all checks passed'
    exit 0
fi
echo "preflight: ${FAILED} check(s) failed"
exit 1
