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
    '--libexecdir libexec' \
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
    'host contract: X11, OpenGL/EGL, accessibility IPC, schemas, fonts and session services' \
    'fontconfig install: manual copy' \
    'zlib libffi pcre2 expat libpng pixman' \
    'gtk lz4 vte libhandy'; do
    if grep -Fq -- "$required" "$DEPS_PLAN"; then
        pass "dependency plan contains ${required}"
    else
        fail "dependency plan is missing ${required}"
    fi
done

echo
echo '== locked static stack =='
for dependency in gnome-terminal vte gtk libhandy glib pango cairo harfbuzz freetype fontconfig gdk-pixbuf pcre2 zlib libffi libpng pixman fribidi expat atk epoxy lz4; do
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
