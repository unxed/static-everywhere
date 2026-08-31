#!/bin/sh
# tools/build-far2l.sh — build and audit far2l as a Static Everywhere
# reference application. Interface: 04-REFERENCE-far2l.md §10. Target
# configurations and their exact cmake arguments: §6 (copied, not
# improvised). Third-party versions/hashes: contrib/far2l/deps.lock, never
# hardcoded here. Tag pin: 04-REFERENCE-far2l.md §2.
#
# POSIX sh, not bash (04-REFERENCE-far2l.md §10's own requirement).
set -eu

FAR2L_TAG_DEFAULT="v_2.8.0"
FAR2L_REPO="https://github.com/elfmz/far2l"

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
ONEBIN_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

usage() {
    cat <<'EOF'
Usage: tools/build-far2l.sh --config tiny|tty|sdl|wx [OPTIONS]

  --config tiny|tty|sdl|wx  required: which of 04-REFERENCE-far2l.md §6's
                            four target configurations to build
  --src DIR                 far2l source tree (default: ./far2l-src)
  --tag TAG                 git tag to check out if --src is absent
                            (default: v_2.8.0)
  --out DIR                 build/install output directory
                            (default: ./out/far2l-<config>)
  --jobs N                  parallel build jobs (default: 4)
  --profile hybrid|universal build profile (default: hybrid); universal is
                            currently supported for the SDL configuration
  --deps-prefix DIR         where already-built static third-party libs
                            live, per contrib/far2l/deps.lock
  --solo-root DIR           SoLo handoff root containing materialized
                            libdlfcn.a and lib/dlfcn.h (required for
                            --profile universal)
  --fetch                   allowed to clone far2l over the network
  --no-fetch                refuse to touch the network (default)
  --print-plan              print every command this invocation would run,
                            one per line, and exit 0 without doing any of
                            them — works with no network, no far2l
                            checkout, and no compiler
  --audit-only              skip straight to auditing an already-built
                            --out directory
  -h, --help                this message
EOF
}

CONFIG=""
SRC="./far2l-src"
TAG="${FAR2L_TAG_DEFAULT}"
OUT=""
JOBS=4
PROFILE=hybrid
DEPS_PREFIX=""
SOLO_ROOT=""
FETCH=0
PRINT_PLAN=0
AUDIT_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --config)      CONFIG=${2:-}; shift 2 ;;
        --src)         SRC=${2:-}; shift 2 ;;
        --tag)         TAG=${2:-}; shift 2 ;;
        --out)         OUT=${2:-}; shift 2 ;;
        --jobs)        JOBS=${2:-}; shift 2 ;;
        --profile)     PROFILE=${2:-}; shift 2 ;;
        --deps-prefix) DEPS_PREFIX=${2:-}; shift 2 ;;
        --solo-root)   SOLO_ROOT=${2:-}; shift 2 ;;
        --fetch)       FETCH=1; shift ;;
        --no-fetch)    FETCH=0; shift ;;
        --print-plan)  PRINT_PLAN=1; shift ;;
        --audit-only)  AUDIT_ONLY=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)
            echo "error: unknown option '$1'" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "${PROFILE}" in
    hybrid|universal) ;;
    *)
        echo "error: --profile must be hybrid or universal (got '${PROFILE}')" >&2
        exit 2
        ;;
esac

case "${CONFIG}" in
    tiny|tty|sdl|wx) ;;
    "")
        echo "error: --config is required (tiny, tty, sdl, or wx)" >&2
        exit 2
        ;;
    *)
        echo "error: --config must be tiny, tty, sdl, or wx (got '${CONFIG}')" >&2
        exit 2
        ;;
esac

if [ "${PROFILE}" = universal ]; then
    if [ "${CONFIG}" != sdl ]; then
        echo "error: --profile universal currently supports only --config sdl" >&2
        exit 2
    fi
    if [ -z "${SOLO_ROOT}" ]; then
        echo "error: --solo-root is required for --profile universal" >&2
        exit 2
    fi
    if [ "${PRINT_PLAN}" -eq 0 ]; then
        [ -f "${SOLO_ROOT}/libdlfcn.a" ] || {
            echo "error: SoLo materialized dlfcn archive not found: ${SOLO_ROOT}/libdlfcn.a" >&2
            exit 1
        }
        [ -f "${SOLO_ROOT}/lib/dlfcn.h" ] || {
            echo "error: SoLo header not found: ${SOLO_ROOT}/lib/dlfcn.h" >&2
            exit 1
        }
    fi
