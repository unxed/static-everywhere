#!/usr/bin/env bash
# Build GNOME Terminal with its GTK stack linked from a static dependency
# prefix. Display servers, fonts, schemas and session services remain runtime
# inputs; the toolkit and its code dependencies do not.
set -euo pipefail
set -o pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
TOOLCHAIN="${REPO_ROOT}/onebin/toolchain"
PKG_CONFIG_WRAPPER="${REPO_ROOT}/tools/pkg-config-hybrid-host.sh"
GNOME_STATIC_PATCH="${REPO_ROOT}/contrib/gnome-terminal/patches/gnome-terminal-static-gmodule-override.patch"
GNOME_PORTABLE_PATCH="${REPO_ROOT}/contrib/gnome-terminal/patches/gnome-terminal-portable-paths.patch"
PORTABLE_LAUNCHER="${REPO_ROOT}/contrib/gnome-terminal/gnome-terminal-portable.sh"
PORTABLE_APP_ID=org.gnome.Terminal.StaticEverywhere
GLIBC_SHIM_SOURCE="${REPO_ROOT}/contrib/f4-qt/compat/glibc-shims.c"
PKG_CONFIG_COMMAND=(bash "${PKG_CONFIG_WRAPPER}")
PKG_CONFIG_ENV="bash $(printf '%q' "${PKG_CONFIG_WRAPPER}")"

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
  --deps-prefix DIR  DESTDIR root containing the static /usr dependency tree
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
INSTALL_PREFIX=/usr
PACKAGE_ROOT="${OUT_ABS}/package"
NATIVE_FILE="${OUT_ABS}/meson-static.ini"
ARTIFACT="${OUT_ABS}/gnome-terminal-server"
CLIENT_ARTIFACT="${OUT_ABS}/gnome-terminal-client"
GLIBC_SHIM_OBJ="${OUT_ABS}/gnome-terminal-glibc-shims.o"
TARGET="x86_64-linux-gnu.${BASELINE}"
DEPS_RUNTIME_ROOT="${DEPS_ABS}${INSTALL_PREFIX}"
PKG_CONFIG_PATH_VALUE="${DEPS_RUNTIME_ROOT}/lib/pkgconfig:${DEPS_RUNTIME_ROOT}/lib/x86_64-linux-gnu/pkgconfig:${DEPS_RUNTIME_ROOT}/share/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/share/pkgconfig"
ONEBIN="${REPO_ROOT}/onebin/build/onebin"
GNOME_TERMINAL_GLIBC_RUNTIME_CONTRACT=(
    # Profile H keeps the glibc runtime dynamic.  Keep the complete set of
    # runtime SONAMEs explicit: glibc splits resolver and other components
    # into separate DT_NEEDED entries on some dependency graphs.
    --allow libc.so.6 --allow libm.so.6 --allow libdl.so.2
    --allow libpthread.so.0 --allow librt.so.1 --allow libresolv.so.2
)
GNOME_TERMINAL_GUI_HOST_CONTRACT=(
    # The only non-C-runtime GUI boundary is the explicitly permitted X11 and
    # OpenGL/EGL host ABI.  Toolkit/UI and desktop protocol implementations
    # remain in the static prefix.
    --allow libX11.so.6 --allow libX11-xcb.so.1 --allow libXext.so.6
    --allow libXi.so.6 --allow libXrandr.so.2 --allow libXrender.so.1
    --allow libXcursor.so.1 --allow libXdamage.so.1 --allow libXfixes.so.3
    --allow libXcomposite.so.1 --allow libXinerama.so.1
    --allow libXau.so.6 --allow libXdmcp.so.6 --allow libICE.so.6
    --allow libSM.so.6 --allow libxcb.so.1 --allow libxcb-render.so.0
    --allow libxcb-shm.so.0 --allow libxcb-xkb.so.1
    --allow libxcb-render-util.so.0 --allow libxcb-image.so.0
    --allow libxcb-keysyms.so.1 --allow libxcb-util.so.1
    --allow libxcb-xinerama.so.0 --allow libxcb-cursor.so.0
    --allow libXtst.so.6 --allow libGL.so.1 --allow libEGL.so.1
)
GNOME_TERMINAL_HOST_CONTRACT=(
    "${GNOME_TERMINAL_GLIBC_RUNTIME_CONTRACT[@]}"
    "${GNOME_TERMINAL_GUI_HOST_CONTRACT[@]}"
)

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

