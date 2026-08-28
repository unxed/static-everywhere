#!/usr/bin/env bash
# Fast invariant checks for tools/build-f4-qt.sh.
#
# Why this exists
# ---------------
# A full f4-qt run is roughly two hours. Several of those hours have been
# spent discovering mistakes that were visible in one second of
# `--print-plan` output:
#
#   - the ZoinGallery checkout was added inside the `--fetch` branch,
#     while CI calls the script with `--no-fetch`, so it never ran and the
#     graph rebuilt in full to reproduce the identical error;
#   - `conan cache clean --source` deleted the extracted sources from the
#     directory CI caches, so the next run re-downloaded every upstream
#     tarball and died on an HTTP 418 from freedesktop.org;
#   - a shim object was passed by a relative path that only resolved
#     because CI happened to pass an absolute --out.
#
# Every one of those is an assertion about *the command line the script
# emits*, which `--print-plan` prints without building anything. This
# script makes those assertions explicit, so a bad patch fails in
# seconds instead of at minute ninety.
#
# Each check names the failure that motivated it. That is deliberate: a
# check whose reason is forgotten gets deleted the first time it is
# inconvenient.
#
# Needs no network. The host-library link probe is skipped when zig is
# not on PATH; everything else always runs.
#
# The companion check for the other class -- calls to glibc symbols newer
# than the baseline -- is tools/glibc-source-scan.py, run separately
# because it needs the source trees checked out.

set -uo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
BUILD_SCRIPT="${REPO_ROOT}/tools/build-f4-qt.sh"

FAILED=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=$((FAILED + 1)); }
skip() { printf '  --   %s (skipped: %s)\n' "$1" "$2"; }

# The flags CI actually uses. If the workflow changes these, this must
# change with it -- checking the plan for flags nobody passes is how the
# --fetch mistake survived review in the first place.
CI_FLAGS=(--config linux --toolchain zig --gallery public
          --src ./f4-src --out "$PWD/out/f4-qt" --no-fetch)

PLAN=$(mktemp)
trap 'rm -f "$PLAN"' EXIT

echo "== rendering the plan with CI's own flags =="
if ! "$BUILD_SCRIPT" "${CI_FLAGS[@]}" --print-plan >"$PLAN" 2>&1; then
    echo "  could not render the plan:"
    sed 's/^/    /' "$PLAN"
    exit 1
fi
printf '  %s steps\n\n' "$(wc -l <"$PLAN")"

echo "== steps that must be present for these flags =="

# Cost: one full CI cycle. The checkout lived in the --fetch branch.
if grep -q 'submodule update --init' "$PLAN"; then
    pass "ZoinGallery submodule checkout is in the --no-fetch path"
else
    fail "ZoinGallery submodule checkout missing (it must NOT be inside the --fetch branch)"
fi

# The submodule is pinned by SSH URL upstream; without the rewrite it
# fails for anyone without a key even though the repo is public.
if grep -q 'insteadOf' "$PLAN"; then
    pass "submodule URL is rewritten to https"
else
    fail "no https rewrite for the SSH submodule URL"
fi

if grep -qE -- '-c [^ ]*compat/glibc-shims[.]c -o [^ ]*compat-glibc-shims[.]o' "$PLAN"; then
    pass "glibc compat shim object is built"
else
    fail "glibc compat shim object is never compiled"
fi

# Cost: one full CI cycle, at the very last target. The shim was scoped to
# `qt/*` because a global object broke openssl -- but Qt is only where the
# call is *compiled*; libQt6Core.a carries the unresolved reference into
# every downstream link, so f4-qt-host died on `undefined symbol: statx`
# with everything else already built. Both lists, and both global: a
# shared library with an unresolved statx links silently and fails at
# runtime, which is the worse of the two failures.
for _flags in exelinkflags sharedlinkflags; do
    if grep -qE "'tools\.build:${_flags}=\[[^']*compat-glibc-shims\.o" "$PLAN"; then
        pass "shim is in the global tools.build:${_flags}"
    else
        fail "shim missing from the global tools.build:${_flags}"
    fi
done

# Cost: the first run ever to reach the auditor, which refused to open a
# 708 MB binary at all (OB0092, 512 MiB input limit). zig cc emits DWARF
# with no -g asked for, and the Qt package's archives total 3.5 GB.
for _flags in exelinkflags sharedlinkflags; do
    if grep -qE "'tools\.build:${_flags}=\[[^']*--strip-debug" "$PLAN"; then
        pass "debug info is stripped in tools.build:${_flags}"
    else
        fail "no --strip-debug in tools.build:${_flags}"
    fi