fi

[ -n "${OUT}" ] || OUT="./out/far2l-${CONFIG}"

# Every path derived from where this script happens to live (ONEBIN_ROOT)
# is real and absolute for actual execution, but must never leak into
# --print-plan's output as-is — 00-AGENT-TASK.md Task 15 requires the plan
# to contain nothing but what was given on the command line. plan_step()
# rewrites ONEBIN_ROOT to the same "<repo>/onebin/..." placeholder
# 04-REFERENCE-far2l.md §6 itself uses, so the plan is identical no matter
# where the repository is checked out.
TOOLCHAIN_DIR="${ONEBIN_ROOT}/toolchain"
ONEBIN_BIN="${ONEBIN_ROOT}/build/onebin"

# Third-party dependencies each configuration actually needs, per
# contrib/far2l/deps.lock's own header comment (which explains the "why"
# for each row below in full).
#
# `libssh`/`libnfs`/`mbedtls`/`zlib`/`openssl`/`neon` are all pinned and
# proven against real NetRocks brokers (04-REFERENCE-far2l.md §6.2.1-
# 6.2.3): NetRocks-SFTP/SCP (libssh+mbedtls), NetRocks-NFS (libnfs), and
# NetRocks-FTP/WebDAV (openssl+neon, once far2l's own LICENSE.txt was
# confirmed to carry the OpenSSL Linking Exception -- see STATUS.md
# "NetRocks OpenSSL & WebDAV: RESOLVED"). `libxml2` still isn't pinned,
# so COLORER stays off below.
deps_for_config() {
    case "$1" in
        tiny) ;; # none: every optional subsystem that would need one is off
        tty|wx) printf '%s\n' libssh libnfs mbedtls zlib openssl neon ;;
        sdl) printf '%s\n' libssh libnfs mbedtls zlib openssl neon sdl2 freetype harfbuzz fontconfig expat ;;
    esac
}

# far2l's own cmake/modules/FindLibSSH.cmake and FindLibNfs.cmake are
# hand-written find_library/find_path modules with no transitive-
# dependency info of their own, and (confirmed by reading both, not
# assumed) they don't even share a cache-variable naming convention:
# FindLibSSH.cmake exits early if the PLURAL LIBSSH_LIBRARIES/
# LIBSSH_INCLUDE_DIRS are already set, letting one variable carry
# libssh's whole static link chain (libssh.a + its own mbedTLS/zlib
# static deps); FindLibNfs.cmake instead searches on the SINGULAR
# LIBNFS_LIBRARY/LIBNFS_INCLUDE_DIR. Pre-seeding the wrong pair for
# either module leaves it silently NOTFOUND. 04-REFERENCE-far2l.md
# SS6.2.2/SS6.2.3.
netrocks_crypto_args() {
    printf '%s\n' \
        "-DLIBSSH_LIBRARIES='${DEPS_PREFIX}/libssh/lib/libssh.a;${DEPS_PREFIX}/mbedtls/lib/libmbedtls.a;${DEPS_PREFIX}/mbedtls/lib/libmbedx509.a;${DEPS_PREFIX}/mbedtls/lib/libmbedcrypto.a;${DEPS_PREFIX}/zlib/lib/libz.a'" \
        "-DLIBSSH_INCLUDE_DIRS=${DEPS_PREFIX}/libssh/include" \
        "-DLIBNFS_LIBRARY=${DEPS_PREFIX}/libnfs/lib/libnfs.a" \
        "-DLIBNFS_INCLUDE_DIR=${DEPS_PREFIX}/libnfs/include" \
        "-DOPENSSL_ROOT_DIR=${DEPS_PREFIX}/openssl" \
        "-DOPENSSL_USE_STATIC_LIBS=TRUE" \
        "-DNEON_LIBRARY=${DEPS_PREFIX}/neon/lib/libneon.a" \
        "-DNEON_INCLUDE_DIR=${DEPS_PREFIX}/neon/include/neon"
}