apply_source_patch() {
    local source=$1 patch=$2
    if ! git -C "${source}" apply --numstat "${patch}" >/dev/null 2>&1; then
        printf 'build-gnome-terminal.sh: malformed captured GNOME Terminal patch: %s\n' \
            "${patch}" >&2
        return 1
    fi
    if git -C "${source}" apply --reverse --check "${patch}" >/dev/null 2>&1; then
        return 0
    fi
    run git -C "${source}" apply --whitespace=nowarn "${patch}"
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
# Map every physical tree that can supply a source, generated source or
# installed header. The dependency pkg-config files intentionally point at
# DEPS_ABS for build-time consumption, so mapping SRC_ABS alone leaves the
# staging path visible through headers such as GLib's gobject cleanups.
c_args = ['-target', '${TARGET}', '-fPIE', '-ffunction-sections', '-fdata-sections', '-fstack-protector-strong', '-ffile-prefix-map=${SRC_ABS}=.', '-ffile-prefix-map=${DEPS_ABS}=.', '-ffile-prefix-map=${OUT_ABS}=.']
cpp_args = ['-target', '${TARGET}', '-fPIE', '-ffunction-sections', '-fdata-sections', '-fstack-protector-strong', '-ffile-prefix-map=${SRC_ABS}=.', '-ffile-prefix-map=${DEPS_ABS}=.', '-ffile-prefix-map=${OUT_ABS}=.']
c_link_args = ['${GLIBC_SHIM_OBJ}', '-target', '${TARGET}', '-static-libgcc', '-Wl,--gc-sections', '-Wl,-z,relro', '-Wl,-z,now', '-Wl,-z,noexecstack', '-pie', '-s', '-L${DEPS_RUNTIME_ROOT}/lib', '-L${DEPS_RUNTIME_ROOT}/lib/x86_64-linux-gnu', '-L/usr/lib/x86_64-linux-gnu', '-L/usr/lib']
cpp_link_args = ['${GLIBC_SHIM_OBJ}', '-target', '${TARGET}', '-static-libgcc', '-static-libstdc++', '-Wl,--gc-sections', '-Wl,-z,relro', '-Wl,-z,now', '-Wl,-z,noexecstack', '-pie', '-s', '-L${DEPS_RUNTIME_ROOT}/lib', '-L${DEPS_RUNTIME_ROOT}/lib/x86_64-linux-gnu', '-L/usr/lib/x86_64-linux-gnu', '-L/usr/lib']
default_library = 'static'
b_pie = true
EOF
}

cat <<PLAN
# GNOME Terminal static GTK build
source: ${SRC}
static dependency staging root: ${DEPS_PREFIX}
static dependency logical prefix: ${INSTALL_PREFIX}
package root (install with DESTDIR): ${PACKAGE_ROOT}
target: ${TARGET}
jobs: ${JOBS}

# The dependency staging root must contain a /usr tree with static GTK3, GLib, Pango, Cairo, GdkPixbuf,
# FreeType, HarfBuzz, Fontconfig, VTE, libhandy and libuuid archives plus their
# .pc files.
# The dependency lock is contrib/gnome-terminal/deps.lock.
# Profile H keeps the explicit glibc runtime ABI dynamic, including split
# resolver entries such as libresolv.so.2.  The only non-C-runtime GUI host
# boundary is X11/OpenGL/EGL; GTK, GLib, D-Bus and the rest of the UI stack
# stay in the prefix's private static dependency closure.
# The build uses logical /usr paths in a DESTDIR, then turns that tree into a
# relocatable bundle. The tracked launcher sets GNOME_TERMINAL_PORTABLE_ROOT,
# starts the server under ${PORTABLE_APP_ID} and resolves the
# source's own absolute install paths below the unpacked bundle.
# source hygiene: remap SRC_ABS, DEPS_ABS and OUT_ABS with -ffile-prefix-map;
# staged headers and generated sources must not leak their physical paths.
# linker hardening: -Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack
# captured GNOME source patch: ${GNOME_STATIC_PATCH}
# glibc baseline compatibility source: ${GLIBC_SHIM_SOURCE}
# glibc baseline compatibility object: ${GLIBC_SHIM_OBJ}
# portable launcher: ${PORTABLE_LAUNCHER}
# portable server application ID: ${PORTABLE_APP_ID}
PLAN

