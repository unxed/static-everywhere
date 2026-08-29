#!/bin/sh
# tools/build-f4-qt.sh — build and audit f4-qt (Qt Reference Application).
# Interface: 05-REFERENCE-f4-qt.md §9.
# POSIX sh, not bash.
set -eu

CONFIG=""
SRC="./f4-qt-src"
OUT="./out/f4-qt"
FETCH=0
PRINT_PLAN=0
PIN="1a03511a5ad97bbd4ec1400078272373b32e9d2c"
GALLERY=""
TOOLCHAIN="host"
GLIBC_BASELINE="2.27"
# qwindowkit is fetched by f4's own script from an unpinned branch; we pin
# it (see the mirror steps below and contrib/f4-qt/deps.lock). This is what
# stdware/qwindowkit's main resolved to when it was pinned -- not a blessed
# release, since upstream tags none.
QWK_URL="https://github.com/stdware/qwindowkit.git"
QWK_PIN="4f683f2e0e4f3a7d6061d0224de9ed30e7c17e0f"

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
ONEBIN_BIN="${REPO_ROOT}/onebin/build/onebin"
DEPS_LOCK="${REPO_ROOT}/contrib/f4-qt/deps.lock"
ZIGCC="${REPO_ROOT}/onebin/toolchain/zig-cc"
ZIGCXX="${REPO_ROOT}/onebin/toolchain/zig-c++"

usage() {
    cat <<'EOF'
Usage: tools/build-f4-qt.sh --config linux|windows --src DIR --out DIR [OPTIONS]

  --config linux|windows  required: target configuration
  --src DIR               f4-qt source tree (default: ./f4-qt-src)
  --out DIR               build/install output directory (default: ./out/f4-qt)
  --pin COMMIT            git commit to check out (default: 1a03511a...)
  --fetch                 allowed to clone f4 over the network
  --no-fetch              refuse to touch the network (default)
  --print-plan            print every command this invocation would run
  --gallery public        fetch the ZoinGallery submodule over https (§7.8);
                          now the only supported value, and the default
  --toolchain host|zig    which compiler builds the Qt dependency stack (default: host)
                          host: exactly f4's own ci/build-portable-qt-linux.sh --
                                requires root inside literally Ubuntu 18.04 (their
                                own glibc-2.27-pinning method). Kept as an option
                                for side-by-side verification against upstream's
                                own claims, not because it's the recommended path.
                          zig:  this project's own glibc baseline pin
                                (zig cc -target x86_64-linux-gnu.2.27), the same
                                technique already used for far2l. No root, no
                                container, no specific host OS -- Conan already
                                supports pointing it at an arbitrary compiler
                                binary (tools.build:compiler_executables), so the
                                same Conan recipe f4's own maintainers wrote runs
                                unmodified, just compiled by a different toolchain.
                                One real gap, found running this for real: a few
                                of Conan's own "system" packages (egl/system,
                                opengl/system, xorg/system, xkeyboard-config/
                                system -- these are the ABI-stable, host-provided
                                libraries this project's own doctrine already
                                treats specially, not things we vendor) check for
                                dev headers via apt and need root to auto-install
                                them. Rather than fail deep in a Qt subbuild with
                                a permission error, this path uses Conan's
                                tools.system.package_manager:mode=check, which
                                lists exactly what's missing instead of trying to
                                install it -- install those with your own `sudo
                                apt install ...` once (they're small, common
                                desktop dev headers), then re-run.
  -h, --help              this message
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --config)      CONFIG=${2:-}; shift 2 ;;
        --src)         SRC=${2:-}; shift 2 ;;
        --out)         OUT=${2:-}; shift 2 ;;
        --pin)         PIN=${2:-}; shift 2 ;;
        --fetch)       FETCH=1; shift ;;
        --no-fetch)    FETCH=0; shift ;;
        --print-plan)  PRINT_PLAN=1; shift ;;
        --gallery)     GALLERY=${2:-}; shift 2 ;;
        --toolchain)   TOOLCHAIN=${2:-}; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *)
            echo "error: unknown option '$1'" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "${CONFIG}" in
    linux|windows) ;;
    "")
        echo "error: --config is required (linux or windows)" >&2
        exit 2
        ;;
    *)
        echo "error: --config must be linux or windows (got '${CONFIG}')" >&2
        exit 2
        ;;
esac

case "${TOOLCHAIN}" in
    host|zig) ;;
    *)
        echo "error: --toolchain must be host or zig (got '${TOOLCHAIN}')" >&2
        exit 2
        ;;
esac

if [ "${TOOLCHAIN}" = "zig" ] && [ "${CONFIG}" = "windows" ]; then
    echo "error: --toolchain zig is only implemented for --config linux so far." >&2
    echo "       Windows still needs --toolchain host (pwsh + MSVC)." >&2
    exit 2
fi

# ZoinGallery is now public (verified by anonymous `git ls-remote`), so
# --gallery public is the working default and needs no credentials. The
# submodule URL in f4's .gitmodules is still the SSH form, which is what
# fails anonymously; the clone step below rewrites it to https.
#
# --gallery off is gone. It never worked and could not have: it exported
# F4_NO_GALLERY as an environment variable, nothing ever read it, and f4
# has no such CMake option at this pin -- the ZoinGallery check in
# qt/host/CMakeLists.txt:55 is unconditional. It also should not be made
# to work. f4-qt is an image viewer; 53 references across main.cpp, two
# test targets and three QML files are not a feature flag, they are the
# application. A build with the gallery removed would not be the artifact
# this reference build exists to reproduce.
if [ -n "${GALLERY}" ] && [ "${GALLERY}" != "public" ]; then
    echo "error: --gallery '${GALLERY}' is not supported." >&2
    echo "       Only --gallery public exists now; ZoinGallery is public and" >&2
    echo "       is fetched over https. See 05-REFERENCE-f4-qt.md §7.8." >&2
    exit 2
fi