# cmake -D... arguments for this configuration, copied verbatim from
# 04-REFERENCE-far2l.md §6 (do not improvise them).
cmake_config_args() {
    case "$1" in
        tiny)
            printf '%s\n' \
                "-DCMAKE_TOOLCHAIN_FILE=${TOOLCHAIN_DIR}/onebin-linux-static.cmake" \
                "-DCMAKE_BUILD_TYPE=Release" \
                "-DMUSL=1" "-DUSEWX=no" "-DUSESDL=no" "-DTTYX=no" "-DTTYXI=no" \
                "-DUSEUCD=no" "-DCOLORER=no" "-DNETROCKS=no" "-DMULTIARC=no" "-DARCLITE=no" \
                "-DPYTHON=no" "-DUNRAR=no" "-DICU_MODE=prebuilt" \
                "-DADB=no" "-DALIGN=no" "-DAUTOWRAP=no" "-DCALC=no" "-DCOMPARE=no" "-DDRAWLINE=no" \
                "-DEDITCASE=no" "-DEDITORCOMP=no" "-DEDSORT=no" "-DFILECASE=no" "-DHEXITOR=no" \
                "-DIMAGEVIEWER=no" "-DINCSRCH=no" "-DINSIDE=no" "-DMEMO=no" "-DOPENWITH=no" \
                "-DSIMPLEINDENT=no" "-DTMPPANEL=no" "-DTRUNCATE=no"
            ;;
        tty)
            printf '%s\n' \
                "-DCMAKE_TOOLCHAIN_FILE=${TOOLCHAIN_DIR}/onebin-linux-hybrid.cmake" \
                "-DCMAKE_BUILD_TYPE=Release" \
                "-DUSEWX=no" "-DUSESDL=no" "-DPYTHON=no" "-DUNRAR=no" "-DICU_MODE=prebuilt" \
                "-DNR_AWS=no" \
                "-DCOLORER=no" "-DMULTIARC=no" "-DUSEUCD=no"
            netrocks_crypto_args
            # COLORER/MULTIARC/USEUCD=no: libxml2/libarchive
            # aren't wired into this script's deps yet (libarchive IS
            # pinned in deps.lock but hasn't been proven through a real
            # far2l MULTIARC build; libxml2 for Colorer isn't pinned at
            # all). NETROCKS stays at its far2l
            # default (yes): libssh+libnfs above give it real SFTP/SCP/
            # NFS support, and NetRocks-SHELL/FISHPLUS need nothing at
            # all (04-REFERENCE-far2l.md SS6.2.1) so the plugin already
            # has working network transfer regardless.
            ;;
        sdl)
            sdl_toolchain="${TOOLCHAIN_DIR}/onebin-linux-hybrid.cmake"
            if [ "${PROFILE}" = universal ]; then
                sdl_toolchain="${TOOLCHAIN_DIR}/onebin-linux-universal.cmake"
            fi
            printf '%s\n' \
                "-DCMAKE_TOOLCHAIN_FILE=${sdl_toolchain}" \
                "-DCMAKE_BUILD_TYPE=Release" \
                "-DUSEWX=no" "-DUSESDL=YES" "-DPYTHON=no" "-DUNRAR=no" "-DICU_MODE=prebuilt" \
                "-DNR_AWS=no" \
                "-DCOLORER=no" "-DMULTIARC=no" "-DUSEUCD=no"
            if [ "${PROFILE}" = universal ]; then
                printf '%s\n' "-DONEBIN_SOLO_ROOT=${SOLO_ROOT}" \
                    "-DTTYX=no" "-DTTYXI=no"
            fi
            netrocks_crypto_args
            # Same reasoning as tty above, plus: USESDL=YES only exists on
            # far2l's unstable master (04-REFERENCE-far2l.md SS6.3) -- pass
            # --tag <the pinned preview commit> explicitly when building
            # this config against --src, this script does not default it.
            ;;
        wx)
            printf '%s\n' \
                "-DCMAKE_TOOLCHAIN_FILE=${TOOLCHAIN_DIR}/onebin-linux-hybrid.cmake" \
                "-DCMAKE_BUILD_TYPE=Release" \
                "-DUSEWX=yes" "-DUSESDL=no" \
                "-DNR_AWS=no" \
                "-DCOLORER=no" "-DMULTIARC=no" "-DUSEUCD=no"
            netrocks_crypto_args
            ;;
    esac
}

