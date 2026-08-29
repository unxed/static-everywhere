#!/usr/bin/env bash
# Build the pinned Layer-1 dependency prefix consumed by
# build-gnome-terminal.sh. The display server, GPU ABI, accessibility bridge
# and desktop data remain host inputs of Profile H; the GTK/UI code does not.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
LOCK="${REPO_ROOT}/contrib/gnome-terminal/deps.lock"
TOOLCHAIN="${REPO_ROOT}/onebin/toolchain"

PREFIX="${REPO_ROOT}/out/gnome-terminal/static-prefix"
WORK="${REPO_ROOT}/out/gnome-terminal/deps-work"
BASELINE=2.28
JOBS=${GNOME_TERMINAL_JOBS:-$(nproc 2>/dev/null || echo 4)}
FETCH=1
PRINT_PLAN=0

usage() {
    cat <<'EOF'
Usage: tools/build-gnome-terminal-deps.sh [OPTIONS]

  --prefix DIR       static dependency prefix
  --work DIR         source and build work directory
  --baseline VER     glibc baseline passed to Zig (default: 2.28)
  --jobs N           parallel build jobs
  --no-fetch         require all pinned source trees to already exist
  --print-plan       print the dependency order without touching the network
  -h, --help         show this message
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix)   PREFIX=${2:?--prefix needs a directory}; shift 2 ;;
        --work)     WORK=${2:?--work needs a directory}; shift 2 ;;
        --baseline) BASELINE=${2:?--baseline needs a version}; shift 2 ;;
        --jobs)     JOBS=${2:?--jobs needs a number}; shift 2 ;;
        --no-fetch) FETCH=0; shift ;;
        --print-plan) PRINT_PLAN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'build-gnome-terminal-deps.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

CC="${TOOLCHAIN}/zig-cc"
CXX="${TOOLCHAIN}/zig-c++"
AR="${TOOLCHAIN}/zig-ar"
RANLIB="${TOOLCHAIN}/zig-ranlib"
CMAKE_TOOLCHAIN="${TOOLCHAIN}/onebin-linux-hybrid.cmake"
MESON_NATIVE="${WORK}/onebin-linux-hybrid-meson.ini"
TARGET="x86_64-linux-gnu.${BASELINE}"

dependency_order=(
    zlib libffi pcre2 expat libpng pixman glib fribidi freetype harfbuzz
    fontconfig cairo pango gdk-pixbuf atk epoxy gtk lz4 vte libhandy
)

lock_field() {
    local name=$1 field=$2
    awk -v name="${name}" -v field="${field}" \
        '$1 == name { print $field; exit }' "${LOCK}"
}

quote_cmd() {
    printf '+ '
    printf '%q ' "$@"
    printf '\n'
}

run() {
    if [ "${PRINT_PLAN}" -eq 1 ]; then
        quote_cmd "$@"
    else
        quote_cmd "$@" >&2
        "$@"
    fi
}

run_env() {
    if [ "${PRINT_PLAN}" -eq 1 ]; then
        quote_cmd env "$@"
    else
        quote_cmd env "$@" >&2
        env "$@"
    fi
}

if [ "${PRINT_PLAN}" -eq 1 ]; then
    cat <<PLAN
# GNOME Terminal Profile H dependency producer
prefix: ${PREFIX}
work: ${WORK}
target: ${TARGET}
source pins: ${LOCK} (commit verified)
order: ${dependency_order[*]}
host contract: X11, OpenGL/EGL, accessibility IPC, schemas, fonts and session services
PLAN
    for dependency in "${dependency_order[@]}"; do
        printf '# pinned source: %s %s %s\n' \
            "${dependency}" "$(lock_field "${dependency}" 2)" "$(lock_field "${dependency}" 3)"
    done
    printf '# final consumer: tools/build-gnome-terminal.sh --deps-prefix %s\n' "${PREFIX}"
    exit 0
fi

for tool in git meson cmake pkg-config make install readelf; do
    command -v "${tool}" >/dev/null 2>&1 || {
        printf 'build-gnome-terminal-deps.sh: required tool not found: %s\n' "${tool}" >&2
        exit 1
    }
done
for tool in "${CC}" "${CXX}" "${AR}" "${RANLIB}"; do
    [ -x "${tool}" ] || {
        printf 'build-gnome-terminal-deps.sh: toolchain wrapper not found: %s\n' "${tool}" >&2
        exit 1
    }
