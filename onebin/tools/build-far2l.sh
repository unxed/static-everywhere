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
  --deps-prefix DIR         where already-built static third-party libs
                            live, per contrib/far2l/deps.lock
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
DEPS_PREFIX=""
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
        --deps-prefix) DEPS_PREFIX=${2:-}; shift 2 ;;
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
deps_for_config() {
    case "$1" in
        tiny) ;; # none: every optional subsystem that would need one is off
        tty|wx) printf '%s\n' libssh openssl libnfs neon libarchive libxml2 libuchardet ;;
        sdl) printf '%s\n' libssh openssl libnfs neon libarchive libxml2 libuchardet sdl2 freetype harfbuzz fontconfig ;;
    esac
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
                "-DUSEWX=no" "-DUSESDL=no" "-DPYTHON=no" "-DUNRAR=no" "-DICU_MODE=prebuilt"
            ;;
        sdl)
            printf '%s\n' \
                "-DCMAKE_TOOLCHAIN_FILE=${TOOLCHAIN_DIR}/onebin-linux-hybrid.cmake" \
                "-DCMAKE_BUILD_TYPE=Release" \
                "-DUSEWX=no" "-DUSESDL=YES" "-DPYTHON=no" "-DUNRAR=no" "-DICU_MODE=prebuilt"
            ;;
        wx)
            printf '%s\n' \
                "-DCMAKE_TOOLCHAIN_FILE=${TOOLCHAIN_DIR}/onebin-linux-hybrid.cmake" \
                "-DCMAKE_BUILD_TYPE=Release" \
                "-DUSEWX=yes" "-DUSESDL=no"
            ;;
    esac
}

# Artifacts to audit and how, per 04-REFERENCE-far2l.md §9's table:
# "profile:level:strict:extra_allow:relpath", one per line. extra_allow is
# comma-separated sonames, or empty. strict is the literal word "strict"
# or empty.
audit_plan_for_config() {
    case "$1" in
        tiny)
            printf '%s\n' \
                "static:1:strict::bin/far2l"
            ;;
        tty)
            printf '%s\n' \
                "hybrid:1:strict::bin/far2l" \
                "hybrid:1:strict:libX11.so.6,libXi.so.6,libICE.so.6,libSM.so.6,libXext.so.6:lib/far2l/far2l_ttyx.broker"
            ;;
        sdl)
            printf '%s\n' \
                "hybrid:1:strict::bin/far2l" \
                "hybrid:1:strict::lib/far2l/far2l_sdl.so" \
                "hybrid:1:strict:libX11.so.6,libXi.so.6,libICE.so.6,libSM.so.6,libXext.so.6:lib/far2l/far2l_ttyx.broker"
            ;;
        wx)
            printf '%s\n' \
                "hybrid:0:::bin/far2l" \
                "hybrid:0:::lib/far2l/far2l_gui.so"
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
    plan_step "git -C ${SRC} describe --tags --exact-match"
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

# ------------------------------------------------------------ build steps

configure_build_install() {
    args=$(cmake_config_args "${CONFIG}" | tr '\n' ' ')
    plan_step "mkdir -p ${OUT}"
    # shellcheck disable=SC2086
    plan_step "cmake -S ${SRC} -B ${OUT}/_build ${args} -DCMAKE_INSTALL_PREFIX=${OUT}/install"
    plan_step "cmake --build ${OUT}/_build --parallel ${JOBS}"
    plan_step "cmake --install ${OUT}/_build"
}

# ------------------------------------------------------------------ audit

run_audits() {
    status=0
    plan=$(audit_plan_for_config "${CONFIG}")
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
        cmd="${cmd} ${OUT}/install/${relpath}"

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
configure_build_install
run_audits