# Artifacts to audit and how, per 04-REFERENCE-far2l.md §9's table:
# "profile:level:strict:extra_allow:relpath", one per line. extra_allow is
# comma-separated sonames, or empty. strict is the literal word "strict"
# or empty.
#
# The install layout depends on the far2l tree: older/custom-prefix builds
# can be flat, while the pinned SDL preview uses the standard
# "<prefix>/bin" plus "<prefix>/lib/far2l" layout. Keep the historical
# flat paths in the offline plan, but detect the split layout after a real
# install so --audit-only and the build path both follow the artifacts that
# exist.
# far2l_sdl.so is audited as --profile module, not hybrid: it is a
# dlopen'd shared object, never has PT_INTERP by design, and --profile
# hybrid's OB0036 ("no PT_INTERP") is the wrong check for it — confirmed
# by building this exact artifact and re-auditing both ways.
audit_plan_for_config() {
    if [ "${PROFILE}" = universal ]; then
        printf '%s\n' \
            "universal:1:strict::far2l" \
            "universal:1:strict::far2l_sdl.so"
        return 0
    fi
    case "$1" in
        tiny)
            printf '%s\n' \
                "static:1:strict::far2l"
            ;;
        tty)
            printf '%s\n' \
                "hybrid:1:strict::far2l" \
                "hybrid:1:strict:libX11.so.6,libXi.so.6,libICE.so.6,libSM.so.6,libXext.so.6:far2l_ttyx.broker"
            ;;
        sdl)
            printf '%s\n' \
                "hybrid:1:strict::far2l" \
                "module:1:strict::far2l_sdl.so" \
                "hybrid:1:strict:libX11.so.6,libXi.so.6,libICE.so.6,libSM.so.6,libXext.so.6:far2l_ttyx.broker"
            ;;
        wx)
            printf '%s\n' \
                "hybrid:0:::far2l" \
                "module:0:::far2l_gui.so"
            ;;
    esac
}

plan_step() {
    if [ "${PRINT_PLAN}" -eq 1 ]; then
        printf '%s\n' "$1" | sed "s#${ONEBIN_ROOT}#<repo>/onebin#g"
        return 0
    fi
    printf '+ %s\n' "$1" >&2
    eval "$1"
}

# ---------------------------------------------------------------- source

resolve_source() {
    if [ "${FETCH}" -eq 1 ]; then
        plan_step "git clone --depth 1 --branch ${TAG} ${FAR2L_REPO} ${SRC}"
    elif [ "${PRINT_PLAN}" -eq 0 ] && [ ! -d "${SRC}" ]; then
        echo "error: source tree '${SRC}' not found and --no-fetch is set." >&2
        echo "       run again with --fetch to clone ${FAR2L_REPO} (tag ${TAG})," >&2
        echo "       or point --src at an existing checkout." >&2
        exit 1
    fi
    if [ "${PRINT_PLAN}" -eq 1 ]; then
        # Keep the stable-tag plan byte-for-byte compatible with the golden
        # fixtures. Preview pins are verified by the execution path below.
        plan_step "git -C ${SRC} describe --tags --exact-match"
        return 0
    fi

    if git -C "${SRC}" describe --tags --exact-match >/dev/null 2>&1; then
        test "$(git -C "${SRC}" describe --tags --exact-match)" = "${TAG}"
    else
        # far2l-sdl is not tagged yet. Its source is pinned to a commit in
        # contrib/far2l/deps.lock, so accepting only the requested object is
        # just as strict as the tag check and makes the preview reproducible.
        expected=$(git -C "${SRC}" rev-parse "${TAG}^{commit}")
        actual=$(git -C "${SRC}" rev-parse HEAD)
        test "${actual}" = "${expected}"
    fi
}

verify_deps() {
    deps_for_config "${CONFIG}" > /tmp/onebin-far2l-deps.$$ 2>/dev/null || true
    if [ ! -s /tmp/onebin-far2l-deps.$$ ]; then
        rm -f /tmp/onebin-far2l-deps.$$
        return 0
    fi
    if [ -z "${DEPS_PREFIX}" ]; then
        plan_step "test -n \"\${DEPS_PREFIX:?--deps-prefix is required for --config ${CONFIG}}\""
        rm -f /tmp/onebin-far2l-deps.$$
        return 0
    fi
    while IFS= read -r dep; do
        [ -n "${dep}" ] || continue
        plan_step "test -d ${DEPS_PREFIX}/${dep}"
    done < /tmp/onebin-far2l-deps.$$
    rm -f /tmp/onebin-far2l-deps.$$
}