done
command -v zig >/dev/null 2>&1 || {
    printf 'build-gnome-terminal-deps.sh: zig is not on PATH\n' >&2
    exit 1
}

mkdir -p "${PREFIX}" "${WORK}/sources" "${WORK}/build" "${PREFIX}/lib/pkgconfig"

cat >"${MESON_NATIVE}" <<EOF
[binaries]
c = '${CC}'
cpp = '${CXX}'
ar = '${AR}'
ranlib = '${RANLIB}'
strip = 'strip'

[built-in options]
c_args = ['-target', '${TARGET}', '-fPIE', '-ffunction-sections', '-fdata-sections', '-fstack-protector-strong']
cpp_args = ['-target', '${TARGET}', '-fPIE', '-ffunction-sections', '-fdata-sections', '-fstack-protector-strong']
c_link_args = ['-target', '${TARGET}', '-static-libgcc', '-Wl,--gc-sections', '-Wl,-z,relro', '-Wl,-z,now', '-Wl,-z,noexecstack', '-Wl,-z,nodelete', '-pie', '-s', '-L${PREFIX}/lib', '-L/usr/lib/x86_64-linux-gnu', '-L/usr/lib', '-L/lib/x86_64-linux-gnu']
cpp_link_args = ['-target', '${TARGET}', '-static-libgcc', '-static-libstdc++', '-Wl,--gc-sections', '-Wl,-z,relro', '-Wl,-z,now', '-Wl,-z,noexecstack', '-Wl,-z,nodelete', '-pie', '-s', '-L${PREFIX}/lib', '-L/usr/lib/x86_64-linux-gnu', '-L/usr/lib', '-L/lib/x86_64-linux-gnu']
default_library = 'static'
b_pie = true
EOF

export PATH="${TOOLCHAIN}:${PATH}"
export PKG_CONFIG_ALLOW_SYSTEM_LIBS=1
export PKG_CONFIG_ALLOW_SYSTEM_CFLAGS=1
export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PREFIX}/share/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/share/pkgconfig"
export CMAKE_PREFIX_PATH="${PREFIX}"

source_tree() {
    local name=$1 dir commit url actual
    commit=$(lock_field "${name}" 3)
    url=$(lock_field "${name}" 4)
    [ -n "${commit}" ] && [ -n "${url}" ] || {
        printf 'build-gnome-terminal-deps.sh: missing lock entry for %s\n' "${name}" >&2
        exit 1
    }

    dir="${WORK}/sources/${name}"
    if [ -d "${dir}/.git" ]; then
        actual=$(git -C "${dir}" rev-parse HEAD 2>/dev/null || true)
        if [ "${actual}" != "${commit}" ]; then
            [ "${FETCH}" -eq 1 ] || {
                printf 'build-gnome-terminal-deps.sh: %s is not pinned to %s\n' "${dir}" "${commit}" >&2
                exit 1
            }
            git -C "${dir}" remote set-url origin "${url}" 2>/dev/null || \
                git -C "${dir}" remote add origin "${url}"
            run git -C "${dir}" fetch --no-tags --depth=1 origin "${commit}"
            run git -C "${dir}" checkout --quiet --force --detach "${commit}"
        fi
    else
        [ "${FETCH}" -eq 1 ] || {
            printf 'build-gnome-terminal-deps.sh: source tree missing: %s\n' "${dir}" >&2
            exit 1
        }
        run git init --quiet "${dir}"
        run git -C "${dir}" remote add origin "${url}"
        run git -C "${dir}" fetch --no-tags --depth=1 origin "${commit}"
        run git -C "${dir}" checkout --quiet --force --detach "${commit}"
    fi

    actual=$(git -C "${dir}" rev-parse HEAD)
    [ "${actual}" = "${commit}" ] || {
        printf 'build-gnome-terminal-deps.sh: source pin mismatch for %s: %s != %s\n' \
            "${name}" "${actual}" "${commit}" >&2
        exit 1
    }
    printf '%s\n' "${dir}"
}

mark() {
    local name=$1 commit
    commit=$(lock_field "${name}" 3)
    printf '%s\n' "${commit}" >"${PREFIX}/.built-${name}"
}

built() {
    local name=$1 commit
    commit=$(lock_field "${name}" 3)
    [ -f "${PREFIX}/.built-${name}" ] && grep -Fxq "${commit}" "${PREFIX}/.built-${name}"
}