# libGL is deliberately ABSENT from this list, and that is the point.
#
# contrib/f4-qt/optional-gl.cmake removes it from DT_NEEDED entirely, so
# a correct build never needs it allowed. Leaving it allowed "just in
# case" would have been worse than useless: an allowlisted soname is
# reported by nothing, so a build where the forwarder silently stopped
# applying would pass the audit and we would have no evidence either way.
# Omitted, the property is enforced -- if libGL ever comes back as a
# load-time dependency, OB0010 says so by name.
#
# The host GUI contract, named once.
#
# Profile H exists precisely so a binary can be static in everything
# except a small, declared set of host libraries. onebin's default
# allowlist covers the C runtime only, so the first audit that read the
# binary reported 18 x OB0010 -- one per GUI library. They are not
# accidents, and the fix is to state the contract rather than to widen
# the profile:
#
#   libX11, libxcb   the display connection. Qt's xcb platform plugin --
#   libX11-xcb       the one imported in contrib/f4-qt/import-qt-static-
#                    plugins.cmake -- links the xcb helper libraries
#   libxcb-*         directly; they are its published dependencies, not
#                    ours.
#   libICE, libSM    X11 session management, pulled in by the same plugin.
#
# Deliberately NOT here: fontconfig, freetype, harfbuzz, ssl, zlib and the
# image codecs. Those are linked statically out of the Conan graph, and
# if one ever appears in this list it means something stopped being
# static -- so the list failing to cover a new soname is a signal worth
# having, not a nuisance to silence with a wildcard.
F4_QT_HOST_CONTRACT="libX11.so.6 libX11-xcb.so.1 libxcb.so.1 \
libxcb-cursor.so.0 libxcb-icccm.so.4 libxcb-image.so.0 libxcb-keysyms.so.1 \
libxcb-randr.so.0 libxcb-render.so.0 libxcb-render-util.so.0 \
libxcb-shape.so.0 libxcb-shm.so.0 libxcb-sync.so.1 libxcb-xfixes.so.0 \
libxcb-xkb.so.1 libICE.so.6 libSM.so.6"

f4_qt_allow_flags() {
    for _soname in ${F4_QT_HOST_CONTRACT}; do
        printf -- '--allow %s ' "${_soname}"
    done
}

plan_step() {
    if [ "${PRINT_PLAN}" -eq 1 ]; then
        printf '%s\n' "$1" | sed "s#${REPO_ROOT}#<repo>#g"
        return 0
    fi
    printf '+ %s\n' "$1" >&2
    eval "$1"
}

# 0. Read deps.lock
# shellcheck disable=SC2034  # hash/url documented, matched for readability, not used further here
while IFS=' ' read -r name ver hash url; do
    case "$name" in
        ""|\#*) continue ;;
        *) plan_step "# Dependency from deps.lock: $name $ver" ;;
    esac
done < "$DEPS_LOCK"

# 1. Resolve source
if [ "${FETCH}" -eq 1 ]; then
    plan_step "git clone https://github.com/Zoinen/f4 ${SRC}"
    plan_step "git -C ${SRC} checkout ${PIN}"
elif [ "${PRINT_PLAN}" -eq 0 ] && [ ! -d "${SRC}" ]; then
    echo "error: source tree '${SRC}' not found and --no-fetch is set." >&2
    echo "       run again with --fetch to clone, or point --src at an existing checkout." >&2
    exit 1
fi

# ZoinGallery, unconditionally -- NOT inside the --fetch branch above.
# That was the first attempt at this fix and it never ran: CI clones f4 in
# its own workflow step and calls this script with --no-fetch, so the
# whole graph rebuilt for well over an hour and then f4's configure
# aborted with "ZoinGallery submodule is missing" exactly as before. What
# the script needs is for the submodule to be present in whatever tree it
# has been handed, however that tree arrived.
#
# f4 pins the submodule by SSH URL (git@github.com:Zoinen/ZoinGallery),
# which fails for anyone without a key even though the repository is
# public. The rewrite is passed with `git -c` rather than written with
# `submodule set-url`, so a checkout the caller owns is not left with
# modified config afterwards. Confirmed anonymously: this checks out
# 65d851c5, the commit f4 pins at PIN 1a03511a. Re-running is a no-op.
plan_step "git -C ${SRC} -c url.\"https://github.com/\".insteadOf=\"git@github.com:\" submodule update --init --recursive --depth 1"

# Fail here, not an hour and a half later inside f4's configure. The
# preceding step is the only thing that can put this file in place, so if
# it is still absent something changed upstream and every minute spent
# building Qt afterwards is wasted.
if [ "${PRINT_PLAN}" -eq 0 ] && [ ! -f "${SRC}/third_party/ZoinGallery/CMakeLists.txt" ]; then
    echo "error: ZoinGallery submodule is still missing after checkout." >&2
    echo "       expected ${SRC}/third_party/ZoinGallery/CMakeLists.txt" >&2
    echo "       see 05-REFERENCE-f4-qt.md §7.8" >&2
    exit 1
fi

# 2. Build setup
export F4_PORTABLE_STATIC=ON

plan_step "mkdir -p ${OUT}"