configure_deps_env() {
    [ -n "${DEPS_PREFIX}" ] || return 0

    # far2l's SDL CMake files discover SDL2, FreeType, HarfBuzz and
    # Fontconfig through pkg-config/find_package rather than through the
    # explicit NetRocks cache variables above. Put the pinned prefix first
    # for both mechanisms so a host development package can never silently
    # replace one of the showcase's source-built libraries.
    PKG_CONFIG_PATH="${DEPS_PREFIX}/sdl2/lib/pkgconfig:${DEPS_PREFIX}/freetype/lib/pkgconfig:${DEPS_PREFIX}/harfbuzz/lib/pkgconfig:${DEPS_PREFIX}/fontconfig/lib/pkgconfig:${DEPS_PREFIX}/expat/lib/pkgconfig:${DEPS_PREFIX}/zlib/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
    export PKG_CONFIG_PATH
    CMAKE_PREFIX_PATH="${DEPS_PREFIX}/sdl2:${DEPS_PREFIX}/freetype:${DEPS_PREFIX}/harfbuzz:${DEPS_PREFIX}/fontconfig:${DEPS_PREFIX}/expat:${DEPS_PREFIX}/zlib${CMAKE_PREFIX_PATH:+:${CMAKE_PREFIX_PATH}}"
    export CMAKE_PREFIX_PATH
}

# ------------------------------------------------------------ build steps

configure_build_install() {
    args=$(cmake_config_args "${CONFIG}" | tr '\n' ' ')
    plan_step "mkdir -p ${OUT}"
    # shellcheck disable=SC2086
    # Keep this explicit in the configure command as well as in the
    # toolchain: far2l's CMake adds target_link_directories() for the SDL
    # module, and the hosted build proved that the toolchain-only setting can
    # still leave an absolute dependency RUNPATH in that MODULE artifact.
    plan_step "cmake -S ${SRC} -B ${OUT}/_build ${args} -DCMAKE_INSTALL_PREFIX=${OUT}/install -DCMAKE_SKIP_RPATH=ON"
    if [ "${ONEBIN_VERBOSE_BUILD:-0}" = 1 ]; then
        # U links are intentionally observable: if a shared/module target
        # regresses, the hosted diagnostic contains the exact compiler argv
        # after the zig wrapper's policy normalization.
        plan_step "cmake --build ${OUT}/_build --parallel ${JOBS} --verbose"
    else
        plan_step "cmake --build ${OUT}/_build --parallel ${JOBS}"
    fi
    plan_step "cmake --install ${OUT}/_build"
}

# ------------------------------------------------------------------ audit

run_audits() {
    status=0
    plan=$(audit_plan_for_config "${CONFIG}")
    split_install=0
    if [ "${PRINT_PLAN}" -eq 0 ] && {
        [ -f "${OUT}/install/bin/far2l" ] ||
        [ -f "${OUT}/install/lib/far2l/far2l_sdl.so" ] ||
        [ -f "${OUT}/install/lib/far2l/far2l_gui.so" ];
    }; then
        split_install=1
    fi
    save_ifs=${IFS}
    IFS='
'
    for line in ${plan}; do
        IFS=:
        # shellcheck disable=SC2086  # word-splitting on IFS=: is the point
        set -- ${line}
        IFS=${save_ifs}
        profile=${1:-}; level=${2:-}; strict=${3:-}; allow=${4:-}; relpath=${5:-}

        cmd="${ONEBIN_BIN} audit --profile ${profile} --level ${level}"
        [ "${strict}" = "strict" ] && cmd="${cmd} --strict"
        if [ -n "${allow}" ]; then
            save_ifs2=${IFS}
            IFS=,
            for a in ${allow}; do
                cmd="${cmd} --allow ${a}"
            done
            IFS=${save_ifs2}
        fi
        artifact="${OUT}/install/${relpath}"
        if [ "${split_install}" -eq 1 ]; then
            if [ "${relpath}" = "far2l" ]; then
                artifact="${OUT}/install/bin/far2l"
            else
                artifact="${OUT}/install/lib/far2l/${relpath}"
            fi
        fi
        cmd="${cmd} ${artifact}"

        if ! plan_step "${cmd}"; then
            status=1
        fi
    done
    return "${status}"
}

# ------------------------------------------------------------------- main

if [ "${AUDIT_ONLY}" -eq 1 ]; then
    run_audits
    exit $?
fi

resolve_source
verify_deps
configure_deps_env
configure_build_install
run_audits
