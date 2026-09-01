#!/usr/bin/env bash
# Build the pinned static dependencies needed by the far2l SDL preview.
#
# This is deliberately separate from build-far2l.sh: the latter consumes a
# populated --deps-prefix, while this script is the reproducible CI producer
# for that prefix. The host is used only for X11/OpenGL headers and libraries
# which SDL loads at runtime; the graphics and NetRocks libraries come from
# contrib/far2l/deps.lock. Host libc headers are never part of this contract.

set -euo pipefail

# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
LOCK="${REPO_ROOT}/contrib/far2l/deps.lock"
TOOLCHAIN="${REPO_ROOT}/onebin/toolchain"
MESON_NATIVE="${TOOLCHAIN}/onebin-linux-hybrid-meson.ini"

PREFIX="${REPO_ROOT}/out/far2l/deps-prefix"
WORK="${REPO_ROOT}/out/far2l/deps-work"
JOBS=4
PRINT_PLAN=0
PROFILE=hybrid

usage() {
    sed -n '2,11p' "$0"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --profile) PROFILE=${2:?--profile needs hybrid or universal}; shift 2 ;;
        --prefix) PREFIX=${2:?--prefix needs a directory}; shift 2 ;;
        --work)   WORK=${2:?--work needs a directory}; shift 2 ;;
        --jobs)   JOBS=${2:?--jobs needs a number}; shift 2 ;;
        --print-plan) PRINT_PLAN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "build-far2l-deps.sh: unknown argument: $1" >&2; exit 2 ;;
    esac
done

case "${PROFILE}" in
    hybrid)
        MESON_NATIVE="${TOOLCHAIN}/onebin-linux-hybrid-meson.ini"
        CMAKE_TOOLCHAIN="${TOOLCHAIN}/onebin-linux-hybrid.cmake"
        TARGET="x86_64-linux-gnu.2.28"
        ;;
    universal)
        MESON_NATIVE="${TOOLCHAIN}/onebin-linux-universal-meson.ini"
        CMAKE_TOOLCHAIN="${TOOLCHAIN}/onebin-linux-universal-deps.cmake"
        TARGET="x86_64-linux-musl"
        ;;
    *)
        echo "build-far2l-deps.sh: --profile must be hybrid or universal (got '${PROFILE}')" >&2
        exit 2
        ;;
esac

CC="${TOOLCHAIN}/zig-cc"
CXX="${TOOLCHAIN}/zig-c++"
AR="${TOOLCHAIN}/zig-ar"
RANLIB="${TOOLCHAIN}/zig-ranlib"
if [ "${PRINT_PLAN}" -eq 1 ]; then
    cat <<PLAN
# far2l SDL dependency prefix
profile: ${PROFILE}
PREFIX=${PREFIX}
WORK=${WORK}
source archives: contrib/far2l/deps.lock (sha256 verified)
toolchain: ${CMAKE_TOOLCHAIN}
Meson: >= 1.11.0 (fontconfig 2.18.3 requirement)
order: zlib -> mbedtls -> openssl -> expat -> freetype(pass 1) -> harfbuzz -> freetype(pass 2) -> fontconfig -> sdl2 -> libssh -> libnfs -> neon
fontconfig install: copy static archive, generated pc and headers; never run meson install
host link inputs: X11/OpenGL only; no host SDL/Qt/KDE/FreeType/HarfBuzz/Fontconfig
PLAN
    exit 0
fi

MESON_MIN_VERSION=1.11.0
meson_version=$(meson --version 2>/dev/null || true)
if [ -z "${meson_version}" ]; then
    echo 'build-far2l-deps.sh: Meson is required (fontconfig 2.18.3 needs >= 1.11.0)' >&2
    exit 1
fi
meson_floor=$(printf '%s\n' "${MESON_MIN_VERSION}" "${meson_version}" | sort -V | head -n 1)
if [ "${meson_floor}" != "${MESON_MIN_VERSION}" ]; then
    printf 'build-far2l-deps.sh: Meson %s is too old; need >= %s\n' \
        "${meson_version}" "${MESON_MIN_VERSION}" >&2
    exit 1
fi

lock_field() {
    local name=$1 field=$2
    awk -v name="${name}" -v field="${field}" \
        '$1 == name { print $field; exit }' "${LOCK}"
}