require_pc() {
    local pc prefix
    for pc in "$@"; do
        prefix=$(pkg-config --variable=prefix "${pc}" 2>/dev/null || true)
        [ "${prefix}" = "${PREFIX}" ] || {
            printf 'build-gnome-terminal-deps.sh: %s resolved outside the static prefix: %s\n' \
                "${pc}" "${prefix:-not found}" >&2
            exit 1
        }
    done
}

cmake_dep() {
    local name=$1 source=$2 build_name=$3
    shift 3
    built "${name}" && return 0
    local build_dir="${WORK}/build/${build_name}"
    mkdir -p "${build_dir}"
    run cmake -S "${source}" -B "${build_dir}" \
        -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="${CMAKE_TOOLCHAIN}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_PREFIX_PATH="${PREFIX}" \
        "$@"
    run cmake --build "${build_dir}" --parallel "${JOBS}"
    run cmake --install "${build_dir}"
    mark "${name}"
}

meson_dep() {
    local name=$1 source=$2 build_name=$3
    shift 3
    built "${name}" && return 0
    local build_dir="${WORK}/build/${build_name}"
    run meson setup --wipe "${build_dir}" "${source}" \
        --native-file "${MESON_NATIVE}" \
        --prefix "${PREFIX}" --libdir lib --buildtype release \
        --prefer-static --wrap-mode nodownload -Ddefault_library=static "$@"
    run meson compile -C "${build_dir}" -j "${JOBS}"
    run meson install -C "${build_dir}"
    mark "${name}"
}

autotools_dep() {
    local name=$1 source=$2 build_name=$3
    shift 3
    built "${name}" && return 0
    local build_dir="${WORK}/build/${build_name}"
    if [ ! -x "${source}/configure" ]; then
        # libffi's autogen.sh only passes -I m4. With the current libtool,
        # LT_SYS_SYMBOL_USCORE is supplied by the system ltdl.m4 and must be
        # visible to aclocal explicitly.
        run bash -c "cd \"${source}\" && autoreconf -v -i -I m4 -I /usr/share/aclocal"
    fi
    run mkdir -p "${build_dir}"
    (
        cd "${build_dir}"
        run_env CC="${CC}" AR="${AR}" RANLIB="${RANLIB}" \
            CFLAGS="-target ${TARGET} -fPIC -ffile-prefix-map=${source}=." \
            LDFLAGS="-target ${TARGET} -static-libgcc" \
            "${source}/configure" --host=x86_64-linux-gnu \
            --prefix="${PREFIX}" --disable-shared --enable-static "$@"
    )
    run make -C "${build_dir}" -j "${JOBS}"
    run make -C "${build_dir}" install
    mark "${name}"
}

write_simple_pc() {
    local name=$1 version=$2 libs=$3
    cat >"${PREFIX}/lib/pkgconfig/${name}.pc" <<EOF
prefix=${PREFIX}
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: ${name}
Description: pinned static dependency
Version: ${version}
Libs: -L\${libdir} ${libs}
Cflags: -I\${includedir}
EOF
}

zlib_src=$(source_tree zlib)
cmake_dep zlib "${zlib_src}" zlib \
    -DZLIB_BUILD_SHARED=OFF -DZLIB_BUILD_STATIC=ON -DZLIB_BUILD_TESTING=OFF
find "${PREFIX}/lib" -maxdepth 1 -type f -name 'libz.so*' -delete
write_simple_pc zlib "$(lock_field zlib 2)" -lz

libffi_src=$(source_tree libffi)
autotools_dep libffi "${libffi_src}" libffi \
    --disable-multi-os-directory --disable-docs

pcre2_src=$(source_tree pcre2)
cmake_dep pcre2 "${pcre2_src}" pcre2 \
    -DPCRE2_BUILD_PCRE2_8=ON -DPCRE2_BUILD_PCRE2_16=OFF \
    -DPCRE2_BUILD_PCRE2_32=OFF -DPCRE2_BUILD_PCRE2GREP=OFF \
    -DPCRE2_BUILD_TESTS=OFF -DPCRE2_SUPPORT_JIT=OFF

expat_src=$(source_tree expat)
cmake_dep expat "${expat_src}/expat" expat \
    -DEXPAT_BUILD_TESTS=OFF -DEXPAT_BUILD_EXAMPLES=OFF -DEXPAT_BUILD_TOOLS=OFF \
    -DEXPAT_SHARED_LIBS=OFF

