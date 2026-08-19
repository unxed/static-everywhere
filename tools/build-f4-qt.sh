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

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
ONEBIN_BIN="${REPO_ROOT}/onebin/build/onebin"
DEPS_LOCK="${REPO_ROOT}/contrib/f4-qt/deps.lock"

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
if [ "${CONFIG}" = "linux" ]; then
    plan_step "cd ${SRC} && ci/build-portable-qt-linux.sh"

    plan_step "cp ${SRC}/f4 ${OUT}/f4"
    plan_step "cp ${SRC}/embedded/f4-qt-host.gz ${OUT}/"

    plan_step "${ONEBIN_BIN} audit --profile static --level 1 --strict ${OUT}/f4"
    plan_step "${ONEBIN_BIN} audit --profile hybrid --glibc-max 2.27 --level 1 --strict ${SRC}/build-qt/f4-qt-host"

    plan_step "env QT_QPA_PLATFORM=offscreen QSG_RHI_BACKEND=software ${SRC}/build-qt/f4-qt-host --f4-ext-connect=127.0.0.1:1 > ${OUT}/smoke.log 2>&1 || [ \$? -eq 2 ]"
    plan_step "! grep -q 'QQmlApplicationEngine failed to load component' ${OUT}/smoke.log"
    plan_step "! grep -q 'Could not find the Qt platform plugin' ${OUT}/smoke.log"

elif [ "${CONFIG}" = "windows" ]; then
    plan_step "cd ${SRC} && pwsh ci/build-portable-qt-windows.ps1"
    plan_step "cd ${SRC} && pwsh ci/audit-portable-qt-windows.ps1"
fi
