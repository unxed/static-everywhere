#!/usr/bin/env bash
# Build GNOME Terminal with its GTK stack linked from a static dependency
# prefix. Display servers, fonts, schemas and session services remain runtime
# inputs; the toolkit and its code dependencies do not.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
TOOLCHAIN="${REPO_ROOT}/onebin/toolchain"

SRC=./gnome-terminal-src
DEPS_PREFIX=./out/gnome-terminal/static-prefix
OUT=./out/gnome-terminal
BASELINE=2.28
JOBS=${GNOME_TERMINAL_JOBS:-$(nproc 2>/dev/null || echo 4)}
PRINT_PLAN=0

usage() {
    sed -n '2,9p' "$0"
    cat <<'EOF'

Options:
  --src DIR          GNOME Terminal source checkout
  --deps-prefix DIR  prefix containing static archives and pkg-config files
  --out DIR          output directory (default: ./out/gnome-terminal)
  --baseline VER     glibc baseline passed to zig (default: 2.28)
  --jobs N           parallel build jobs
  --print-plan       print commands without executing them
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --src)          SRC=${2:?--src needs a directory}; shift 2 ;;
        --deps-prefix)  DEPS_PREFIX=${2:?--deps-prefix needs a directory}; shift 2 ;;
        --out)          OUT=${2:?--out needs a directory}; shift 2 ;;
        --baseline)     BASELINE=${2:?--baseline needs a version}; shift 2 ;;
        --jobs)         JOBS=${2:?--jobs needs a number}; shift 2 ;;
        --print-plan)   PRINT_PLAN=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              printf 'build-gnome-terminal.sh: unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