# Absolute form of --out. Most uses of ${OUT} are fine relative, because
# they run from this script's own working directory, but anything handed
# to Conan as a *flag* is re-evaluated inside each package's own build
# folder under ~/.conan2/p/b/..., where a relative path silently resolves
# to nothing. Done by string, not by `cd`, so --print-plan still works
# before the directory exists.
case "${OUT}" in
    /*) OUT_ABS="${OUT}" ;;
    *)  OUT_ABS="$(pwd)/${OUT#./}" ;;
esac

# 3. Build, Audit, and Smoke Test
if [ "${CONFIG}" = "linux" ] && [ "${TOOLCHAIN}" = "host" ]; then
    plan_step "cd ${SRC} && ci/build-portable-qt-linux.sh"

    plan_step "cp ${SRC}/f4 ${OUT}/f4"
    plan_step "cp ${SRC}/embedded/f4-qt-host.gz ${OUT}/"

    # Profile H, not S: goffi makes f4 dynamic on the C runtime by
    # construction (see the go build step). Contract is exactly
    # libc/libdl/libpthread, and through the hygiene wrapper for the
    # OB0060 build-path strings from prebuilt Go modules (colorer4go).
    plan_step "${REPO_ROOT}/tools/audit-with-hygiene-waivers.sh ${ONEBIN_BIN} --profile hybrid --glibc-max ${GLIBC_BASELINE} --allow libc.so.6 --allow libdl.so.2 --allow libpthread.so.0 --level 1 --strict ${OUT}/f4"
    # Through tools/audit-with-hygiene-waivers.sh, not onebin directly.
    # The host audit reaches 0 errors and fails --strict only on OB0060
    # build-path warnings baked into prebuilt Qt and libheif archives --
    # third-party strings in .rodata that never touch DT_NEEDED or
    # RUNPATH, so they do not affect portability. The wrapper tolerates
    # exactly those, by third-party origin, and fails on anything else
    # including an OB0060 path from our own code. It fails STALE once the
    # dependencies stop embedding the paths, so the tolerance removes
    # itself.
    plan_step "${REPO_ROOT}/tools/audit-with-hygiene-waivers.sh ${ONEBIN_BIN} --profile hybrid --glibc-max 2.27 $(f4_qt_allow_flags)--level 1 --strict ${SRC}/build-qt/f4-qt-host"

    plan_step "timeout --kill-after=30s 120s env QT_QPA_PLATFORM=offscreen QSG_RHI_BACKEND=software ${SRC}/build-qt/f4-qt-host --f4-ext-connect=127.0.0.1:1 > ${OUT}/smoke.log 2>&1 || [ \$? -eq 2 ]"
    plan_step "! grep -q 'QQmlApplicationEngine failed to load component' ${OUT}/smoke.log"
    plan_step "! grep -q 'Could not find the Qt platform plugin' ${OUT}/smoke.log"

elif [ "${CONFIG}" = "linux" ] && [ "${TOOLCHAIN}" = "zig" ]; then
    # Diagnostics audit (prompted directly by losing a real CI cycle to
    # a hook that silently never fired, with no way to tell why from the
    # log alone): -vv on the conan install below, and the diagnostic-log
    # collection in f4-qt-zig-build.yml, both exist because of this
    # audit, not because either failure had already happened once
    # before being fixed. -vv is *more* verbose than Conan's own default
    # (the real ascending order, confirmed against Conan's own docs:
    # quiet < error < warning < notice < status (default) < verbose <
    # debug/-vv < trace/-vvv) -- an earlier version of this line used
    # -vnotice, which is actually *less* verbose than default and would
    # have suppressed output rather than surfaced more of it; caught and
    # fixed before it shipped, not after another wasted CI cycle.
    #
    # A parallel reimplementation of ci/build-portable-qt-linux.sh's
    # essential steps, not a call into it — their script hard-refuses to
    # run outside literally root-in-Ubuntu-18.04, which is exactly the
    # container dependency this path exists to avoid. Confirmed feasible
    # in this project's own sandbox before writing this: a minimal
    # Conan+CMakeToolchain project, compiler_executables pointed at these
    # same zig-cc/zig-c++ wrappers plus -target x86_64-linux-gnu.2.27 in
    # tools.build:cflags/cxxflags/exelinkflags, configures, builds, runs,
    # and onebin audit --profile hybrid --glibc-max 2.27 on the result
    # comes back PASS Level 1 with "glibc: requires GLIBC_2.16, baseline
    # 2.27" -- the mechanism itself is proven, not theorized. The full
    # ~35-package Qt dependency stack has not been built end to end this
    # way yet -- that is the next real step, not this one.
    #
    # glib/*:with_mount=False (in the conan install invocation below)
    # sidesteps a real, confirmed-open upstream zig bug
    # (ziglang/zig#22765) instead of patching around it: zig's bundled
    # headers unconditionally declare close_range()/statx() as extern
    # regardless of the pinned -target glibc version, colliding with
    # util-linux/libmount's own configure-detected static-inline
    # fallbacks for those same functions ("static declaration ... follows
    # non-static declaration"). glib's own ConanCenter recipe gates its
    # libmount dependency behind exactly this option (used only for
    # gio's Unix mount-point monitoring, which f4-qt's own Qt-based code
    # never touches) -- confirmed by reading glib's actual recipe
    # source, not guessed. Disabling it removes libmount from the
    # dependency graph entirely, sidestepping the zig bug rather than
    # fighting it. (STATUS.md also records a scoped, verified-safe
    # -DHAVE_CLOSE_RANGE=1 fix kept below as defense in depth, and why an
    # equivalent -DHAVE_STATX=1 was tried and reverted as unsafe -- moot
    # now that libmount shouldn't be pulled in at all, but harmless to
    # leave in case some other package's option matrix still needs it.)
    #
    # glib/*:with_elf=False -- same pattern, this time sidestepping
    # elfutils rather than keep chasing its own internal bugs (a real
    # duplicate-symbol collision with zlib's crc32, already fixed via a
    # Conan post_source hook that patches lib/crc32.c directly -- see
    # STATUS.md for that whole chase). glib's actual recipe source
    # confirms elfutils is only pulled in for the `gresource` CLI tool
    # (embeds resources into ELF sections, a GNOME/GLib build
    # convention f4-qt's own Qt-based code has no reason to touch),
    # gated behind exactly this option. Open question, not yet
    # resolved: raised directly with f4's own upstream maintainer why
    # this Qt build needs glib at all -- Qt's own recipe defaults
    # with_glib to False and only requires glib when explicitly turned
    # on, which this project's own build command never does, yet
    # upstream's official build script *also* force-builds glib from
    # source, meaning something in the graph still needs it for a
    # reason not yet traced. This with_elf=False fix is safe regardless
    # of that answer (harmless no-op if glib turns out unnecessary,
    # useful if it stays) -- not blocking on the answer to keep it.
    #
    # harfbuzz/*:with_glib=False -- traced the actual "who requires
    # glib" question further while waiting on that upstream reply, and
    # found a real, well-evidenced answer, not another guess: multiple
    # independent real users' Conan dependency-graph dumps
    # (conan-center-index issues #9794, #19632, #20383, #27705, all
    # unrelated to this project) show glib appearing in *every* Qt
    # build's graph specifically alongside harfbuzz -- and ConanCenter's
    # own harfbuzz recipe page confirms with_glib=True as harfbuzz's
    # own default, on every platform. f4-qt's own CMakeLists.txt
    # (checked directly against the pinned commit) never touches glib
    # or harfbuzz itself, only Qt6's Core/Gui/Qml/Quick/QuickControls2/
    # Network/Svg components -- harfbuzz comes in unavoidably via Qt's
    # own text-shaping needs (Gui module), but harfbuzz's glib
    # integration (hb-glib.h, GLib-type conversion helpers) is a
    # convenience layer for GLib-based *callers* of harfbuzz, not
    # something Qt's own C-API usage of harfbuzz depends on. Likely the
    # real, complete answer -- not verified with a live `conan graph
    # info` resolution, since that isn't available in this sandbox, so
    # kept alongside (not instead of) the with_elf=False/crc32-hook
    # fixes as defense in depth rather than assumed sufficient alone.
    #
    # PKG_CONFIG_PATH prefix on the main conan install: a real CI run
    # got past elfutils/glib/harfbuzz entirely (confirming those fixes
    # worked) and reached a new, unrelated failure -- xkbcommon's own
    # X11 variant failing to find <xcb/xkb.h>, from the `xorg/system`
    # Conan package's pkg-config-based discovery of the host's XCB
    # extension headers. Checked directly, not guessed: libxcb-xkb-dev
    # (which genuinely does provide this exact header on Debian/Ubuntu,
    # confirmed via dpkg-query -L) is already in this workflow's own
    # apt-get install list, and plain `pkg-config --exists xcb-xkb`
    # succeeds cleanly when tested directly against a real installed
    # libxcb-xkb-dev -- the package and its .pc file are both genuinely
    # present and correctly registered. The likely remaining gap:
    # whatever PKG_CONFIG_PATH Conan's own generators construct for this
    # package's build environment may not include the system's default
    # pkgconfig directories, since Conan-managed builds commonly curate
    # an explicit path pointing only at Conan-provided .pc files to
    # avoid accidentally picking up the wrong version of something --
    # plausible but not confirmed against a live run yet. This
    # explicitly prepends the standard Debian/Ubuntu multiarch pkgconfig
    # locations (additively, preserving whatever Conan's own value
    # already is via the trailing $PKG_CONFIG_PATH) rather than assuming
    # they're already reachable.
    #
    # CMAKE_LIBRARY_ARCHITECTURE=x86_64-linux-gnu: the second, worse
    # consequence of that same broken ABI detection, and the thing that
    # blocked Qt itself. CMake normally derives this from the compiler's
    # ABI info; with zig-cc it comes out EMPTY (seen directly in Qt's own
    # generated CMakeFiles/<ver>/CMakeCCompiler.cmake:
    # `set(CMAKE_LIBRARY_ARCHITECTURE "")`). find_library() builds its
    # search paths from it, so with it empty CMake never looks in
    # /usr/lib/x86_64-linux-gnu -- which is exactly where Debian/Ubuntu
    # multiarch puts libGL.so and libEGL.so. Qt then reported
    # `WrapOpenGL_FOUND = "FALSE"` / `EGL_FOUND = "FALSE"` and refused to
    # configure, because this project forces qt:with_egl=True.
    #
    # Proven, not inferred: reproduced locally with real zig 0.13.0 and
    # a two-line CMake project doing find_library(z). With zig-cc as the
    # compiler, CMAKE_LIBRARY_ARCHITECTURE came out '' and the lookup
    # returned NOTFOUND even though /usr/lib/x86_64-linux-gnu/libz.so
    # exists; adding this one variable made the same lookup succeed.
    # (Testing it against the host gcc first was misleading -- gcc's ABI
    # detection sets the variable itself and silently overrode the -D.)
    #
    # Only correct because this build targets x86_64 Linux exclusively.
    # Note this deliberately lets CMake see host libraries in the
    # multiarch dir: that is the intent for Layer-1 host-contract
    # libraries like libGL/libEGL. Conan's own toolchain still puts its
    # package paths ahead of system ones, so vendored dependencies are
    # not expected to be shadowed by host copies -- worth watching if a
    # dependency ever resolves to an unexpected host library.
    #
    # CMAKE_SIZEOF_VOID_P=8: CMake's own "Detecting C/CXX compiler ABI
    # info" step -- which normally populates this variable by
    # introspecting a small compiled test program -- fails with zig-cc
    # ("Detecting C compiler ABI info - failed", visible in every
    # package's configure log throughout this whole build, harmless
    # everywhere else since nothing else reads the variable). libjpeg-
    # turbo's own CMakeLists.txt is the first package in this chain that
    # actually computes a bit-width from it (`math(EXPR ... "${CMAKE_
    # SIZEOF_VOID_P} * 8")`), and an empty value breaks that expression
    # outright ("math cannot parse the expression: \" * 8\""). Since this
    # whole build only ever targets one architecture (x86_64), forcing
    # the one genuinely correct value here carries no ambiguity --
    # unlike the statx situation earlier, there's no second architecture
    # this could quietly be wrong for.
    #
    # -pie/-shared conflicts (openssl's providers/legacy.so, elfutils'
    # own __thread-support configure probe): tried package-scoped Conan
    # conf overrides first (tools.build:exelinkflags scoped to just the
    # affected package). Worked for openssl, confirmed directly NOT to
    # take effect for elfutils' own early configure probe (verified from
    # its real config.log, not assumed) -- different build systems
    # (OpenSSL's own Configure/Makefile vs. plain GNU autotools)
    # evidently pull LDFLAGS from Conan's generated files at different
    # points, and a package-scoped conf doesn't reliably reach all of
    # them. Fixed properly instead, unconditionally, in
    # onebin/toolchain/zig-cc and zig-c++ themselves: -pie and -shared
    # are never simultaneously valid for any package this project could
    # build, so both wrappers now drop -pie whenever -shared is also
    # present, regardless of which package is being compiled. No
    # per-package overrides needed here any more.
    #
    # elfutils/zlib crc32 duplicate-symbol collision: a real, confirmed
    # upstream bug in elfutils itself (lib/crc32.c's own `crc32`
    # function has no `static`/hidden-visibility marking, checked
    # directly against elfutils' actual source), not something specific
    # to our toolchain. It only surfaces when statically combining
    # elfutils' own libeu.a (which contains this internal helper) with
    # zlib's libz.a into the same final .so ("ld.lld: error: duplicate
    # symbol: crc32") -- with dynamic linking only one of the two ever
    # gets resolved at runtime, so upstream never had reason to notice.
    #
    # Tried telling the linker to simply tolerate it first
    # (-Wl,--allow-multiple-definition, then -Wl,-z,muldefs after the
    # first turned out to be its own separate zig cc bug --
    # ziglang/zig#21455) -- both rejected outright by zig cc's own
    # narrow -Wl,/-z allowlist ("unsupported linker arg" /
    # "unsupported linker extension flag"), confirmed against two real
    # CI runs, not guessed. Rather than keep guessing at flag spellings
    # zig cc might happen to accept -- a real cost, each attempt is a
    # full CI cycle -- fixed at the actual root instead: a Conan
    # post_source hook (conan.io/2.0/reference/extensions/hooks.html)
    # patches elfutils' own lib/crc32.c to add `static` right after its
    # source is fetched, before build() runs. This is the correct
    # upstream-shaped fix (the function was never meant to be
    # externally visible), works regardless of which linker flags zig
    # cc's driver happens to recognize, and doesn't risk masking a
    # genuine duplicate-symbol bug in some other package the way a
    # project-wide --allow-multiple-definition-equivalent would.
    # glibc compat shims. zig cc's -target versions the symbol stubs but
    # not the headers, so a bare `#ifdef` on a kernel-header macro sees a
    # glibc newer than the 2.27 that will be linked against, emits the
    # call, and fails at link time. Two so far, both in Qt and both the
    # same shape: statx() (2.28) behind STATX_BASIC_STATS, and
    # close_range() (2.34) behind CLOSE_RANGE_CLOEXEC. Full reasoning, evidence
    # and the alternatives considered are in contrib/f4-qt/compat/glibc-shims.c
    # and STATUS.md. Compiled here, ahead of `conan install`, because the
    # object has to exist before Conan starts building anything.
    #
    # CMAKE_SKIP_RPATH: the first audit that could actually read the
    # binary reported 48 errors, and 47 of them were one thing --
    #
    #   OB0040  search path component is not $ORIGIN-relative:
    #           /home/runner/.conan2/p/b/qtf24b8750aaa73/p/lib
    #
    # CMake records the directory of every shared library it links as a
    # build rpath, so a binary meant to run anywhere carried a list of
    # absolute paths from the machine that built it. For a static
    # artefact none of them is needed at runtime, and each one is both a
    # portability hazard and a leak of the build environment.
    #
    # Verified against real CMake and the real wrappers: a probe linking
    # a shared library from a non-standard directory gets that directory
    # in DT_RUNPATH, and with this variable set it does not.

    # -Wl,--strip-debug on both lists: zig cc emits DWARF whether or not
    # anyone asked for it. Measured, not assumed -- compiling a trivial
    # file with `-O2` and no `-g` still produces .debug_info,
    # .debug_abbrev, .debug_line and .debug_str, and `-g0` barely dents
    # it because zig's own startup objects carry debug info too. At this
    # scale it stops being cosmetic: the Qt package's static archives
    # total 3.5 GB and f4-qt-host came out at 708 MB, past the auditor's
    # 512 MiB input limit, so nothing downstream could even be examined.
    #
    # --strip-debug, not --strip-all: it removes DWARF and keeps .symtab,
    # so crashes still symbolise. Verified that a stripped binary keeps
    # .dynsym and .gnu.version_r, which is what the glibc-baseline audit
    # actually reads.
    #
    # In the GLOBAL exe and shared link flags, not scoped to `qt/*`.
    # It was scoped for a while, and that was wrong in an instructive
    # way. Scoping does fix the symptom it was introduced for -- an
    # object file in a flag list is not idempotent, and openssl replays
    # its LDFLAGS three times over, which is fine for flags and a
    # duplicate symbol for an object. But Qt is *not* the only package
    # that needs the shim: Qt is where the call is compiled, and
    # libQt6Core.a then carries the unresolved reference into every
    # downstream link. Scoping it to qt/* left the final link of
    # f4-qt-host without it, and the build died on `undefined symbol:
    # statx` after everything else had succeeded.
    #
    # Global injection is safe now because the real fix for openssl was
    # the other half: every symbol in the shim is __attribute__((weak)),
    # so repeated copies collapse instead of colliding. Verified against
    # real zig for each shape that matters -- an executable and a shared
    # library each linking the object three times, a shared link with
    # -z defs, and a consumer linking a static archive that references
    # statx and close_range with the shim supplied only through linker
    # flags.
    #
    # sharedlinkflags matters as much as exelinkflags here, and more
    # quietly: a shared library with an unresolved statx links without
    # complaint and fails at runtime instead.
    plan_step "${ZIGCC} -target x86_64-linux-gnu.${GLIBC_BASELINE} -O2 -fPIC -c ${REPO_ROOT}/contrib/f4-qt/compat/glibc-shims.c -o ${OUT_ABS}/compat-glibc-shims.o"

    plan_step "mkdir -p \$HOME/.conan2/extensions/hooks"
    plan_step "cat > \$HOME/.conan2/extensions/hooks/hook_elfutils_crc32.py << 'HOOKEOF'
# static-everywhere: elfutils' own lib/crc32.c defines \`crc32\` with no
# static/hidden-visibility marker, colliding with zlib's own public
# crc32() once both land statically in the same final .so. Real upstream
# gap (harmless under dynamic linking, where only one ever resolves at
# runtime), not a toolchain quirk -- see STATUS.md. Patching \`static\`
# onto the definition here is the correct fix, applied once right after
# Conan fetches elfutils' source, before its own build() runs.
#
# The first attempt at this hook silently never fired (confirmed: none
# of its own output messages appeared anywhere in a real CI log, and
# the crc32 collision was unchanged) -- diagnostic prints added below,
# both at module-import time (fires the instant Conan loads this file
# at all, regardless of whether post_source ever runs for any package)
# and unconditionally inside post_source for *every* package (not just
# elfutils), to tell apart \"Conan never loads hook files from here\"
# from \"it loads fine but this specific condition/logic has a bug\" on
# the next run, rather than guessing a second time blind.
import os
import sys
import traceback

# Module-level: fires the instant Conan imports this file at all,
# before any function runs. Both a raw stderr print (visible if Conan
# forwards hook stdout/stderr directly) and, once a conanfile is
# available inside post_source, conanfile.output calls too (Conan's
# own documented, guaranteed-visible hook-output mechanism, prefixed
# [HOOK - hook_elfutils_crc32] in its own log format) -- not relying
# on only one of the two now that it's confirmed the first version's
# raw-print-only approach produced zero visible output in a real run.
sys.stderr.write(\"static-everywhere hook: hook_elfutils_crc32.py module loaded\\n\")
sys.stderr.flush()

def post_source(conanfile):
    try:
        sys.stderr.write(f\"static-everywhere hook: post_source() entered for {conanfile.name}\\n\")
        sys.stderr.flush()
        conanfile.output.info(f\"static-everywhere hook: post_source() entered for {conanfile.name}\")
        if conanfile.name != \"elfutils\":
            return
        path = os.path.join(conanfile.source_folder, \"lib\", \"crc32.c\")
        conanfile.output.info(f\"static-everywhere hook: checking {path}\")
        if not os.path.exists(path):
            conanfile.output.warning(\"static-everywhere hook: lib/crc32.c not found, elfutils layout may have changed, skipping\")
            return
        with open(path, \"r\", encoding=\"utf-8\") as f:
            content = f.read()
        old = \"uint32_t\ncrc32 (uint32_t crc, unsigned char *buf, size_t len)\"
        new = \"static uint32_t\ncrc32 (uint32_t crc, unsigned char *buf, size_t len)\"
        if old not in content:
            conanfile.output.warning(\"static-everywhere hook: expected crc32.c pattern not found, elfutils source may have changed, skipping\")
            return
        content = content.replace(old, new, 1)
        with open(path, \"w\", encoding=\"utf-8\") as f:
            f.write(content)
        conanfile.output.info(\"static-everywhere hook: patched elfutils lib/crc32.c (added static -- avoids link collision with zlib's own crc32 under fully static linking)\")
    except Exception:
        # A hook-internal exception must never be able to disappear
        # silently -- print the full traceback through every channel
        # available rather than assume Conan's own hook-exception
        # handling will surface it loudly on its own.
        tb = traceback.format_exc()
        sys.stderr.write(f\"static-everywhere hook: EXCEPTION in post_source:\\n{tb}\\n\")
        sys.stderr.flush()
        try:
            conanfile.output.error(f\"static-everywhere hook: EXCEPTION in post_source: {tb}\")
        except Exception:
            pass
        raise
HOOKEOF"
    plan_step "mkdir -p ${OUT}/conan-venv"
    plan_step "command -v uv >/dev/null 2>&1 || { echo 'error: uv not found -- https://astral.sh/uv' >&2; exit 1; }"
    plan_step "uv venv --python 3.12 --clear ${OUT}/conan-venv"
    plan_step "uv pip install --python ${OUT}/conan-venv/bin/python 'conan==2.29.1' 'cmake==3.31.6' 'ninja==1.13.0'"

    plan_step "env PATH=\"${OUT}/conan-venv/bin:\$PATH\" conan profile detect --force"

    # Real, concrete diagnosis of why the crc32 hook never fired despite
    # loading correctly (confirmed via -vv: "hook_elfutils_crc32.py
    # module loaded" appears in the log, but post_source() itself never
    # does, for elfutils or anything else): this project's own
    # actions/cache restore step brings back elfutils' already-fetched
    # source from an earlier CI attempt (predating this hook's own
    # existence), and Conan correctly treats already-cached source as
    # not needing source() re-invoked -- which means post_source()
    # never runs either, on this run or any future one, for as long as
    # that cached source folder persists. Force elfutils' source to be
    # re-fetched by removing just it from the cache immediately before
    # the real install -- `-c` for non-interactive, scoped to elfutils
    # only so the other ~34 packages' cached progress is untouched.
    plan_step "env PATH=\"${OUT}/conan-venv/bin:\$PATH\" conan remove 'elfutils/*' -c || true"

    plan_step "cd ${SRC} && git config --global --add safe.directory \"\$PWD\""

    # Same fontconfig-recipe-URL workaround as upstream's own script
    # (freedesktop.org rejects some CI IP ranges with HTTP 418) -- kept
    # verbatim, this has nothing to do with which compiler is used.
    plan_step "cd ${SRC} && env PATH=\"${OUT}/conan-venv/bin:\$PATH\" conan download fontconfig/2.15.0 --only-recipe --remote=conancenter"

    # CMAKE_*_IMPLICIT_INCLUDE_DIRECTORIES: CMake could not detect them
    # under zig-cc -- CMakeCXXCompiler.cmake in a real failing build reads
    # `set(CMAKE_CXX_IMPLICIT_INCLUDE_DIRECTORIES "")` -- so CMake stopped
    # filtering /usr/include out of target include lists and emitted it
    # explicitly. CMake's own FindBacktrace sets Backtrace_INCLUDE_DIR to a
    # bare /usr/include, Qt Core links Backtrace::Backtrace, and imported
    # targets' includes are emitted as -isystem in link order -- so Core
    # compiled with `-isystem /usr/include` sitting *ahead* of the vendored
    # `-isystem <icu>/include`. Result: Qt compiled against the host's ICU
    # 74 headers and linked against Conan's ICU 78 archives, failing with
    # 26 undefined `*_74` symbols. Declaring the directory implicit is not
    # a fiction: the zig-cc/zig-c++ wrappers append `-idirafter
    # /usr/include`, so it genuinely is a lowest-priority implicit search
    # path for this compiler. This is the same underlying defect as the
    # empty CMAKE_LIBRARY_ARCHITECTURE -- CMake cannot introspect zig-cc --
    # and it protects every vendored library whose headers also exist on
    # the host, not just ICU.
    #
    # Same target_packages list as upstream: every package the target
    # actually links against gets rebuilt regardless of remote binary
    # availability, because Conan package IDs don't encode the glibc
    # baseline this pass exists to pin.
    plan_step "cd ${SRC} && env PATH=\"${OUT}/conan-venv/bin:\$PATH\" PKG_CONFIG_PATH=\"/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig:\${PKG_CONFIG_PATH:-}\" conan install qt/host \
--build=missing --build='m4/*' \
--build='brotli/*' --build='bzip2/*' --build='double-conversion/*' --build='elfutils/*' \
--build='expat/*' --build='fontconfig/*' --build='freetype/*' --build='glib/*' \
--build='harfbuzz/*' --build='icu/*' --build='jasper/*' --build='lcms/*' --build='libde265/*' \
--build='libffi/*' --build='libheif/*' --build='libiconv/*' --build='libjpeg-turbo/*' \
--build='libmount/*' --build='libpng/*' --build='libraw/*' --build='libselinux/*' \
--build='libtiff/*' --build='libwebp/*' --build='libxml2/*' --build='md4c/*' \
--build='msgpack-cxx/*' --build='openssl/*' --build='pcre2/*' --build='qt/*' \
--build='sqlite3/*' --build='wayland/*' --build='xkbcommon/*' --build='xz_utils/*' \
--build='zlib/*' --build='zstd/*' \
-s:h build_type=Release -s:h compiler.cppstd=gnu20 \
-s:b build_type=Release -s:b compiler.cppstd=gnu20 \
-o:h 'qt/*:shared=False' -o:h 'qt/*:qtwayland=True' -o:h 'qt/*:with_egl=True' \
-o:h 'glib/*:with_mount=False' \
-o:h 'glib/*:with_elf=False' \
-o:h 'harfbuzz/*:with_glib=False' \
-o:h 'xkbcommon/*:with_wayland=True' -o:h 'libraw/*:shared=False' \
-c 'tools.build:compiler_executables={\"c\":\"${ZIGCC}\",\"cpp\":\"${ZIGCXX}\"}' \
-c 'tools.cmake.cmaketoolchain:extra_variables={\"CMAKE_C_COMPILER_LAUNCHER\":\"ccache\",\"CMAKE_CXX_COMPILER_LAUNCHER\":\"ccache\",\"CMAKE_SIZEOF_VOID_P\":\"8\",\"CMAKE_LIBRARY_ARCHITECTURE\":\"x86_64-linux-gnu\",\"CMAKE_C_IMPLICIT_INCLUDE_DIRECTORIES\":\"/usr/include\",\"CMAKE_CXX_IMPLICIT_INCLUDE_DIRECTORIES\":\"/usr/include\",\"CMAKE_SKIP_RPATH\":\"ON\"}' \
-c 'tools.build:cflags=[\"-target\",\"x86_64-linux-gnu.${GLIBC_BASELINE}\"]' \
-c 'tools.build:cxxflags=[\"-target\",\"x86_64-linux-gnu.${GLIBC_BASELINE}\"]' \
-c 'libmount*:tools.build:cflags=[\"-DHAVE_CLOSE_RANGE=1\"]' \
-c 'tools.build:sharedlinkflags=[\"-target\",\"x86_64-linux-gnu.${GLIBC_BASELINE}\",\"${OUT_ABS}/compat-glibc-shims.o\",\"-Wl,--strip-debug\"]' \
-c 'tools.build:exelinkflags=[\"-target\",\"x86_64-linux-gnu.${GLIBC_BASELINE}\",\"-pie\",\"${OUT_ABS}/compat-glibc-shims.o\",\"-Wl,--strip-debug\"]' \
-cc core.sources:download_cache=\"${OUT_ABS}/sources-backup\" \
-cc core.sources:download_urls='[\"https://c3i.jfrog.io/artifactory/conan-center-backup-sources/\",\"origin\"]' \
-c tools.system.package_manager:mode=check \
-vv \
--output-folder=qt/host/build-portable-linux"

    # NOT --source. That was here for one run and cost a full CI cycle:
    # CI caches ~/.conan2/p, which is where the extracted sources live, so
    # deleting them before the cache is saved forces the *next* run to
    # re-download every upstream tarball. One of them -- fontconfig from
    # freedesktop.org -- answered HTTP 418, and the build stopped before
    # compiling anything. Sources are a small fraction of the cache and
    # re-fetching them is the fragile part, so they stay.
    #
    # Reclaim the Conan build trees before f4 itself builds. Measured on
    # the run that filled the disk: 26.8GB of Conan cache, of which
    # 16.7GB is build folders (b/) and 10.1GB the packages (p/) that are
    # actually needed from here on. Every dependency is built and packaged
    # by this point, so the build trees are pure residue -- and the
    # previous run died at 144G/145G used with 635M free, immediately
    # after Qt packaged successfully. This also makes the cache that gets
    # saved at the end of CI smaller and faster.
    plan_step "cd ${SRC} && env PATH=\"${OUT}/conan-venv/bin:\$PATH\" conan cache clean '*' --build --temp"

    # Pin qwindowkit. f4's ci/build-qwindowkit.sh does `rm -rf` and then
    # `git clone --branch main`, with no pin -- so an upstream commit to
    # somebody else's default branch can change this artifact at any time
    # and an SBOM covering it would be wrong. Everything else here is
    # pinned; this was the one hole.
    #
    # It cannot be pinned by pre-placing a checkout, because their script
    # deletes the directory first, and patching their script would be the
    # fragile option. Instead: build a tiny bare mirror holding exactly
    # the pinned commit, publish it as `main`, and redirect their clone to
    # it with GIT_CONFIG_* environment variables. Those are ephemeral --
    # no global git config is touched, nothing on disk is edited, and the
    # variables die with the command.
    #
    # The redirect is transparent in the way that matters: git records the
    # *pre-rewrite* URL as origin, so qwindowkit's relative submodule URL
    # (../../stdware/qmsetup.git) still resolves against GitHub. Verified:
    # qmsetup lands on a63c44c9, exactly what the pinned tree records.
    # `fetch --depth 1 <sha>` keeps the mirror at ~4MB.
    plan_step "rm -rf ${OUT_ABS}/qwk-mirror && git init -q --bare ${OUT_ABS}/qwk-mirror"
    plan_step "git -C ${OUT_ABS}/qwk-mirror remote add origin ${QWK_URL}"
    plan_step "git -C ${OUT_ABS}/qwk-mirror fetch -q --depth 1 origin ${QWK_PIN}"
    plan_step "git -C ${OUT_ABS}/qwk-mirror update-ref refs/heads/main ${QWK_PIN}"
    # qwindowkit must be built with the same toolchain as everything
    # else. f4's ci/build-qwindowkit.sh runs a plain `cmake -S ... -B ...`
    # with no compiler settings, so CMake picks the host default -- host
    # g++, and therefore libstdc++ -- while Qt, f4 and every Conan
    # package here are built by zig c++, which uses libc++. The two only
    # meet at the very last link of f4-qt-host, which is exactly where a
    # real CI run failed:
    #
    #   ld.lld: error: undefined symbol:
    #     std::__detail::_List_node_base::_M_hook(...)
    #     std::_Rb_tree_increment(std::_Rb_tree_node_base*)
    #   >>> referenced by abstractwindowcontext.cpp.o
    #
    # Those are libstdc++'s own out-of-line symbols, and
    # abstractwindowcontext.cpp is qwindowkit's. CMake honours CC/CXX and
    # CFLAGS/CXXFLAGS/LDFLAGS on a fresh configure, so setting them on
    # the invocation fixes it without patching f4's script -- the same
    # approach already used here to pin qwindowkit via GIT_CONFIG_*.
    # The -target flags have to be passed explicitly because the wrappers
    # do not add them; everywhere else they arrive via Conan's
    # tools.build:cflags/cxxflags.
    plan_step "cd ${SRC} && env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=url.${OUT_ABS}/qwk-mirror.insteadOf GIT_CONFIG_VALUE_0=${QWK_URL} CC=${ZIGCC} CXX=${ZIGCXX} CFLAGS=\"-target x86_64-linux-gnu.${GLIBC_BASELINE}\" CXXFLAGS=\"-target x86_64-linux-gnu.${GLIBC_BASELINE}\" LDFLAGS=\"-target x86_64-linux-gnu.${GLIBC_BASELINE}\" bash ci/build-qwindowkit.sh \"\$PWD/qt/host/build-portable-linux\" Release static"

    # The redirect above is the prevention; this is the detection, and it
    # is what keeps the arrangement from being fragile. If upstream ever
    # changes the URL their script clones, the rewrite silently stops
    # applying and we would be back to an unpinned dependency without
    # noticing. This turns that into a loud failure.
    plan_step "test \"\$(git -C ${SRC}/build/qwindowkit-src rev-parse HEAD)\" = ${QWK_PIN} || { echo 'error: qwindowkit is not at the pinned commit ${QWK_PIN} -- the GIT_CONFIG_* redirect did not take effect (did upstream change the clone URL?)' >&2; exit 1; }"

    plan_step "cd ${SRC} && cmake -S qt/host -B qt/host/build-portable-linux -G Ninja \
-DCMAKE_TOOLCHAIN_FILE=\"\$PWD/qt/host/build-portable-linux/conan_toolchain.cmake\" \
-DCMAKE_BUILD_TYPE=Release \
-DCMAKE_PREFIX_PATH=\"\$PWD/build/qwindowkit-install\" \
-DQWindowKit_DIR=\"\$PWD/build/qwindowkit-install/lib/cmake/QWindowKit\" \
-DCMAKE_PROJECT_INCLUDE=\"${REPO_ROOT}/contrib/f4-qt/project-include.cmake\" \\
-DBUILD_TESTING=ON -DUSE_QWK=ON -DF4_PORTABLE_STATIC=ON"
    plan_step "cd ${SRC} && cmake --build qt/host/build-portable-linux --config Release --parallel \$(nproc)"
    # Through tools/ctest-with-waivers.sh, not ctest directly. One f4 test
    # case races its own scroll animation and fails under offscreen
    # rendering (report: f4-bugreport-pointer-test-race.md); everything
    # after this step -- the glibc audit, the smoke run, packaging, the
    # final static audit -- would otherwise never be reached. The wrapper
    # waives that ONE named case, still fails on anything else, and fails
    # LOUDLY once the case starts passing, so the workaround removes
    # itself rather than outliving the bug.
    plan_step "cd ${SRC} && ${REPO_ROOT}/tools/ctest-with-waivers.sh --test-dir qt/host/build-portable-linux -C Release --output-on-failure --timeout 300 -R '^(F4|QtShellController|WindowGeometryPersistence)'"

    plan_step "${REPO_ROOT}/tools/audit-with-hygiene-waivers.sh ${ONEBIN_BIN} --profile hybrid --glibc-max ${GLIBC_BASELINE} $(f4_qt_allow_flags)--level 1 --strict ${SRC}/qt/host/build-portable-linux/bin/Release/f4-qt-host"

    plan_step "timeout --kill-after=30s 120s env QT_QPA_PLATFORM=offscreen QSG_RHI_BACKEND=software ${SRC}/qt/host/build-portable-linux/bin/Release/f4-qt-host --f4-ext-connect=127.0.0.1:1 --f4-ext-nonce=ci-smoke > ${OUT}/smoke.log 2>&1 || [ \$? -eq 2 ]"
    plan_step "! grep -q 'QQmlApplicationEngine failed to load component' ${OUT}/smoke.log"
    plan_step "! grep -q 'Could not find the Qt platform plugin' ${OUT}/smoke.log"

    plan_step "cd ${SRC} && python ci/package-embedded-qt-host.py qt/host/build-portable-linux/bin/Release/f4-qt-host"
    plan_step "cd ${SRC} && go test -tags f4_embedded_qt_host -run 'TestMaterializeEmbeddedQtHost|TestGeneratedEmbeddedQtHostPayload' ."
    plan_step "mkdir -p ${SRC}/dist/f4-linux-amd64"
    # -buildmode=pie and -bindnow are load-bearing, not cosmetic.
    #
    # f4 is built without cgo and reaches system libraries through goffi,
    # whose fakecgo path uses //go:cgo_import_dynamic. That makes the Go
    # linker emit PT_INTERP and DT_NEEDED even under CGO_ENABLED=0, so the
    # binary is dynamic by construction and audited as Profile H. A
    # dynamic binary must carry RELRO and BIND_NOW or the audit fails
    # OB0050/OB0051, both ERROR, and ET_EXEC additionally warns OB0054
    # (no ASLR).
    #
    # External linking would supply them but requires cgo, which f4 avoids
    # on purpose. Go's internal linker does both alone: -buildmode=pie
    # emits PT_GNU_RELRO and makes the file ET_DYN, and the linker flag
    # -bindnow sets DT_BIND_NOW and DF_1_NOW. Verified on Go 1.27 with
    # goffi 0.6.3, and asserted against this very line by
    # tools/test-goffi-hardening.sh.
    plan_step "cd ${SRC} && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -tags f4_embedded_qt_host -buildmode=pie -ldflags='-s -w -bindnow' -o dist/f4-linux-amd64/f4 ."

    plan_step "cp ${SRC}/dist/f4-linux-amd64/f4 ${OUT}/f4"
    # Ship the diagnostic wrapper next to the binary. CI cannot test a
    # real display; when a user's first graphical launch fails, this is
    # what turns "it didn't work" into a log that says why.
    plan_step "cp ${REPO_ROOT}/contrib/f4-qt/f4-diag.sh ${OUT}/f4-diag"
    plan_step "chmod +x ${OUT}/f4-diag"
    # Profile H, not S: goffi makes f4 dynamic on the C runtime by
    # construction (see the go build step). Contract is exactly
    # libc/libdl/libpthread, and through the hygiene wrapper for the
    # OB0060 build-path strings from prebuilt Go modules (colorer4go).
    plan_step "${REPO_ROOT}/tools/audit-with-hygiene-waivers.sh ${ONEBIN_BIN} --profile hybrid --glibc-max ${GLIBC_BASELINE} --allow libc.so.6 --allow libdl.so.2 --allow libpthread.so.0 --level 1 --strict ${OUT}/f4"

elif [ "${CONFIG}" = "windows" ]; then
    plan_step "cd ${SRC} && pwsh ci/build-portable-qt-windows.ps1"
    plan_step "cd ${SRC} && pwsh ci/audit-portable-qt-windows.ps1"
fi