source_tree() {
    local name=$1 version archive url sha tmp
    local -a dirs
    version=$(lock_field "${name}" 2)
    sha=$(lock_field "${name}" 3)
    url=$(lock_field "${name}" 4)
    if [ -z "${version}" ] || [ -z "${sha}" ] || [ -z "${url}" ]; then
        echo "build-far2l-deps.sh: no lock entry for ${name}" >&2
        exit 1
    fi

    mkdir -p "${WORK}/archives" "${WORK}/sources"
    archive="${WORK}/archives/$(basename "${url%%\?*}")"
    if [ ! -f "${archive}" ]; then
        curl --fail --location --retry 3 --retry-delay 2 --silent --show-error \
            --output "${archive}" "${url}"
    fi
    printf '%s  %s\n' "${sha}" "${archive}" | sha256sum --check --status - || {
        echo "build-far2l-deps.sh: sha256 mismatch for ${name} ${version}" >&2
        exit 1
    }

    if [ -d "${WORK}/sources/${name}" ]; then
        printf '%s\n' "${WORK}/sources/${name}"
        return 0
    fi

    tmp=$(mktemp -d "${WORK}/sources/.${name}.XXXXXX")
    tar -xf "${archive}" -C "${tmp}"
    mapfile -t dirs < <(find "${tmp}" -mindepth 1 -maxdepth 1 -type d -print)
    if [ "${#dirs[@]}" -ne 1 ]; then
        echo "build-far2l-deps.sh: ${name} archive did not contain one source directory" >&2
        exit 1
    fi
    mv "${dirs[0]}" "${WORK}/sources/${name}"
    rm -rf "${tmp}"
    printf '%s\n' "${WORK}/sources/${name}"
}

mark() {
    : > "${PREFIX}/.${1}.built"
}

built() {
    [ -f "${PREFIX}/.${1}.built" ]
}

cmake_dep() {
    local marker=$1 prefix_name=$2 source=$3 build_name=$4
    shift 4
    if built "${marker}"; then
        return 0
    fi
    local build_dir="${WORK}/build/${build_name}"
    mkdir -p "${build_dir}" "${PREFIX}/${prefix_name}"
    cmake -S "${source}" -B "${build_dir}" \
        -DCMAKE_TOOLCHAIN_FILE="${CMAKE_TOOLCHAIN}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${PREFIX}/${prefix_name}" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_PREFIX_PATH="${PREFIX}/zlib;${PREFIX}/mbedtls;${PREFIX}/openssl;${PREFIX}/expat;${PREFIX}/freetype;${PREFIX}/harfbuzz;${PREFIX}/fontconfig" \
        "$@"
    cmake --build "${build_dir}" --parallel "${JOBS}"
    cmake --install "${build_dir}"
    mark "${marker}"
}

meson_dep() {
    local marker=$1 prefix_name=$2 source=$3 build_name=$4
    shift 4
    if built "${marker}"; then
        return 0
    fi
    local build_dir="${WORK}/build/${build_name}"
    mkdir -p "${build_dir}" "${PREFIX}/${prefix_name}"
    meson setup --wipe "${build_dir}" "${source}" \
        --native-file "${MESON_NATIVE}" \
        --prefix "${PREFIX}/${prefix_name}" \
        --libdir lib \
        --buildtype release \
        --prefer-static \
        --wrap-mode nodownload \
        -Ddefault_library=static \
        "$@"
    meson compile -C "${build_dir}" -j "${JOBS}"
    meson install -C "${build_dir}"
    mark "${marker}"
}

mkdir -p "${PREFIX}" "${WORK}"

if [ "${PROFILE}" = universal ]; then
    # SDL's CMake checks discover X11 by finding /usr/include and then pass
    # that whole directory as -I to every try_compile. That is valid for a
    # native compiler but lets a musl compiler read the host's glibc headers.
    # Stage only the declared graphics header trees and let the Zig wrappers
    # rewrite generic /usr/include flags to this directory. Keeping this
    # beside the cached work tree makes the host-header boundary reproducible
    # for the later far2l configure invocation as well.
    HOST_GRAPHICS_INCLUDE_DIR="${WORK}/host-graphics-include"
    mkdir -p "${HOST_GRAPHICS_INCLUDE_DIR}"
    for graphics_dir in X11 GL EGL GLES GLES2 GLES3 KHR xcb; do
        host_graphics_dir="/usr/include/${graphics_dir}"
        if [ -e "${host_graphics_dir}" ]; then
            if [ -e "${HOST_GRAPHICS_INCLUDE_DIR}/${graphics_dir}" ] ||
               [ -L "${HOST_GRAPHICS_INCLUDE_DIR}/${graphics_dir}" ]; then
                rm -f "${HOST_GRAPHICS_INCLUDE_DIR}/${graphics_dir}"
            fi
            ln -s "${host_graphics_dir}" "${HOST_GRAPHICS_INCLUDE_DIR}/${graphics_dir}"
        fi
    done
    for required_graphics_dir in X11 GL; do
        if [ ! -d "${HOST_GRAPHICS_INCLUDE_DIR}/${required_graphics_dir}" ]; then
            echo "build-far2l-deps.sh: required host graphics headers are missing: /usr/include/${required_graphics_dir}" >&2
            exit 1
        fi
    done
    export ONEBIN_HOST_INCLUDE_DIR="${HOST_GRAPHICS_INCLUDE_DIR}"
    printf 'host graphics include boundary: %s\n' "${ONEBIN_HOST_INCLUDE_DIR}"
    find "${HOST_GRAPHICS_INCLUDE_DIR}" -mindepth 1 -maxdepth 1 -type l \
        -printf '  %f -> %l\n' | sort