libpng_src=$(source_tree libpng)
cmake_dep libpng "${libpng_src}" libpng \
    -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_TESTS=OFF \
    -DSKIP_INSTALL_EXECUTABLES=ON -DZLIB_ROOT="${PREFIX}"

pixman_src=$(source_tree pixman)
meson_dep pixman "${pixman_src}" pixman \
    -Dtests=disabled -Ddemos=disabled -Dgtk=disabled -Dopenmp=disabled

glib_src=$(source_tree glib)
require_pc zlib libffi libpcre2-8
meson_dep glib "${glib_src}" glib \
    -Dtests=false -Dinstalled_tests=false -Dman=false -Dman-pages=disabled \
    -Ddocumentation=false -Dintrospection=disabled -Dselinux=disabled \
    -Dlibmount=disabled -Dsysprof=disabled -Dsystemtap=false \
    -Dglib_debug=disabled -Dnls=disabled

fribidi_src=$(source_tree fribidi)
meson_dep fribidi "${fribidi_src}" fribidi \
    -Ddocs=false -Dtests=false -Dbin=false

freetype_src=$(source_tree freetype)
cmake_dep freetype "${freetype_src}" freetype \
    -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_PNG=ON \
    -DFT_DISABLE_BROTLI=ON -DFT_DISABLE_BZIP2=ON \
    -DZLIB_LIBRARY="${PREFIX}/lib/libz.a" -DZLIB_INCLUDE_DIR="${PREFIX}/include"

harfbuzz_src=$(source_tree harfbuzz)
require_pc freetype2
meson_dep harfbuzz "${harfbuzz_src}" harfbuzz \
    -Dglib=disabled -Dicu=disabled -Dgraphite2=disabled -Dcairo=disabled \
    -Dgobject=disabled -Dintrospection=disabled -Ddocs=disabled \
    -Dtests=disabled -Dutilities=disabled -Dbenchmark=disabled \
    -Dsubset=disabled -Dfreetype=enabled

if [ ! -f "${PREFIX}/.built-freetype-harfbuzz" ]; then
    freetype_build="${WORK}/build/freetype-harfbuzz"
    run cmake -S "${freetype_src}" -B "${freetype_build}" \
        -G Ninja -DCMAKE_TOOLCHAIN_FILE="${CMAKE_TOOLCHAIN}" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
        -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DBUILD_SHARED_LIBS=OFF -DFT_DISABLE_HARFBUZZ=OFF \
        -DFT_DYNAMIC_HARFBUZZ=OFF -DFT_REQUIRE_HARFBUZZ=ON \
        -DHarfBuzz_INCLUDE_DIR="${PREFIX}/include" \
        -DHarfBuzz_LIBRARY="${PREFIX}/lib/libharfbuzz.a" \
        -DZLIB_LIBRARY="${PREFIX}/lib/libz.a" \
        -DZLIB_INCLUDE_DIR="${PREFIX}/include"
    run cmake --build "${freetype_build}" --parallel "${JOBS}"
    run cmake --install "${freetype_build}"
    printf '%s\n' "$(lock_field freetype 3)" >"${PREFIX}/.built-freetype-harfbuzz"
fi

fontconfig_src=$(source_tree fontconfig)
require_pc freetype2 expat
meson_dep fontconfig "${fontconfig_src}" fontconfig \
    -Ddoc=disabled -Dtests=disabled -Dtools=disabled -Dcache-build=disabled \
    -Diconv=disabled -Dnls=disabled -Dsysconfdir=/etc -Ddatadir=/usr/share \
    -Dcache-dir=/var/cache/fontconfig

cairo_src=$(source_tree cairo)
require_pc glib-2.0 fontconfig freetype2 libpng pixman-1 zlib
meson_dep cairo "${cairo_src}" cairo \
    -Dfontconfig=enabled -Dfreetype=enabled -Dpng=enabled -Dzlib=enabled \
    -Dxlib=enabled -Dxcb=disabled -Dxlib-xcb=disabled -Dglib=enabled \
    -Dtee=disabled -Dspectre=disabled -Dsymbol-lookup=disabled \
    -Dtests=disabled -Dgtk2-utils=disabled

pango_src=$(source_tree pango)
require_pc glib-2.0 fribidi harfbuzz cairo fontconfig freetype2
meson_dep pango "${pango_src}" pango \
    -Dfontconfig=enabled -Dcairo=enabled -Dfreetype=enabled \
    -Dxft=disabled -Dlibthai=disabled -Dintrospection=disabled \
    -Dgtk_doc=false -Dsysprof=disabled -Dinstall-tests=false

