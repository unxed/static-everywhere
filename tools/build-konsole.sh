#!/usr/bin/env bash
# Build the Konsole showcase with static Conan Qt and source-built KF6.
# Host dependencies are limited to X11/xcb and the OpenGL ABI, as in f4 qt.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
ONEBIN_BIN="$REPO_ROOT/onebin/build/onebin"
ZIGCC="$REPO_ROOT/onebin/toolchain/zig-cc"
ZIGCXX="$REPO_ROOT/onebin/toolchain/zig-c++"
GLIBC_BASELINE=2.27
KONSOLE_REF=264ecd0808f752a10204f954dfc1f87f7aba9ea8
KDE_BUILDER_REF=0e661248c9da227dc5c129949cf7a403eb6d4d7e
OUT=./out/konsole
KDE_BUILDER=
PRINT_PLAN=0

usage() {
    cat <<'EOF'
Usage: tools/build-konsole.sh --kde-builder DIR [OPTIONS]

  --kde-builder DIR       checked-out kde-builder source tree
  --out DIR               output directory (default: ./out/konsole)
  --konsole-ref SHA       Konsole commit (default: pinned showcase commit)
  --kde-builder-ref SHA   kde-builder commit (default: pinned showcase commit)
  --print-plan            print every build command without executing it
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --kde-builder) KDE_BUILDER=${2:-}; shift 2 ;;
        --out) OUT=${2:-}; shift 2 ;;
        --konsole-ref) KONSOLE_REF=${2:-}; shift 2 ;;
        --kde-builder-ref) KDE_BUILDER_REF=${2:-}; shift 2 ;;
        --print-plan) PRINT_PLAN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'error: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ -z $KDE_BUILDER ]]; then
    printf 'error: --kde-builder is required\n' >&2
    exit 2