fi

export PKG_CONFIG_PATH="${PREFIX}/zlib/lib/pkgconfig:${PREFIX}/mbedtls/lib/pkgconfig:${PREFIX}/openssl/lib/pkgconfig:${PREFIX}/expat/lib/pkgconfig:${PREFIX}/freetype/lib/pkgconfig:${PREFIX}/harfbuzz/lib/pkgconfig:${PREFIX}/fontconfig/lib/pkgconfig:${PREFIX}/sdl2/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

zlib_src=$(source_tree zlib)
if ! built zlib; then
    cmake_dep zlib zlib "${zlib_src}" zlib \
        -DZLIB_BUILD_SHARED=OFF \
        -DZLIB_BUILD_TESTING=OFF
    mark zlib
fi
# zlib's CMake build emits shared objects despite BUILD_SHARED_LIBS=OFF.
# Leaving them beside libz.a makes a later -lz silently choose the .so. Do
# this on every run so restored prefixes are normalized before consumers use
# them, even when the zlib marker says the build itself can be skipped.
find "${PREFIX}/zlib/lib" -maxdepth 1 \
    \( -name 'libz.so' -o -name 'libz.so.*' \) -delete
mkdir -p "${PREFIX}/zlib/lib/pkgconfig"
# Keep pkg-config variables literal. The format is double-quoted, so each
# dollar sign is escaped for the shell; an extra backslash would become part
# of the .pc file and pkg-config would pass paths such as -I\/home/... to
# compilers.
printf "prefix=%s\nexec_prefix=\${prefix}\nlibdir=\${prefix}/lib\nincludedir=\${prefix}/include\n\nName: zlib\nDescription: zlib\nVersion: 1.3.2\nLibs: -L\${libdir} -lz\nCflags: -I\${includedir}\n" \
    "${PREFIX}/zlib" > "${PREFIX}/zlib/lib/pkgconfig/zlib.pc"
if [ ! -f "${PREFIX}/zlib/lib/pkgconfig/zlib.pc" ] || \
   grep -Fq "\\\${" "${PREFIX}/zlib/lib/pkgconfig/zlib.pc"; then
    echo 'build-far2l-deps.sh: zlib.pc contains escaped or missing pkg-config variables' >&2
    exit 1
fi

mbedtls_src=$(source_tree mbedtls)
if ! built mbedtls; then
    python3 "${mbedtls_src}/scripts/config.py" set MBEDTLS_THREADING_C
    python3 "${mbedtls_src}/scripts/config.py" set MBEDTLS_THREADING_PTHREAD
    cmake_dep mbedtls mbedtls "${mbedtls_src}" mbedtls \
        -DUSE_STATIC_MBEDTLS_LIBRARY=ON \
        -DUSE_SHARED_MBEDTLS_LIBRARY=OFF \
        -DENABLE_PROGRAMS=OFF \
        -DENABLE_TESTING=OFF
    mark mbedtls
fi

openssl_src=$(source_tree openssl)
if ! built openssl; then
    openssl_prefix="${PREFIX}/openssl"
    mkdir -p "${openssl_prefix}"
    (
        cd "${openssl_src}"
        CC="${CC}" CXX="${CXX}" AR="${AR}" RANLIB="${RANLIB}" \
        CFLAGS="-target ${TARGET} -ffile-prefix-map=${WORK}=." \
        LDFLAGS="-target ${TARGET} -static-libgcc -static-libstdc++" \
        ./Configure linux-x86_64 no-shared no-tests \
            --prefix="${openssl_prefix}" --openssldir="${openssl_prefix}/ssl"
    )
    make -C "${openssl_src}" -j "${JOBS}"
    make -C "${openssl_src}" install_sw install_ssldirs
    mark openssl