gdk_pixbuf_src=$(source_tree gdk-pixbuf)
require_pc glib-2.0 gobject-2.0 gio-2.0 libpng
meson_dep gdk-pixbuf "${gdk_pixbuf_src}" gdk-pixbuf \
    -Dpng=enabled -Djpeg=disabled -Dtiff=disabled \
    -Dbuiltin_loaders=png,bmp,gif,ico,ani,pnm,xpm,xbm,tga,icns,qtif \
    -Dintrospection=disabled -Dman=false -Dtests=false \
    -Dinstalled_tests=false -Dgio_sniffing=false -Dgtk_doc=false -Ddocs=false

atk_src=$(source_tree atk)
require_pc glib-2.0 gobject-2.0
meson_dep atk "${atk_src}" atk \
    -Dintrospection=false -Ddocs=false -Dtests=false

epoxy_src=$(source_tree epoxy)
meson_dep epoxy "${epoxy_src}" epoxy \
    -Dglx=yes -Degl=yes -Dx11=true -Dtests=false -Ddocs=false

gtk_src=$(source_tree gtk)
require_pc glib-2.0 gobject-2.0 gio-2.0 cairo pango pangocairo pangoft2 \
    gdk-pixbuf-2.0 fontconfig atk epoxy harfbuzz fribidi
meson_dep gtk "${gtk_src}" gtk \
    -Dx11_backend=true -Dwayland_backend=false -Dbroadway_backend=false \
    -Dxinerama=no -Dcloudproviders=false -Dprofiler=false -Dtracker3=false \
    -Dprint_backends=file -Dgtk_doc=false -Dman=false -Dintrospection=false \
    -Ddemos=false -Dexamples=false -Dtests=false -Dinstalled_tests=false \
    -Dbuiltin_immodules=xim,multipress

lz4_src=$(source_tree lz4)
if ! built lz4; then
    run make -C "${lz4_src}/lib" clean
    run make -C "${lz4_src}/lib" -j "${JOBS}" \
        CC="${CC}" AR="${AR}" RANLIB="${RANLIB}" \
        CFLAGS="-target ${TARGET} -fPIC -ffile-prefix-map=${lz4_src}=." \
        BUILD_STATIC=yes BUILD_SHARED=no
    run install -D "${lz4_src}/lib/liblz4.a" "${PREFIX}/lib/liblz4.a"
    run install -d "${PREFIX}/include"
    run install -m 644 "${lz4_src}/lib/lz4.h" "${lz4_src}/lib/lz4hc.h" \
        "${lz4_src}/lib/lz4frame.h" "${PREFIX}/include/"
    write_simple_pc liblz4 "$(lock_field lz4 2)" -llz4
    mark lz4
fi

require_pc glib-2.0 pango gtk+-3.0 libpcre2-8 fribidi liblz4
vte_src=$(source_tree vte)
meson_dep vte "${vte_src}" vte \
    -Dgtk3=true -Dgtk4=false -Dfribidi=true -Dgnutls=false -Dicu=false \
    -D_systemd=false -Dgir=false -Dvapi=false -Dglade=false -Ddocs=false

libhandy_src=$(source_tree libhandy)
require_pc gtk+-3.0 glib-2.0
meson_dep libhandy "${libhandy_src}" libhandy \
    -Dintrospection=disabled -Dvapi=false -Dgtk_doc=false \
    -Dtests=false -Dexamples=false -Dglade_catalog=disabled

for library in \
    libz.a libffi.a libpcre2-8.a libexpat.a libpng16.a libpixman-1.a \
    libglib-2.0.a libfribidi.a libfreetype.a libharfbuzz.a libfontconfig.a \
    libcairo.a libpango-1.0.a libpangocairo-1.0.a libgdk_pixbuf-2.0.a \
    libatk-1.0.a libepoxy.a libgtk-3.a liblz4.a libvte-2.91.a libhandy-1.a; do
    [ -f "${PREFIX}/lib/${library}" ] || {
        printf 'build-gnome-terminal-deps.sh: expected static archive missing: %s\n' "${PREFIX}/lib/${library}" >&2
        exit 1
    }
done

printf 'GNOME Terminal static dependency prefix ready: %s\n' "${PREFIX}"