if [ "$PRINT_PLAN" -eq 1 ]; then
    echo "# Meson native file: ${NATIVE_FILE}"
    echo "# default_library = static"
    echo "# c/c++ target = ${TARGET}"
    quote_cmd git -C "$SRC_ABS" apply --whitespace=nowarn "$GNOME_STATIC_PATCH"
    quote_cmd git -C "$SRC_ABS" apply --whitespace=nowarn "$GNOME_PORTABLE_PATCH"
    quote_cmd "${TOOLCHAIN}/zig-cc" -target "$TARGET" -O2 -fPIC \
        -c "$GLIBC_SHIM_SOURCE" -o "$GLIBC_SHIM_OBJ"
    quote_cmd env "PKG_CONFIG_PATH=${PKG_CONFIG_PATH_VALUE}" \
        meson setup --wipe "$BUILD_DIR" "$SRC_ABS" \
        --native-file "$NATIVE_FILE" \
        --prefix "$INSTALL_PREFIX" --libdir lib --libexecdir libexec --buildtype release \
        --prefer-static --wrap-mode nodownload -Ddefault_library=static \
        -Ddocs=false -Dnautilus_extension=false -Dsearch_provider=false
    quote_cmd env "PKG_CONFIG_PATH=${PKG_CONFIG_PATH_VALUE}" \
        meson compile -C "$BUILD_DIR" -j "$JOBS"
    quote_cmd env "PKG_CONFIG_PATH=${PKG_CONFIG_PATH_VALUE}" \
        meson install -C "$BUILD_DIR" --destdir "$PACKAGE_ROOT"
    quote_cmd mv "$PACKAGE_ROOT/usr/bin/gnome-terminal" "$PACKAGE_ROOT/usr/bin/gnome-terminal.bin"
    quote_cmd install -D -m 755 "$PORTABLE_LAUNCHER" "$PACKAGE_ROOT/gnome-terminal"
    quote_cmd ln -s ../../gnome-terminal "$PACKAGE_ROOT/usr/bin/gnome-terminal"
    quote_cmd rm -f "$PACKAGE_ROOT/usr/share/dbus-1/services/org.gnome.Terminal.service" "$PACKAGE_ROOT/usr/lib/systemd/user/gnome-terminal-server.service"
    quote_cmd install -D "$PACKAGE_ROOT/usr/libexec/gnome-terminal-server" "$ARTIFACT"
    quote_cmd install -D "$PACKAGE_ROOT/usr/bin/gnome-terminal.bin" "$CLIENT_ARTIFACT"
    quote_cmd "$REPO_ROOT/tools/verify-gnome-terminal-static.sh" "$ARTIFACT"
    quote_cmd "$REPO_ROOT/tools/verify-gnome-terminal-static.sh" "$CLIENT_ARTIFACT"
    quote_cmd "$ONEBIN" audit --profile hybrid --glibc-max "$BASELINE" \
        --level 1 --strict "${GNOME_TERMINAL_HOST_CONTRACT[@]}" "$ARTIFACT"
    quote_cmd "$ONEBIN" audit --profile hybrid --glibc-max "$BASELINE" \
        --level 1 --strict "${GNOME_TERMINAL_HOST_CONTRACT[@]}" "$CLIENT_ARTIFACT"
    exit 0
fi

for tool in git meson pkg-config readelf; do
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
[ -x "$ONEBIN" ] || {
    printf 'build-gnome-terminal.sh: missing onebin audit tool: %s\n' "$ONEBIN" >&2
    exit 1
}
[ -f "$PKG_CONFIG_WRAPPER" ] || {
    printf 'build-gnome-terminal.sh: host pkg-config wrapper is missing: %s\n' "$PKG_CONFIG_WRAPPER" >&2
    exit 1
}
[ -f "$GNOME_STATIC_PATCH" ] || {
    printf 'build-gnome-terminal.sh: captured GNOME Terminal patch is missing: %s\n' \
        "$GNOME_STATIC_PATCH" >&2
    exit 1
}
[ -f "$GNOME_PORTABLE_PATCH" ] || {
    printf 'build-gnome-terminal.sh: captured GNOME Terminal portable-path patch is missing: %s\n' \
        "$GNOME_PORTABLE_PATCH" >&2
    exit 1
}
[ -x "$PORTABLE_LAUNCHER" ] || {
    printf 'build-gnome-terminal.sh: portable launcher is missing or not executable: %s\n' \
        "$PORTABLE_LAUNCHER" >&2
    exit 1
}
[ -f "$GLIBC_SHIM_SOURCE" ] || {
    printf 'build-gnome-terminal.sh: glibc baseline shim source is missing: %s\n' \
        "$GLIBC_SHIM_SOURCE" >&2
    exit 1
}
[ -d "$SRC_ABS" ] || { printf 'build-gnome-terminal.sh: source directory not found: %s\n' "$SRC_ABS" >&2; exit 1; }
[ -d "$DEPS_ABS" ] || { printf 'build-gnome-terminal.sh: dependency prefix not found: %s\n' "$DEPS_ABS" >&2; exit 1; }
if ! find "$DEPS_RUNTIME_ROOT" -type f -path '*/pkgconfig/gtk+-3.0.pc' -print -quit | grep -q .; then
    printf 'build-gnome-terminal.sh: static GTK3 pkg-config file not found under %s\n' "$DEPS_ABS" >&2
    exit 1