fi

expat_src=$(source_tree expat)
cmake_dep expat expat "${expat_src}" expat \
    -DEXPAT_BUILD_TESTS=OFF \
    -DEXPAT_BUILD_EXAMPLES=OFF \
    -DEXPAT_BUILD_TOOLS=OFF

freetype_src=$(source_tree freetype)
cmake_dep freetype-p1 freetype "${freetype_src}" freetype-p1 \
    -DFT_DISABLE_HARFBUZZ=ON \
    -DFT_DISABLE_PNG=ON \
    -DFT_DISABLE_BROTLI=ON \
    -DFT_DISABLE_BZIP2=ON \
    -DZLIB_LIBRARY="${PREFIX}/zlib/lib/libz.a" \
    -DZLIB_INCLUDE_DIR="${PREFIX}/zlib/include"

harfbuzz_src=$(source_tree harfbuzz)
meson_dep harfbuzz harfbuzz "${harfbuzz_src}" harfbuzz \
    -Dglib=disabled \
    -Dicu=disabled \
    -Dgraphite2=disabled \
    -Dcairo=disabled \
    -Dgobject=disabled \
    -Dintrospection=disabled \
    -Ddocs=disabled \
    -Dtests=disabled \
    -Dutilities=disabled \
    -Dbenchmark=disabled \
    -Dsubset=disabled \
    -Dfreetype=enabled

# FreeType's FindHarfBuzz.cmake expects the directory containing hb.h.
# HarfBuzz installs that header below include/harfbuzz; using its parent
# makes the module's hb-version.h fallback miss the version.
# This raw Meson flag is the equivalent of f4-qt's Conan option
# `harfbuzz/*:with_glib=False`; keep the two recipes semantically aligned.
if ! built freetype-p2; then
    cmake_dep freetype-p2 freetype "${freetype_src}" freetype-p2 \
        -DFT_DISABLE_HARFBUZZ=OFF \
        -DFT_DYNAMIC_HARFBUZZ=OFF \
        -DFT_REQUIRE_HARFBUZZ=ON \
        -DHarfBuzz_INCLUDE_DIR="${PREFIX}/harfbuzz/include/harfbuzz" \
        -DHarfBuzz_LIBRARY="${PREFIX}/harfbuzz/lib/libharfbuzz.a" \
        -DZLIB_LIBRARY="${PREFIX}/zlib/lib/libz.a" \
        -DZLIB_INCLUDE_DIR="${PREFIX}/zlib/include"
    mark freetype-p2
fi

fontconfig_src=$(source_tree fontconfig)
if ! built fontconfig; then
    fontconfig_build="${WORK}/build/fontconfig"
    mkdir -p "${fontconfig_build}" "${PREFIX}/fontconfig/lib/pkgconfig" "${PREFIX}/fontconfig/include"
    meson setup --wipe "${fontconfig_build}" "${fontconfig_src}" \
        --native-file "${MESON_NATIVE}" \
        --prefix "${PREFIX}/fontconfig" \
        --libdir lib \
        --buildtype release \
        --prefer-static \
        --wrap-mode nodownload \
        -Ddefault_library=static \
        -Ddoc=disabled \
        -Dtests=disabled \
        -Dtools=disabled \
        -Dxml-backend=expat \
        -Dcache-dir=/var/cache/fontconfig \
        -Dsysconfdir=/etc \
        -Ddatadir=/usr/share
    meson compile -C "${fontconfig_build}" -j "${JOBS}"
    fontconfig_lib=$(find "${fontconfig_build}" -type f -name libfontconfig.a -print -quit)
    fontconfig_pc=$(find "${fontconfig_build}" -type f -name fontconfig.pc -print -quit)
    if [ -z "${fontconfig_lib}" ] || [ -z "${fontconfig_pc}" ]; then
        echo 'build-far2l-deps.sh: Fontconfig outputs were not found' >&2
        exit 1
    fi
    cp "${fontconfig_lib}" "${PREFIX}/fontconfig/lib/libfontconfig.a"
    cp "${fontconfig_pc}" "${PREFIX}/fontconfig/lib/pkgconfig/fontconfig.pc"
    mkdir -p "${PREFIX}/fontconfig/include/fontconfig"
    find "${fontconfig_src}/fontconfig" -maxdepth 1 -type f -name '*.h' \
        -exec cp {} "${PREFIX}/fontconfig/include/fontconfig/" \;
    find "${fontconfig_build}" -type f -path '*/fontconfig/*.h' \
        -exec cp {} "${PREFIX}/fontconfig/include/fontconfig/" \;
    mark fontconfig
