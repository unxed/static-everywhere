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
  --gallery public|off    resolve the ZoinGallery private submodule issue (§7.8)
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

if [ -z "${GALLERY}" ]; then
    echo "error: ZoinGallery is a private submodule (05-REFERENCE-f4-qt.md §7.8)." >&2
    echo "       You must resolve this by passing either:" >&2
    echo "         --gallery public  (if you have SSH access or it was made public)" >&2
    echo "         --gallery off     (to build with -DF4_NO_GALLERY=ON)" >&2
    exit 1
fi

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

# 2. Build setup
export F4_PORTABLE_STATIC=ON
if [ "${GALLERY}" = "off" ]; then
    export F4_NO_GALLERY=ON
fi

plan_step "mkdir -p ${OUT}"

# 3. Build, Audit, and Smoke Test
if [ "${CONFIG}" = "linux" ] && [ "${TOOLCHAIN}" = "host" ]; then
    plan_step "cd ${SRC} && ci/build-portable-qt-linux.sh"

    plan_step "cp ${SRC}/f4 ${OUT}/f4"
    plan_step "cp ${SRC}/embedded/f4-qt-host.gz ${OUT}/"

    plan_step "${ONEBIN_BIN} audit --profile static --level 1 --strict ${OUT}/f4"
    plan_step "${ONEBIN_BIN} audit --profile hybrid --glibc-max 2.27 --level 1 --strict ${SRC}/build-qt/f4-qt-host"

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
-c 'tools.cmake.cmaketoolchain:extra_variables={\"CMAKE_C_COMPILER_LAUNCHER\":\"ccache\",\"CMAKE_CXX_COMPILER_LAUNCHER\":\"ccache\",\"CMAKE_SIZEOF_VOID_P\":\"8\"}' \
-c 'tools.build:cflags=[\"-target\",\"x86_64-linux-gnu.${GLIBC_BASELINE}\"]' \
-c 'tools.build:cxxflags=[\"-target\",\"x86_64-linux-gnu.${GLIBC_BASELINE}\"]' \
-c 'libmount*:tools.build:cflags=[\"-DHAVE_CLOSE_RANGE=1\"]' \
-c 'tools.build:sharedlinkflags=[\"-target\",\"x86_64-linux-gnu.${GLIBC_BASELINE}\"]' \
-c 'tools.build:exelinkflags=[\"-target\",\"x86_64-linux-gnu.${GLIBC_BASELINE}\",\"-pie\"]' \
-c tools.system.package_manager:mode=check \
-vv \
--output-folder=qt/host/build-portable-linux"

    plan_step "cd ${SRC} && bash ci/build-qwindowkit.sh \"\$PWD/qt/host/build-portable-linux\" Release static"

    plan_step "cd ${SRC} && cmake -S qt/host -B qt/host/build-portable-linux -G Ninja \
-DCMAKE_TOOLCHAIN_FILE=\"\$PWD/qt/host/build-portable-linux/conan_toolchain.cmake\" \
-DCMAKE_BUILD_TYPE=Release \
-DCMAKE_PREFIX_PATH=\"\$PWD/build/qwindowkit-install\" \
-DQWindowKit_DIR=\"\$PWD/build/qwindowkit-install/lib/cmake/QWindowKit\" \
-DBUILD_TESTING=ON -DUSE_QWK=ON -DF4_PORTABLE_STATIC=ON"
    plan_step "cd ${SRC} && cmake --build qt/host/build-portable-linux --config Release --parallel \$(nproc)"
    plan_step "cd ${SRC} && ctest --test-dir qt/host/build-portable-linux -C Release --output-on-failure --timeout 300 -R '^(F4|QtShellController|WindowGeometryPersistence)'"

    plan_step "${ONEBIN_BIN} audit --profile hybrid --glibc-max ${GLIBC_BASELINE} --level 1 --strict ${SRC}/qt/host/build-portable-linux/bin/Release/f4-qt-host"

    plan_step "timeout --kill-after=30s 120s env QT_QPA_PLATFORM=offscreen QSG_RHI_BACKEND=software ${SRC}/qt/host/build-portable-linux/bin/Release/f4-qt-host --f4-ext-connect=127.0.0.1:1 --f4-ext-nonce=ci-smoke > ${OUT}/smoke.log 2>&1 || [ \$? -eq 2 ]"
    plan_step "! grep -q 'QQmlApplicationEngine failed to load component' ${OUT}/smoke.log"
    plan_step "! grep -q 'Could not find the Qt platform plugin' ${OUT}/smoke.log"

    plan_step "cd ${SRC} && python ci/package-embedded-qt-host.py qt/host/build-portable-linux/bin/Release/f4-qt-host"
    plan_step "cd ${SRC} && go test -tags f4_embedded_qt_host -run 'TestMaterializeEmbeddedQtHost|TestGeneratedEmbeddedQtHostPayload' ."
    plan_step "mkdir -p ${SRC}/dist/f4-linux-amd64"
    plan_step "cd ${SRC} && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -tags f4_embedded_qt_host -ldflags='-s -w' -o dist/f4-linux-amd64/f4 ."

    plan_step "cp ${SRC}/dist/f4-linux-amd64/f4 ${OUT}/f4"
    plan_step "${ONEBIN_BIN} audit --profile static --level 1 --strict ${OUT}/f4"

elif [ "${CONFIG}" = "windows" ]; then
    plan_step "cd ${SRC} && pwsh ci/build-portable-qt-windows.ps1"
    plan_step "cd ${SRC} && pwsh ci/audit-portable-qt-windows.ps1"
fi