done

# Cost: 47 of the 48 errors in the first audit that could read the
# binary. CMake records the directory of every shared library it links,
# so a portable artefact carried absolute paths from the build machine.
if grep -q 'CMAKE_SKIP_RPATH' "$PLAN"; then
    pass "CMAKE_SKIP_RPATH is set, so dependency directories stay out"
else
    fail "CMAKE_SKIP_RPATH missing from the toolchain variables"
fi

if RPATH_TEST=$("${REPO_ROOT}/tools/test-no-embedded-rpath.sh" 2>&1); then
    pass "a probe build embeds no dependency directory in DT_RUNPATH"
else
    fail "embedded rpath regression"
    printf '%s\n' "$RPATH_TEST" | sed 's/^/       /'
fi

# Cost: the first audit that could read the binary reported 18 of these
# after the rpath fix -- one per host GUI library. Profile H exists to
# permit exactly such a set, but only when it is declared.
if CONTRACT_TEST=$("${REPO_ROOT}/tools/test-host-contract.sh" 2>&1); then
    pass "the host GUI contract is declared and still enumerated"
else
    fail "host contract regression"
    printf '%s\n' "$CONTRACT_TEST" | sed 's/^/       /'
fi

# libGL is a GPU driver library, present on desktops and routinely absent
# on servers and minimal images. As a DT_NEEDED entry it stops the binary
# before main(), so no fallback of ours could run; forwarded, its absence
# only selects software rendering.
if GL_TEST=$("${REPO_ROOT}/tools/test-optional-gl.sh" 2>&1); then
    pass "libGL is optional and its absence selects software rendering"
else
    fail "optional-GL regression"
    printf '%s\n' "$GL_TEST" | sed 's/^/       /'
fi

# And that the flag survives the wrappers and leaves the audit's inputs
# alone: --strip-debug must remove DWARF while keeping .dynsym and
# .gnu.version_r, which is what the glibc baseline check reads.
_sd=$(mktemp -d)
printf 'int main(void){return 0;}\n' >"$_sd/m.c"
if "${REPO_ROOT}/onebin/toolchain/zig-cc" -target x86_64-linux-gnu.2.27 -O2 \
     "$_sd/m.c" -o "$_sd/m" -Wl,--strip-debug 2>"$_sd/err"; then
    _dbg=$(readelf -S "$_sd/m" 2>/dev/null | grep -c '\.debug_' || true)
    _dyn=$(readelf -S "$_sd/m" 2>/dev/null | grep -c '\.dynsym' || true)
    if [ "$_dbg" = 0 ] && [ "$_dyn" != 0 ]; then
        pass "--strip-debug drops DWARF and keeps the audit's inputs"
    else
        fail "--strip-debug left ${_dbg} debug sections, .dynsym count ${_dyn}"
    fi
else
    fail "zig-cc rejects -Wl,--strip-debug"
    head -2 "$_sd/err" | sed 's/^/       /'
fi
rm -rf "$_sd"
if grep -q "qt/\*:tools.build:exelinkflags" "$PLAN"; then
    fail "shim is scoped to qt/* again -- that leaves every consumer of libQt6Core.a short"
else
    pass "shim is not package-scoped"
fi

echo
echo "== flags that must have the right shape =="

# Cost: one full CI cycle. Conan re-downloaded every tarball and hit a
# 418, because CI caches ~/.conan2/p and that is where sources live.
if grep -q 'cache clean' "$PLAN"; then
    if grep 'cache clean' "$PLAN" | grep -q -- '--source'; then
        fail "conan cache clean uses --source (deletes the sources CI caches)"
    else
        pass "conan cache clean does not touch sources"
    fi
else
    fail "conan cache clean step missing (build trees are never reclaimed)"
fi

# Cost: one full CI cycle. CMake could not introspect zig-cc, so it
# emitted -isystem /usr/include ahead of every vendored include dir and
# Qt compiled against the host's ICU headers.
for v in CMAKE_C_IMPLICIT_INCLUDE_DIRECTORIES \
         CMAKE_CXX_IMPLICIT_INCLUDE_DIRECTORIES \
         CMAKE_LIBRARY_ARCHITECTURE; do
    if grep -q "$v" "$PLAN"; then
        pass "$v is declared to CMake"
    else
        fail "$v missing -- CMake cannot work this out for itself under zig-cc"
    fi
done