fi

sdl2_src=$(source_tree sdl2)
# The dependency toolchain prefers static archives globally. SDL's X11
# backend is intentionally a runtime-loaded host boundary, so its discovery
# must select the host shared objects and derive libX11.so.6 (rather than
# accidentally encoding libX11.a or disabling the driver).
cmake_dep sdl2 sdl2 "${sdl2_src}" sdl2 \
    -DSDL_STATIC=ON \
    -DSDL_SHARED=OFF \
    -DSDL_X11=ON \
    -DSDL_X11_SHARED=ON \
    -DSDL_OPENGL=ON \
    -DSDL_OPENGLES=ON \
    -DSDL_TEST=OFF \
    -DSDL_TESTS=OFF \
    -DONEBIN_HOST_GRAPHICS=ON \
    "-DONEBIN_FIND_LIBRARY_SUFFIXES=.so;.a" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON

sdl2_archive="${PREFIX}/sdl2/lib/libSDL2.a"
if [ ! -f "${sdl2_archive}" ]; then
    echo "build-far2l-deps.sh: SDL2 archive was not installed: ${sdl2_archive}" >&2
    exit 1
fi
if ! ar t "${sdl2_archive}" | grep -Eq '(^|/)SDL_x11video\.c\.o$'; then
    echo 'build-far2l-deps.sh: SDL2 archive has no X11 video backend object' >&2
    exit 1
fi
for soname in libX11.so.6 libXext.so.6; do
    if ! strings -a "${sdl2_archive}" | grep -Fq "${soname}"; then
        echo "build-far2l-deps.sh: SDL2 X11 backend has no ${soname} runtime soname" >&2
        exit 1
    fi
done

libssh_src=$(source_tree libssh)
cmake_dep libssh libssh "${libssh_src}" libssh \
    -DWITH_MBEDTLS=ON \
    -DWITH_GCRYPT=OFF \
    -DWITH_OPENSSL=OFF \
    -DWITH_GSSAPI=OFF \
    -DWITH_SERVER=OFF \
    -DWITH_PCAP=OFF \
    -DWITH_EXAMPLES=OFF \
    -DWITH_NACL=OFF \
    -DWITH_SFTP=ON \
    -DUNIT_TESTING=OFF \
    -DWITH_ZLIB=ON \
    -DZLIB_LIBRARY="${PREFIX}/zlib/lib/libz.a" \
    -DZLIB_INCLUDE_DIR="${PREFIX}/zlib/include" \
    -DMBEDTLS_INCLUDE_DIR="${PREFIX}/mbedtls/include" \
    -DMBEDTLS_LIBRARY="${PREFIX}/mbedtls/lib/libmbedtls.a" \
    -DMBEDX509_LIBRARY="${PREFIX}/mbedtls/lib/libmbedx509.a" \
    -DMBEDCRYPTO_LIBRARY="${PREFIX}/mbedtls/lib/libmbedcrypto.a"

libnfs_src=$(source_tree libnfs)
cmake_dep libnfs libnfs "${libnfs_src}" libnfs \
    -DENABLE_TESTS=OFF \
    -DENABLE_DOCUMENTATION=OFF \
    -DENABLE_UTILS=OFF \
    -DENABLE_EXAMPLES=OFF \
    -DENABLE_MULTITHREADING=OFF \
    -DCMAKE_DISABLE_FIND_PACKAGE_GSSAPI=TRUE \
    -DCMAKE_DISABLE_FIND_PACKAGE_GnuTLS=TRUE

neon_src=$(source_tree neon)
if ! built neon; then
    neon_prefix="${PREFIX}/neon"
    mkdir -p "${neon_prefix}"
    (
        cd "${neon_src}"
        CC="${CC}" AR="${AR}" RANLIB="${RANLIB}" \
        CPPFLAGS="-I${PREFIX}/openssl/include -I${PREFIX}/expat/include -I${PREFIX}/zlib/include" \
        LDFLAGS="-L${PREFIX}/openssl/lib -L${PREFIX}/expat/lib -L${PREFIX}/zlib/lib" \
        PKG_CONFIG_PATH="${PKG_CONFIG_PATH}" \
        ./configure --prefix="${neon_prefix}" --with-ssl=openssl \
            --with-expat --disable-shared --enable-static
    )
    make -C "${neon_src}" -j "${JOBS}"
    make -C "${neon_src}" install
    mark neon
fi

printf '%s\n' "far2l dependency prefix ready: ${PREFIX}"