fi
if [[ $OUT = /* ]]; then
    OUT_ABS=$OUT
else
    OUT_ABS=$(pwd)/${OUT#./}
fi
if [[ -d $KDE_BUILDER ]]; then
    KDE_BUILDER=$(cd -- "$KDE_BUILDER" && pwd)
fi

KDE_SOURCE_DIR="$OUT_ABS/kde-source"
KDE_BUILD_DIR="$OUT_ABS/kde-build"
KDE_INSTALL_DIR="$OUT_ABS/kde-install"
KDE_LOG_DIR="$OUT_ABS/kde-logs"
KDE_STATE_DIR="$OUT_ABS/kde-state"
QT_OUT="$OUT_ABS/qt"
CONAN_VENV="$OUT_ABS/conan-venv"
CONAN_HOME=${CONAN_HOME:-$HOME/.conan2}
KDE_JOBS=${KONSOLE_JOBS:-$(nproc)}
KDE_CONFIG="$OUT_ABS/kde-builder.yaml"
CONAN_TOOLCHAIN="$QT_OUT/conan_toolchain.cmake"
CMAKE_PREFIX_PATH="$QT_OUT;$KDE_INSTALL_DIR"
TARGET_TRIPLE="x86_64-linux-gnu.${GLIBC_BASELINE}"
GIT_CONFIG_GLOBAL="$OUT_ABS/gitconfig"
QT_PACKAGE_ROOT=

# Keep the Conan metadata lookup in one tested helper; package and host
# architecture names are not stable parts of CMakeDeps filenames.
# shellcheck disable=SC1091
source "$REPO_ROOT/contrib/konsole/qt-package-root.sh"

quote_cmd() {
    printf '+ '
    printf '%q ' "$@"
    printf '\n'
}
run() {
    if [[ $PRINT_PLAN -eq 1 ]]; then
        quote_cmd "$@"
    else
        quote_cmd "$@" >&2
        "$@"
    fi
}
run_env() {
    if [[ $PRINT_PLAN -eq 1 ]]; then
        quote_cmd env "$@"
    else
        quote_cmd env "$@" >&2
        env "$@"
    fi
}

printf '# Konsole showcase plan\n'
printf 'konsole_ref=%s\nkde_builder_ref=%s\nglibc_baseline=%s\n' \
    "$KONSOLE_REF" "$KDE_BUILDER_REF" "$GLIBC_BASELINE"
printf 'host contract: X11/xcb/ICE/SM and runtime-loaded OpenGL; Qt/KF6: source-built\n'
# shellcheck disable=SC2034  # lock-file fields are deliberately read for a plan-only inventory
while IFS=' ' read -r name version _hash url; do
    [[ -z $name || $name == \#* ]] && continue
    printf '# dependency: %s %s\n' "$name" "$version"
done < "$REPO_ROOT/contrib/konsole/deps.lock"

if [[ $PRINT_PLAN -eq 0 ]]; then
    [[ -x $ONEBIN_BIN ]] || { printf 'error: build onebin first\n' >&2; exit 1; }
    command -v zig >/dev/null || { printf 'error: zig is not on PATH\n' >&2; exit 1; }
    command -v uv >/dev/null || { printf 'error: uv is not on PATH\n' >&2; exit 1; }
    [[ -f "$KDE_BUILDER/kde-builder" ]] || {
        printf 'error: kde-builder source tree is missing %s/kde-builder\n' "$KDE_BUILDER" >&2
        exit 1
    }
    actual_kde_builder=$(git -C "$KDE_BUILDER" rev-parse HEAD)
    [[ $actual_kde_builder == "$KDE_BUILDER_REF" ]] || {
        printf 'error: kde-builder is %s, expected %s\n' "$actual_kde_builder" "$KDE_BUILDER_REF" >&2
        exit 1
    }
fi

run mkdir -p "$OUT_ABS" "$QT_OUT" "$KDE_SOURCE_DIR" "$KDE_BUILD_DIR" \
    "$KDE_INSTALL_DIR" "$KDE_LOG_DIR" "$KDE_STATE_DIR"
run touch "$GIT_CONFIG_GLOBAL"
run "$ZIGCC" -target "$TARGET_TRIPLE" -O2 -fPIC -c \
    "$REPO_ROOT/contrib/f4-qt/compat/glibc-shims.c" \
    -o "$OUT_ABS/compat-glibc-shims.o"

run mkdir -p "$CONAN_VENV"
run uv venv --python 3.12 --clear "$CONAN_VENV"
run uv pip install --python "$CONAN_VENV/bin/python" \
    conan==2.29.1 cmake==3.31.6 ninja==1.13.0 setproctitle
run_env PATH="$CONAN_VENV/bin:$PATH" CONAN_HOME="$CONAN_HOME" \
    conan profile detect --force

# This is f4's exact fontconfig transport workaround. The runner may receive
# HTTP 418 from freedesktop.org; the Conan checksum remains authoritative.
run_env PATH="$CONAN_VENV/bin:$PATH" CONAN_HOME="$CONAN_HOME" \
    conan download fontconfig/2.15.0 --only-recipe --remote=conancenter
if [[ $PRINT_PLAN -eq 1 ]]; then
    # shellcheck disable=SC2016  # this command is printed for a later shell, not expanded here
    quote_cmd bash -c 'fontconfig_recipe=$(conan cache path fontconfig/2.15.0); copy=$(mktemp -d /tmp/static-everywhere-fontconfig.XXXXXX); cp "$fontconfig_recipe/conanfile.py" "$fontconfig_recipe/conandata.yml" "$copy/"; sed -i "s#https://www.freedesktop.org/software/fontconfig/release/#https://distfiles.macports.org/fontconfig/#" "$copy/conandata.yml"; grep -q "https://distfiles.macports.org/fontconfig/fontconfig-2.15.0.tar.xz" "$copy/conandata.yml"; conan export "$copy" --name=fontconfig --version=2.15.0'
else
    fontconfig_recipe=$(env PATH="$CONAN_VENV/bin:$PATH" CONAN_HOME="$CONAN_HOME" \
        conan cache path fontconfig/2.15.0)
    fontconfig_copy=$(mktemp -d /tmp/static-everywhere-fontconfig.XXXXXX)
    cp "$fontconfig_recipe/conanfile.py" "$fontconfig_recipe/conandata.yml" "$fontconfig_copy/"
    sed -i 's#https://www.freedesktop.org/software/fontconfig/release/#https://distfiles.macports.org/fontconfig/#' \
        "$fontconfig_copy/conandata.yml"
    grep -q 'https://distfiles.macports.org/fontconfig/fontconfig-2.15.0.tar.xz' \
        "$fontconfig_copy/conandata.yml"
    run_env PATH="$CONAN_VENV/bin:$PATH" CONAN_HOME="$CONAN_HOME" \
        conan export "$fontconfig_copy" --name=fontconfig --version=2.15.0
fi

# Conan package IDs do not include the glibc baseline, so the native packages
# that are compiled into the target are explicitly rebuilt instead of silently
# taking a GCC binary. libmount is deliberately absent from this list: the
# CCI util-linux recipe cannot be rebuilt with the Zig glibc headers because
# its syscall compatibility wrappers collide with declarations in that
# header set. Its direct Conan requirement still supplies the headers and
# static target metadata; Conan may use its compatible published package.
conan_args=(
    install "$REPO_ROOT/contrib/konsole/qt-host"
    --build=missing
    --build='brotli/*' --build='bzip2/*' --build='double-conversion/*'
    --build='expat/*' --build='fontconfig/*' --build='freetype/*'
    --build='harfbuzz/*' --build='icu/*' --build='libffi/*'
    --build='libiconv/*' --build='libpng/*' --build='md4c/*'
    --build='pcre2/*' --build='qt/*' --build='xkbcommon/*'
    --build='xz_utils/*' --build='zlib/*'
    -s:h build_type=Release -s:h compiler.cppstd=gnu20
    -s:b build_type=Release -s:b compiler.cppstd=gnu20
    -o:h 'qt/*:shared=False' -o:h 'qt/*:opengl=desktop'
    -o:h 'qt/*:qtdeclarative=True'
    -o:h 'qt/*:qtmultimedia=True' -o:h 'qt/*:qtshadertools=True'
    -o:h 'qt/*:qttools=True'
    -o:h 'qt/*:qtwayland=False'
    -o:h 'qt/*:with_dbus=True' -o:h 'qt/*:with_egl=True'
    -o:h 'qt/*:with_x11=True'
    -o:h 'qt/*:with_glib=False' -o:h 'qt/*:with_openal=False'
    -o:h 'qt/*:with_gstreamer=False' -o:h 'qt/*:with_pulseaudio=False'
    -o:h 'qt/*:with_libalsa=False'
    -o:h 'qt/*:openssl=False' -o:h 'xkbcommon/*:with_x11=True'
    -o:h 'xkbcommon/*:with_wayland=False'
    -c "tools.build:compiler_executables={\"c\":\"$ZIGCC\",\"cpp\":\"$ZIGCXX\"}"
    -c 'tools.cmake.cmaketoolchain:extra_variables={"CMAKE_C_COMPILER_LAUNCHER":"ccache","CMAKE_CXX_COMPILER_LAUNCHER":"ccache","CMAKE_SIZEOF_VOID_P":"8","CMAKE_LIBRARY_ARCHITECTURE":"x86_64-linux-gnu","CMAKE_C_IMPLICIT_INCLUDE_DIRECTORIES":"/usr/include","CMAKE_CXX_IMPLICIT_INCLUDE_DIRECTORIES":"/usr/include","CMAKE_SKIP_RPATH":"ON","CMAKE_FIND_PACKAGE_PREFER_CONFIG":"ON"}'
    -c "tools.build:cflags=[\"-target\",\"$TARGET_TRIPLE\"]"
    -c "tools.build:cxxflags=[\"-target\",\"$TARGET_TRIPLE\"]"
    -c "tools.build:sharedlinkflags=[\"-target\",\"$TARGET_TRIPLE\",\"$OUT_ABS/compat-glibc-shims.o\",\"-Wl,--strip-debug\"]"
    -c "tools.build:exelinkflags=[\"-target\",\"$TARGET_TRIPLE\",\"-pie\",\"$OUT_ABS/compat-glibc-shims.o\",\"-Wl,--strip-debug\"]"
    -cc "core.sources:download_cache=$OUT_ABS/sources-backup"
    -cc 'core.sources:download_urls=["https://c3i.jfrog.io/artifactory/conan-center-backup-sources/","origin"]'
    -c tools.system.package_manager:mode=check
    -vv --output-folder="$QT_OUT"
)
run_env PATH="$CONAN_VENV/bin:$PATH" \
    PKG_CONFIG_PATH="/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig:${PKG_CONFIG_PATH:-}" \
    CONAN_HOME="$CONAN_HOME" conan "${conan_args[@]}"
run_env PATH="$CONAN_VENV/bin:$PATH" CONAN_HOME="$CONAN_HOME" \
    conan cache clean '*' --build --temp

if [[ $PRINT_PLAN -eq 1 ]]; then
    # shellcheck disable=SC2016  # variables belong to the printed inner shell
    quote_cmd bash -c 'pc_dirs=$(find "$CONAN_HOME/p/b" -type f -name "*.pc" -printf "%h\\n" 2>/dev/null | sort -u | paste -sd: -); export PKG_CONFIG_PATH="$pc_dirs:/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig:${PKG_CONFIG_PATH:-}"; pkg-config --modversion xkbcommon'
else
    pc_dirs=$(find "$CONAN_HOME/p/b" -type f -name '*.pc' -printf '%h\n' 2>/dev/null | sort -u | paste -sd: -)
    export PKG_CONFIG_PATH="$pc_dirs:/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig:${PKG_CONFIG_PATH:-}"
    pkg-config --modversion xkbcommon || {
        printf 'warning: Conan xkbcommon .pc file was not found; do not accept a host xkbcommon fallback silently\n' >&2
    }
fi

# Where Conan unpacked the Qt package.
#
# Needed because ki18n compiles src/i18n-qml against Qt6::Qml, whose
# headers include <qqmlintegration.h> -- and that header does not live in
# include/QtQml. It belongs to the separate QtQmlIntegration module,
# which upstream Qt propagates through Qt6::Qml but this Conan package
# does not, so the compile line never receives the directory and the
# build fails with "'qqmlintegration.h' file not found".
#
# Read, never derive: Conan writes the root into its own generated data
# file as qt_PACKAGE_FOLDER_RELEASE, which is the same variable
# contrib/f4-qt/import-qt-static-plugins.cmake already relies on. Do not
# reconstruct it from a cache layout that is not ours to predict.
# CMakeDeps writes the Qt package root into the generated data file. Add
# that root to CMAKE_PREFIX_PATH as well as the generator directory: the
# Qt Conan package owns Qt6Core/Qt6Gui/... configs outside $QT_OUT.
if [[ $PRINT_PLAN -eq 0 ]]; then
    QT_PACKAGE_ROOT=$(konsole_qt_package_root "$QT_OUT")
    CMAKE_PREFIX_PATH="$QT_OUT;$QT_PACKAGE_ROOT;$KDE_INSTALL_DIR"
fi

render_config() {
    sed -e "s|@KDE_SOURCE_DIR@|$KDE_SOURCE_DIR|g" \
        -e "s|@KDE_BUILD_DIR@|$KDE_BUILD_DIR|g" \
        -e "s|@KDE_INSTALL_DIR@|$KDE_INSTALL_DIR|g" \
        -e "s|@KDE_LOG_DIR@|$KDE_LOG_DIR|g" \
        -e "s|@KDE_STATE_DIR@|$KDE_STATE_DIR|g" \
        -e "s|@KDE_JOBS@|$KDE_JOBS|g" \
        -e "s|@CONAN_TOOLCHAIN@|$CONAN_TOOLCHAIN|g" \
        -e "s|@ZIGCC@|$ZIGCC|g" \
        -e "s|@ZIGCXX@|$ZIGCXX|g" \
        -e "s|@CMAKE_PREFIX_PATH@|$CMAKE_PREFIX_PATH|g" \
        -e "s|@PROJECT_INCLUDE@|$REPO_ROOT/contrib/konsole/project-include.cmake|g" \
        -e "s|@KONSOLE_REF@|$KONSOLE_REF|g" \
        -e "s|@QT_PACKAGE_ROOT@|$QT_PACKAGE_ROOT|g" \
        "$REPO_ROOT/contrib/konsole/kde-builder.yaml.in"
}
if [[ $PRINT_PLAN -eq 1 ]]; then
    quote_cmd bash -c "rendered config > $KDE_CONFIG"
else
    render_config >"$KDE_CONFIG"
fi

run_env GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" PYTHONPATH="$KDE_BUILDER" \
    XDG_STATE_HOME="$KDE_STATE_DIR" \
    CC="$ZIGCC" CXX="$ZIGCXX" \
    PATH="$CONAN_VENV/bin:$PATH" python3 "$KDE_BUILDER/kde-builder" \
    --rc-file "$KDE_CONFIG" konsole

KONSOLE_BIN="$KDE_INSTALL_DIR/bin/konsole"
if [[ $PRINT_PLAN -eq 1 ]]; then
    quote_cmd "$REPO_ROOT/tools/verify-konsole-artifact.sh" "$KONSOLE_BIN"
    quote_cmd "$REPO_ROOT/tools/audit-with-hygiene-waivers.sh" "$ONEBIN_BIN" \
        --profile hybrid --glibc-max "$GLIBC_BASELINE" \
        --allow libc.so.6 --allow libdl.so.2 --allow libpthread.so.0 \
        --allow libX11.so.6 --allow libX11-xcb.so.1 --allow libxcb.so.1 \
        --allow libxcb-cursor.so.0 --allow libxcb-icccm.so.4 \
        --allow libxcb-image.so.0 --allow libxcb-keysyms.so.1 \
        --allow libxcb-randr.so.0 --allow libxcb-render.so.0 \
        --allow libxcb-render-util.so.0 --allow libxcb-shape.so.0 \
        --allow libxcb-shm.so.0 --allow libxcb-sync.so.1 \
        --allow libxcb-xfixes.so.0 --allow libxcb-xkb.so.1 \
        --allow libICE.so.6 --allow libSM.so.6 --level 1 --strict "$KONSOLE_BIN"
else
    [[ -x $KONSOLE_BIN ]] || { printf 'error: kde-builder did not install %s\n' "$KONSOLE_BIN" >&2; exit 1; }
    "$REPO_ROOT/tools/verify-konsole-artifact.sh" "$KONSOLE_BIN" | tee "$OUT_ABS/konsole-audit.txt"
    audit_args=(
        --profile hybrid --glibc-max "$GLIBC_BASELINE"
        --allow libc.so.6 --allow libdl.so.2 --allow libpthread.so.0
        --allow libX11.so.6 --allow libX11-xcb.so.1 --allow libxcb.so.1
        --allow libxcb-cursor.so.0 --allow libxcb-icccm.so.4
        --allow libxcb-image.so.0 --allow libxcb-keysyms.so.1
        --allow libxcb-randr.so.0 --allow libxcb-render.so.0
        --allow libxcb-render-util.so.0 --allow libxcb-shape.so.0
        --allow libxcb-shm.so.0 --allow libxcb-sync.so.1
        --allow libxcb-xfixes.so.0 --allow libxcb-xkb.so.1
        --allow libICE.so.6 --allow libSM.so.6 --level 1 --strict "$KONSOLE_BIN"
    )
    "$REPO_ROOT/tools/audit-with-hygiene-waivers.sh" "$ONEBIN_BIN" "${audit_args[@]}" \
        | tee "$OUT_ABS/konsole-onebin-audit.txt"
fi
printf 'Konsole build output: %s\n' "$OUT_ABS"