# Cost: would have been a full CI cycle. A relative path in a Conan flag
# is re-evaluated inside each package's own build folder.
# --print-plan substitutes the repository root with the literal <repo>
# for readability, so a genuinely absolute path can look relative here.
# Both forms count as absolute; anything else does not.
BAD_REL=$(grep -oE "tools\.build:exelinkflags=[^']*" "$PLAN" \
          | grep -oE '[^"]*compat-glibc-shims\.o' \
          | grep -vE '^(/|<repo>/)' || true)
if [ -z "$BAD_REL" ]; then
    pass "shim object is passed by absolute path"
else
    fail "shim object passed by relative path: $BAD_REL"
fi

echo
echo "== compiler-wrapper argv preservation =="
# Cost: a full qwindowkit build. qmsetup passes -D definitions containing
# spaces; the wrappers must filter their known-bad flags without splitting
# those definitions into separate linker inputs. The fake-zig regression
# test exercises both wrappers before the real compiler is needed.
if WRAPPER_TEST=$("${REPO_ROOT}/tools/test-toolchain-argument-quoting.sh" 2>&1); then
    pass "zig-cc and zig-c++ preserve arguments containing spaces"
else
    fail "compiler wrappers corrupt arguments containing spaces"
    printf '%s\n' "$WRAPPER_TEST" | sed 's/^/       /'
fi

if HOOK_TEST=$("${REPO_ROOT}/tools/test-qt6-opengl-hook.sh" 2>&1); then
    pass "Qt6::OpenGL hook ignores nested CMake projects"
else
    fail "Qt6::OpenGL hook runs in a nested CMake project"
    printf '%s\n' "$HOOK_TEST" | sed 's/^/       /'
fi

# Cost: a two-hour run that compiled and linked everything and then had
# eight of nine tests abort before main(), because a static Qt has no
# plugin .so to discover and Conan's generator drops Qt's own
# qt_import_plugins machinery.
if PLUGIN_TEST=$("${REPO_ROOT}/tools/test-qt-static-plugins.sh" 2>&1); then
    pass "static Qt plugin imports reach every consumer of Qt6::Gui"
else
    fail "static Qt plugin import regression"
    printf '%s\n' "$PLUGIN_TEST" | sed 's/^/       /'
fi

# Cost: a full run that fixed every Qt module and then reported
# `module "ZoinGallery" is not installed` 43 times, because the in-tree
# QML plugin had been built as a .so.
if BACKING_TEST=$("${REPO_ROOT}/tools/test-static-qml-backing.sh" 2>&1); then
    pass "the QML backing library is forced static, and only that target"
else
    fail "static QML backing regression"
    printf '%s\n' "$BACKING_TEST" | sed 's/^/       /'
fi

# The waiver is a workaround for an upstream bug, so its own guarantees
# are checked every run: unrelated failures still fail, and a waived case
# that starts passing fails loudly instead of leaving the crutch in place.
if WAIVER_TEST=$("${REPO_ROOT}/tools/test-ctest-waivers.sh" 2>&1); then
    pass "ctest waivers stay narrow and expire by themselves"
else
    fail "ctest waiver mechanism regression"
    printf '%s\n' "$WAIVER_TEST" | sed 's/^/       /'
fi

# Cost: would have been a silently unreproducible artifact rather than a
# failed build -- f4's own script clones qwindowkit from an unpinned
# branch, so upstream could change what we ship without anything failing.
if grep -q 'qwk-mirror' "$PLAN" && grep -q 'GIT_CONFIG_KEY_0' "$PLAN"; then
    pass "qwindowkit is redirected to a pinned mirror"
else
    fail "qwindowkit pin missing -- f4's script clones --branch main unpinned"
fi
# Matched strictly, against the full comparison rather than a substring:
# a first attempt grepped for "rev-parse HEAD" and happily accepted
# "rev-parse HEADX" when the negative control corrupted it.
if grep -qE 'qwindowkit-src rev-parse HEAD\)" = [0-9a-f]{40}' "$PLAN"; then
    pass "qwindowkit commit is verified after the build script runs"
else
    fail "no post-check that qwindowkit landed on the pinned commit"
fi

echo
echo "== every -c/-cc value parses =="
if ! python3 - "$PLAN" <<'PY'
import json, re, sys
plan = open(sys.argv[1]).read()
bad = 0
checked = 0
# -c 'key=value' / -cc key=value, values that look like JSON must parse.
for m in re.finditer(r"-c{1,2} '?([A-Za-z0-9_.:*/-]+)=([^']*)'?", plan):
    key, val = m.group(1), m.group(2).strip()
    if not (val.startswith(("[", "{"))):
        continue
    checked += 1
    try:
        json.loads(val)
    except json.JSONDecodeError as e:
        print(f"  \033[31mFAIL\033[0m {key}: {e}")
        print(f"       value was: {val[:120]}")
        bad += 1