if [[ "$OUT" = /* ]]; then
    OUT_ABS=$OUT
else
    OUT_ABS=$(pwd)/${OUT#./}
fi
if [[ "$SRC" = /* ]]; then
    SRC_ABS=$SRC
else
    SRC_ABS=$(pwd)/${SRC#./}
fi
if [[ "$DEPS_PREFIX" = /* ]]; then
    DEPS_ABS=$DEPS_PREFIX
else
    DEPS_ABS=$(pwd)/${DEPS_PREFIX#./}
fi

BUILD_DIR="${OUT_ABS}/build"
INSTALL_PREFIX="${OUT_ABS}/install"
NATIVE_FILE="${OUT_ABS}/meson-static.ini"
ARTIFACT="${OUT_ABS}/gnome-terminal-server"
TARGET="x86_64-linux-gnu.${BASELINE}"
PKG_CONFIG_PATH_VALUE="${DEPS_ABS}/lib/pkgconfig:${DEPS_ABS}/lib/x86_64-linux-gnu/pkgconfig:${DEPS_ABS}/share/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/share/pkgconfig"

quote_cmd() {
    printf '+ '
    printf '%q ' "$@"
    printf '\n'
}

run() {
    if [ "$PRINT_PLAN" -eq 1 ]; then
        quote_cmd "$@"
    else
        quote_cmd "$@" >&2
        "$@"
    fi
}

run_env() {
    if [ "$PRINT_PLAN" -eq 1 ]; then
        quote_cmd env "$@"
    else
        quote_cmd env "$@" >&2
        env "$@"
    fi
}

render_native_file() {
    cat >"$NATIVE_FILE" <<EOF
[binaries]
c = '${TOOLCHAIN}/zig-cc'
cpp = '${TOOLCHAIN}/zig-c++'
ar = '${TOOLCHAIN}/zig-ar'
ranlib = '${TOOLCHAIN}/zig-ranlib'
strip = 'strip'

[built-in options]
c_args = ['-target', '${TARGET}', '-fPIE', '-ffunction-sections', '-fdata-sections', '-fstack-protector-strong', '-ffile-prefix-map=${SRC_ABS}=.']
cpp_args = ['-target', '${TARGET}', '-fPIE', '-ffunction-sections', '-fdata-sections', '-fstack-protector-strong', '-ffile-prefix-map=${SRC_ABS}=.']
c_link_args = ['-target', '${TARGET}', '-static-libgcc', '-Wl,--gc-sections', '-Wl,-z,relro', '-Wl,-z,now', '-Wl,-z,noexecstack', '-pie', '-s', '-L${DEPS_ABS}/lib', '-L${DEPS_ABS}/lib/x86_64-linux-gnu', '-L/usr/lib/x86_64-linux-gnu', '-L/usr/lib']
cpp_link_args = ['-target', '${TARGET}', '-static-libgcc', '-static-libstdc++', '-Wl,--gc-sections', '-Wl,-z,relro', '-Wl,-z,now', '-Wl,-z,noexecstack', '-pie', '-s', '-L${DEPS_ABS}/lib', '-L${DEPS_ABS}/lib/x86_64-linux-gnu', '-L/usr/lib/x86_64-linux-gnu', '-L/usr/lib']
default_library = 'static'
b_pie = true
EOF
}

cat <<PLAN
# GNOME Terminal static GTK build
source: ${SRC}
static dependency prefix: ${DEPS_PREFIX}
target: ${TARGET}
jobs: ${JOBS}

# The prefix must contain static GTK3, GLib, Pango, Cairo, GdkPixbuf,
# FreeType, HarfBuzz, Fontconfig, VTE and libhandy archives plus their .pc files.
# The dependency lock is contrib/gnome-terminal/deps.lock.
PLAN

if [ "$PRINT_PLAN" -eq 1 ]; then
    echo "# Meson native file: ${NATIVE_FILE}"
    echo "# default_library = static"
    echo "# c/c++ target = ${TARGET}"
    quote_cmd env "PKG_CONFIG_PATH=${PKG_CONFIG_PATH_VALUE}" \
        meson setup --wipe "$BUILD_DIR" "$SRC_ABS" \
        --native-file "$NATIVE_FILE" \
        --prefix "$INSTALL_PREFIX" --libdir lib --libexecdir libexec --buildtype release \
        --prefer-static --wrap-mode nodownload -Ddefault_library=static \
        -Ddocs=false -Dnautilus_extension=false -Dsearch_provider=false
    quote_cmd env "PKG_CONFIG_PATH=${PKG_CONFIG_PATH_VALUE}" \
        meson compile -C "$BUILD_DIR" -j "$JOBS"
    quote_cmd env "PKG_CONFIG_PATH=${PKG_CONFIG_PATH_VALUE}" \
        meson install -C "$BUILD_DIR"
    quote_cmd install -D "$INSTALL_PREFIX/libexec/gnome-terminal-server" "$ARTIFACT"
    quote_cmd "$REPO_ROOT/tools/verify-gnome-terminal-static.sh" "$ARTIFACT"
    exit 0
fi

for tool in meson pkg-config readelf; do
    command -v "$tool" >/dev/null 2>&1 || {
        printf 'build-gnome-terminal.sh: required tool not found: %s\n' "$tool" >&2
        exit 1
    }
done
for tool in zig-cc zig-c++ zig-ar zig-ranlib; do
    [ -x "${TOOLCHAIN}/${tool}" ] || {
        printf 'build-gnome-terminal.sh: missing toolchain wrapper: %s\n' "${TOOLCHAIN}/${tool}" >&2
        exit 1
    }
done
[ -d "$SRC_ABS" ] || { printf 'build-gnome-terminal.sh: source directory not found: %s\n' "$SRC_ABS" >&2; exit 1; }
[ -d "$DEPS_ABS" ] || { printf 'build-gnome-terminal.sh: dependency prefix not found: %s\n' "$DEPS_ABS" >&2; exit 1; }
if ! find "$DEPS_ABS" -type f -path '*/pkgconfig/gtk+-3.0.pc' -print -quit | grep -q .; then
    printf 'build-gnome-terminal.sh: static GTK3 pkg-config file not found under %s\n' "$DEPS_ABS" >&2
    exit 1
fi

mkdir -p "$OUT_ABS"
render_native_file
export PKG_CONFIG_PATH="$PKG_CONFIG_PATH_VALUE"
export PKG_CONFIG_ALLOW_SYSTEM_LIBS=1
export PKG_CONFIG_ALLOW_SYSTEM_CFLAGS=1

pkg-config --exists gtk+-3.0 vte-2.91 libhandy-1 || {
    printf 'build-gnome-terminal.sh: static dependency prefix is incomplete (GTK3, VTE or libhandy missing)\n' >&2
    exit 1
}

run meson setup --wipe "$BUILD_DIR" "$SRC_ABS" \
    --native-file "$NATIVE_FILE" \
    --prefix "$INSTALL_PREFIX" --libdir lib --libexecdir libexec --buildtype release \
    --prefer-static --wrap-mode nodownload -Ddefault_library=static \
    -Ddocs=false -Dnautilus_extension=false -Dsearch_provider=false
run meson compile -C "$BUILD_DIR" -j "$JOBS"
run meson install -C "$BUILD_DIR"
run install -D "$INSTALL_PREFIX/libexec/gnome-terminal-server" "$ARTIFACT"
run "$REPO_ROOT/tools/verify-gnome-terminal-static.sh" "$ARTIFACT"
printf 'GNOME Terminal static GTK build: %s\n' "$ARTIFACT"