fi

mkdir -p "$OUT_ABS"
apply_source_patch "$SRC_ABS" "$GNOME_STATIC_PATCH"
apply_source_patch "$SRC_ABS" "$GNOME_PORTABLE_PATCH"
run "${TOOLCHAIN}/zig-cc" -target "$TARGET" -O2 -fPIC \
    -c "$GLIBC_SHIM_SOURCE" -o "$GLIBC_SHIM_OBJ"
render_native_file
export PKG_CONFIG_PATH="$PKG_CONFIG_PATH_VALUE"
export PKG_CONFIG="$PKG_CONFIG_ENV"
export PKG_CONFIG_ALLOW_SYSTEM_LIBS=1
export PKG_CONFIG_ALLOW_SYSTEM_CFLAGS=1

"${PKG_CONFIG_COMMAND[@]}" --exists gtk+-3.0 vte-2.91 libhandy-1 || {
    printf 'build-gnome-terminal.sh: static dependency prefix is incomplete (GTK3, VTE or libhandy missing)\n' >&2
    exit 1
}

run meson setup --wipe "$BUILD_DIR" "$SRC_ABS" \
    --native-file "$NATIVE_FILE" \
    --prefix "$INSTALL_PREFIX" --libdir lib --libexecdir libexec --buildtype release \
    --prefer-static --wrap-mode nodownload -Ddefault_library=static \
    -Ddocs=false -Dnautilus_extension=false -Dsearch_provider=false
run meson compile -C "$BUILD_DIR" -j "$JOBS"
run rm -rf "$PACKAGE_ROOT"
run meson install -C "$BUILD_DIR" --destdir "$PACKAGE_ROOT"
run mv "$PACKAGE_ROOT/usr/bin/gnome-terminal" "$PACKAGE_ROOT/usr/bin/gnome-terminal.bin"
run install -D -m 755 "$PORTABLE_LAUNCHER" "$PACKAGE_ROOT/gnome-terminal"
run ln -s ../../gnome-terminal "$PACKAGE_ROOT/usr/bin/gnome-terminal"
# The stock activation files contain absolute /usr paths. The portable
# launcher starts the server itself under a bundle-only app ID, so retaining
# those files would create a second, non-relocatable activation path.
run rm -f "$PACKAGE_ROOT/usr/share/dbus-1/services/org.gnome.Terminal.service" \
    "$PACKAGE_ROOT/usr/lib/systemd/user/gnome-terminal-server.service"
run install -D "$PACKAGE_ROOT/usr/libexec/gnome-terminal-server" "$ARTIFACT"
run install -D "$PACKAGE_ROOT/usr/bin/gnome-terminal.bin" "$CLIENT_ARTIFACT"
run "$REPO_ROOT/tools/verify-gnome-terminal-static.sh" "$ARTIFACT"
run "$REPO_ROOT/tools/verify-gnome-terminal-static.sh" "$CLIENT_ARTIFACT"
run "$ONEBIN" audit --profile hybrid --glibc-max "$BASELINE" \
    --level 1 --strict "${GNOME_TERMINAL_HOST_CONTRACT[@]}" "$ARTIFACT" \
    2>&1 | tee "$OUT_ABS/gnome-terminal-onebin-audit.txt"
run "$ONEBIN" audit --profile hybrid --glibc-max "$BASELINE" \
    --level 1 --strict "${GNOME_TERMINAL_HOST_CONTRACT[@]}" "$CLIENT_ARTIFACT" \
    2>&1 | tee "$OUT_ABS/gnome-terminal-client-onebin-audit.txt"
printf 'GNOME Terminal static GTK build: %s\n' "$ARTIFACT"