if bad == 0:
    print(f"  \033[32mok\033[0m   {checked} JSON-valued flags parse")
sys.exit(1 if bad else 0)
PY
then
    FAILED=$((FAILED + 1))
fi

echo
echo "== the repository's own test suite =="
# Added because it was missed. The commit that removed --gallery off left
# three tests in onebin/tests/t_f4_qt_plan.c asserting the old contract,
# and they stayed broken until an unrelated change happened to run the
# suite. A gate that checks the plan but not the tests is half a gate.
if make -sC "${REPO_ROOT}/onebin" test >/tmp/onebin-test.log 2>&1; then
    pass "$(tail -n1 /tmp/onebin-test.log | tr -d '\n')"
else
    fail "onebin test suite"
    grep -E '^\s+FAIL' /tmp/onebin-test.log | sed 's/^/       /'
fi

echo
echo "== host-contract libraries actually link =="
if true; then
    # zig cc with -target searches only its own library directories, while
    # Conan emits host-contract libraries as bare -l names with no -L. That
    # cost a run: the final link of libZoinGalleryQml.so could not find
    # libGL or libX11. The wrappers now append the host paths last; this
    # proves they still do, against the real compiler rather than by
    # grepping the wrapper for a flag.
    if ! command -v zig >/dev/null 2>&1; then
        skip "host library link probe" "zig not on PATH"
    else
        probe=$(mktemp -d)
        echo 'void f(void){}' >"$probe/a.c"
        if "${REPO_ROOT}/onebin/toolchain/zig-cc" -target x86_64-linux-gnu.2.27 \
             -shared -fPIC "$probe/a.c" -lGL -lX11 -lxcb -lEGL \
             -o "$probe/a.so" 2>"$probe/err"; then
            pass "GL, X11, xcb and EGL link through zig-cc with no explicit -L"
        elif grep -q '/usr/lib/' "$probe/err"; then
            # The two failures look identical until you read the searched
            # paths. If the host directory is in that list, the wrapper is
            # doing its job and the machine simply lacks the unversioned
            # .so symlinks, which live in the -dev packages. Saying which
            # is which here saves the next person the log-reading.
            fail "host libraries are searched but not present -- install the -dev packages"
            printf '       (libgl-dev libegl-dev libx11-dev libxcb1-dev)\n'
            grep -m1 'searched paths' "$probe/err" | sed 's/^/       /'
        else
            fail "the wrappers are not adding a host library search path at all"
            head -3 "$probe/err" | sed 's/^/       /'
        fi
        # The linker arguments zig's driver refuses. Two have reached a
        # real build so far, both at the end of a long one; the wrappers
        # filter them, and this proves the filters still work against the
        # real compiler. tools/zig-linker-arg-survey.sh lists the rest.
        probe2=$(mktemp -d)
        printf 'int main(void){return 0;}\n' >"$probe2/m.c"
        if "${REPO_ROOT}/onebin/toolchain/zig-cc" -target x86_64-linux-gnu.2.27 \
             -pie -fPIE "$probe2/m.c" -o "$probe2/m" \
             -Wl,--exclude-libs,ALL -Wl,-rpath-link,/tmp \
             2>"$probe2/err"; then
            pass "linker args zig refuses (--exclude-libs, -rpath-link) are filtered"
        else
            fail "a linker argument zig refuses is reaching it"
            head -2 "$probe2/err" | sed 's/^/       /'
        fi
        # ...but only where dropping it cannot change the output. With
        # something being exported, --exclude-libs matters, so the wrapper
        # must leave it alone and let zig refuse loudly.
        if "${REPO_ROOT}/onebin/toolchain/zig-cc" -target x86_64-linux-gnu.2.27 \
             -pie -fPIE -rdynamic "$probe2/m.c" -o "$probe2/m2" \
             -Wl,--exclude-libs,ALL 2>/dev/null; then
            fail "--exclude-libs is dropped even with -rdynamic (silently changes exports)"
        else
            pass "--exclude-libs is kept when the link exports symbols"
        fi
        rm -rf "$probe2"
        rm -rf "$probe"
    fi
fi

echo
if [ "$FAILED" -eq 0 ]; then
    echo "preflight: all checks passed"
    exit 0
fi
echo "preflight: ${FAILED} check(s) failed -- not worth starting a two-hour build"
exit 1
