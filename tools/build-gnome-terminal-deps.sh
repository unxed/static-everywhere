#!/usr/bin/env bash
# Build the pinned Layer-1 dependency prefix consumed by
# build-gnome-terminal.sh. X11 client libraries and the GPU ABI are the only
# non-C-runtime host inputs; the GTK/UI code and D-Bus protocol implementation
# do not come from the host.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
LOCK="${REPO_ROOT}/contrib/gnome-terminal/deps.lock"
TOOLCHAIN="${REPO_ROOT}/onebin/toolchain"
PKG_CONFIG_WRAPPER="${REPO_ROOT}/tools/pkg-config-hybrid-host.sh"
PKG_CONFIG_COMMAND=(bash "${PKG_CONFIG_WRAPPER}")
PKG_CONFIG_ENV="bash $(printf '%q' "${PKG_CONFIG_WRAPPER}")"

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
MESON_CC="${WORK}/gnome-terminal-zig-cc"
MESON_CXX="${WORK}/gnome-terminal-zig-c++"
TARGET="x86_64-linux-gnu.${BASELINE}"

# Zig cannot provide all of the compiler introspection results that CMake
# normally derives by compiling probes. These values are part of this
# recipe's fixed x86_64 Linux target, and keep CMake from silently falling
# back to host architecture/include decisions. CMAKE_SKIP_RPATH is the
# corresponding portability rule: dependency build directories must never
# be recorded in an installed artefact.
CMAKE_COMMON_ARGS=(
    '-DCMAKE_SIZEOF_VOID_P=8'
    '-DCMAKE_LIBRARY_ARCHITECTURE=x86_64-linux-gnu'
    '-DCMAKE_C_IMPLICIT_INCLUDE_DIRECTORIES=/usr/include'
    '-DCMAKE_CXX_IMPLICIT_INCLUDE_DIRECTORIES=/usr/include'
    '-DCMAKE_SKIP_RPATH=ON'
)

dependency_order=(
    util-linux zlib libffi pcre2 expat libpng pixman glib fribidi freetype harfbuzz
    fontconfig cairo pango gdk-pixbuf atk epoxy gtk lz4 vte libhandy
)

subproject_pins=( gvdb )

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
host contract: X11 client libraries plus the Profile H OpenGL/EGL runtime ABI
host library policy: pkg-config maps only X11/OpenGL -l arguments to shared objects
fontconfig install: manual copy (no meson install; protects host /etc/fonts)
cairo XRender function checks: HAVE_XRENDERCREATESOLIDFILL HAVE_XRENDERCREATELINEARGRADIENT HAVE_XRENDERCREATERADIALGRADIENT HAVE_XRENDERCREATECONICALGRADIENT
cmake contract: ${CMAKE_COMMON_ARGS[*]}
source patches: util-linux-libuuid-only.patch gdk-pixbuf-static-loader-deps.patch gtk-no-host-atk-bridge.patch vte-static-library.patch libhandy-static-library.patch
dependency patch contract: every patch is a valid Git diff captured from its pinned checkout
VTE linker feature contract: _b_symbolic_functions=false for Zig 0.13 (unsupported -Bsymbolic-functions)
subproject policy: materialize pinned gvdb; provide libc gettext through a prefix-local synthetic intl.pc; no Meson downloads
uuid policy: util-linux libuuid-only=true; install only the pinned static libuuid archive and uuid.pc
uuid-only graph audit: reject util-linux libcommon and non-UUID lib/ sources before compile
static loader closure: builtin loader dependencies are exported through gdkpixbuf_dep
source_tree contract: cleanup diagnostics never contaminate the returned source path
Meson option contract: every recipe -D option is declared by the pinned project or Meson core
cache identity: dependency commit plus recipe, patch and toolchain fingerprint
build-time tools: ${PREFIX}/bin precedes the host PATH; producer tools are verified before consumers
libc-free target guard: Meson compiler wrappers disable stack protection only for explicit -nostdlib/-nodefaultlibs targets
PLAN
    for dependency in "${dependency_order[@]}"; do
        printf '# pinned source: %s %s %s\n' \
            "${dependency}" "$(lock_field "${dependency}" 2)" "$(lock_field "${dependency}" 3)"
    done
    for dependency in "${subproject_pins[@]}"; do
        printf '# pinned subproject: %s %s %s\n' \
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
command -v sha256sum >/dev/null 2>&1 || {
    printf 'build-gnome-terminal-deps.sh: required tool not found: sha256sum\n' >&2
    exit 1
}
[ -f "${PKG_CONFIG_WRAPPER}" ] || {
    printf 'build-gnome-terminal-deps.sh: host pkg-config wrapper is missing: %s\n' \
        "${PKG_CONFIG_WRAPPER}" >&2
    exit 1
}
command -v zig >/dev/null 2>&1 || {
    printf 'build-gnome-terminal-deps.sh: zig is not on PATH\n' >&2
    exit 1
}

mkdir -p "${PREFIX}" "${WORK}/sources" "${WORK}/build" "${PREFIX}/lib/pkgconfig"

RECIPE_FINGERPRINT=$(
    sha256sum \
        "${REPO_ROOT}/tools/build-gnome-terminal-deps.sh" \
        "${REPO_ROOT}/contrib/gnome-terminal/deps.lock" \
        "${REPO_ROOT}/contrib/gnome-terminal/patches/"*.patch \
        "${REPO_ROOT}/onebin/toolchain/onebin-linux-hybrid.cmake" \
        "${REPO_ROOT}/onebin/toolchain/onebin-linux-static.cmake" \
        "${REPO_ROOT}/onebin/toolchain/zig-cc" \
        "${REPO_ROOT}/onebin/toolchain/zig-c++" \
        | sha256sum | awk '{print $1}'
)

# Zig 0.13 rejects stack-protector code generation when a target explicitly
# requests a libc-free compilation with -nostdlib or -nodefaultlibs. Pinned
# Meson projects can add either flag to one target while the shared Profile H
# native file supplies -fstack-protector-strong to every target. Keep the
# source project's libc-free request intact, but append the matching compiler
# override only for that target. This wrapper is deliberately generic for the
# whole GNOME Meson dependency graph; it is not a VTE-specific patch and will
# cover the same class of target in a future pinned dependency as well.
write_libc_free_compiler_wrapper() {
    local wrapper=$1 compiler=$2
    cat >"${wrapper}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

needs_libc=0
for arg in "\$@"; do
    case "\$arg" in
        -nostdlib|-nostdlib++|-nodefaultlibs)
            needs_libc=1
            ;;
    esac
done

if [ "\$needs_libc" -eq 1 ]; then
    exec "${compiler}" "\$@" -fno-stack-protector
fi
exec "${compiler}" "\$@"
EOF
    chmod +x "${wrapper}"
}

write_libc_free_compiler_wrapper "${MESON_CC}" "${CC}"
write_libc_free_compiler_wrapper "${MESON_CXX}" "${CXX}"

# -Wno-cast-function-type-strict: a clang-only warning that upstream
# never sees.
#
# vte enables its warning set through cc.get_supported_arguments(). gcc
# has no -Wcast-function-type-strict, so upstream builds silently drop
# it; clang has it, so every GLib G_DEFINE_AUTOPTR_CLEANUP_FUNC expansion
# in gtk-autocleanups.h warns -- around 2800 per translation unit, from
# third-party headers, about code we do not own and cannot change.
#
# Both spellings are needed. Silencing only the -strict one left the
# artifact at 180 MB, because clang's plain -Wcast-function-type -- which
# vte lists explicitly -- fires on the same GLib macro. Measured on the
# same expansion: two warnings from each flag independently.
#
# The cost is not cosmetic. One run produced a 180 MB diagnostics
# artifact too large to download, in which the actual build error was
# buried under millions of identical warning lines. A diagnostic channel
# that cannot be read is not a diagnostic channel.
#
# Set in the native file's built-in options, which meson places after the
# project's own arguments, so the -Wno- wins. Verified with a meson
# project that enables the warning via add_project_arguments.
cat >"${MESON_NATIVE}" <<EOF
[binaries]
c = '${MESON_CC}'
cpp = '${MESON_CXX}'
ar = '${AR}'
ranlib = '${RANLIB}'
strip = 'strip'

[built-in options]
c_args = ['-target', '${TARGET}', '-fPIE', '-ffunction-sections', '-fdata-sections', '-fstack-protector-strong', '-ffile-prefix-map=${WORK}=.', '-Wno-cast-function-type-strict', '-Wno-cast-function-type']
cpp_args = ['-target', '${TARGET}', '-fPIE', '-ffunction-sections', '-fdata-sections', '-fstack-protector-strong', '-ffile-prefix-map=${WORK}=.', '-Wno-cast-function-type-strict', '-Wno-cast-function-type']
c_link_args = ['-target', '${TARGET}', '-static-libgcc', '-Wl,--gc-sections', '-Wl,-z,relro', '-Wl,-z,now', '-Wl,-z,noexecstack', '-Wl,-z,nodelete', '-pie', '-s', '-L${PREFIX}/lib', '-L/usr/lib/x86_64-linux-gnu', '-L/usr/lib', '-L/lib/x86_64-linux-gnu']
cpp_link_args = ['-target', '${TARGET}', '-static-libgcc', '-static-libstdc++', '-Wl,--gc-sections', '-Wl,-z,relro', '-Wl,-z,now', '-Wl,-z,noexecstack', '-Wl,-z,nodelete', '-pie', '-s', '-L${PREFIX}/lib', '-L/usr/lib/x86_64-linux-gnu', '-L/usr/lib', '-L/lib/x86_64-linux-gnu']
default_library = 'static'
b_pie = true
EOF

# Dependency build tools produced by the static prefix must win over host
# tools. In particular, gdk-pixbuf's pinned Meson file calls
# find_program('glib-compile-resources') after GLib has installed that tool.
export PATH="${PREFIX}/bin:${TOOLCHAIN}:${PATH}"
export PKG_CONFIG="${PKG_CONFIG_ENV}"
export PKG_CONFIG_ALLOW_SYSTEM_LIBS=1
export PKG_CONFIG_ALLOW_SYSTEM_CFLAGS=1
export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PREFIX}/share/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/share/pkgconfig:${PKG_CONFIG_PATH:-}"
export CMAKE_PREFIX_PATH="${PREFIX}"

require_prefix_program() {
    local program=$1 resolved
    resolved=$(command -v "${program}" || true)
    case "${resolved}" in
        "${PREFIX}/bin/"*) ;;
        *)
            printf 'build-gnome-terminal-deps.sh: build-time tool is not provided by the static prefix: %s (%s)\n' \
                "${program}" "${resolved:-not found}" >&2
            exit 1
            ;;
    esac
}

# Meson accepts project options from meson_options.txt and a separate set of
# core options. Passing an option borrowed from another project is an easy
# way to stop the dependency graph before compilation (for example, ATK has
# no tests option). Validate the complete recipe at the pinned source tree
# so this class of mistake is reported with the owning project and option.
meson_core_option() {
    case "$1" in
        auto_features|backend|bindir|buildtype|cmake_prefix_path|c_args|cpp_args|c_link_args|cpp_link_args|\
        c_std|datadir|debug|default_library|errorlogs|force_fallback_for|includedir|infodir|install_umask|\
        layout|libdir|libexecdir|localedir|localstatedir|mandir|objc_args|objc_link_args|objcpp_args|\
        objcpp_link_args|objc_std|objcpp_std|optimization|pkg_config_path|prefix|python.bytecompile|\
        python.platlibdir|python.purelibdir|sbindir|sharedstatedir|strip|sysconfdir|unity|unity_size|\
        warning_level|werror|wrap_mode|b_asneeded|b_bitcode|b_b_lto|b_colorout|b_coverage|b_lto|\
        b_lto_mode|b_ndebug|b_pch|b_pie|b_sanitize|b_staticpic|b_vscrt)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

meson_source_option() {
    local source=$1 option=$2 options_file="${source}/meson_options.txt"
    [ -f "${options_file}" ] || return 1
    sed -nE \
        -e "s/^[[:space:]]*option[[:space:]]*\\([[:space:]]*['\"]?([[:alnum:]_.-]+).*/\\1/p" \
        -e "s/^[[:space:]]*['\"]([[:alnum:]_.-]+)['\"].*/\\1/p" \
        "${options_file}" | grep -Fxq -- "${option}"
}

validate_meson_options() {
    local source=$1 arg option
    shift
    for arg in "$@"; do
        case "${arg}" in
            -D?*=*)
                option=${arg#-D}
                option=${option%%=*}
                if meson_core_option "${option}" || meson_source_option "${source}" "${option}"; then
                    continue
                fi
                printf 'build-gnome-terminal-deps.sh: Meson option is not declared by %s or Meson core: -D%s\n' \
                    "${source}" "${option}" >&2
                exit 1
                ;;
        esac
    done
}

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
    # The workflow caches source trees between runs. A failed patch can leave
    # one of those trees partially modified, so restore the pinned checkout
    # before any dependency-specific patch is applied.
    run git -C "${dir}" reset --quiet --hard "${commit}" >&2
    run git -C "${dir}" clean -fdx >&2
    printf '%s\n' "${dir}"
}

apply_source_patch() {
    local source=$1 patch=$2
    if ! git -C "${source}" apply --numstat "${patch}" >/dev/null 2>&1; then
        printf 'build-gnome-terminal-deps.sh: malformed captured dependency patch: %s\n' \
            "${patch}" >&2
        return 1
    fi
    if git -C "${source}" apply --reverse --check "${patch}" >/dev/null 2>&1; then
        return 0
    fi
    run git -C "${source}" apply --whitespace=nowarn "${patch}"
}

materialize_subproject() {
    local source=$1 destination=$2
    run rm -rf "${destination}"
    run mkdir -p "${destination}"
    run cp -a "${source}/." "${destination}/"
}

mark() {
    local name=$1 commit
    commit=$(lock_field "${name}" 3)
    printf '%s %s\n' "${commit}" "${RECIPE_FINGERPRINT}" >"${PREFIX}/.built-${name}"
}

built() {
    local name=$1 commit
    commit=$(lock_field "${name}" 3)
    [ -f "${PREFIX}/.built-${name}" ] \
        && grep -Fxq "${commit} ${RECIPE_FINGERPRINT}" "${PREFIX}/.built-${name}"
}

require_pc() {
    local pc prefix
    for pc in "$@"; do
        prefix=$("${PKG_CONFIG_COMMAND[@]}" --variable=prefix "${pc}" 2>/dev/null || true)
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
        "${CMAKE_COMMON_ARGS[@]}" \
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
    local native_file="${MESON_NATIVE_FILE:-${MESON_NATIVE}}"
    local -a setup_cmd=(
        meson setup --wipe "${build_dir}" "${source}"
        --native-file "${native_file}"
        --prefix "${PREFIX}" --libdir lib --buildtype release
        --prefer-static --wrap-mode nodownload -Ddefault_library=static
    )
    setup_cmd+=("$@")
    validate_meson_options "${source}" "${setup_cmd[@]}"
    run "${setup_cmd[@]}"
    if [ "${name}" = "util-linux" ]; then
        assert_util_linux_uuid_only_graph "${build_dir}"
    fi
    run meson compile -C "${build_dir}" -j "${JOBS}"
    run meson install -C "${build_dir}"
    mark "${name}"
}

assert_util_linux_uuid_only_graph() {
    local build_dir=$1 graph="${build_dir}/build.ninja" unexpected
    [ -f "${graph}" ] || {
        printf 'build-gnome-terminal-deps.sh: util-linux build graph is missing: %s\n' \
            "${graph}" >&2
        exit 1
    }
    if grep -Fq -- 'lib/libcommon.a' "${graph}"; then
        printf 'build-gnome-terminal-deps.sh: libuuid-only graph contains libcommon\n' >&2
        exit 1
    fi
    unexpected=$(grep -oE 'sources/util-linux/lib/[[:alnum:]_.-]+\.c' "${graph}" \
        | sort -u \
        | grep -Ev 'sources/util-linux/lib/(md5|randutils|sha1)\.c$' || true)
    if [ -n "${unexpected}" ]; then
        printf 'build-gnome-terminal-deps.sh: libuuid-only graph contains non-UUID util-linux/lib sources:\n%s\n' \
            "${unexpected}" >&2
        exit 1
    fi
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

util_linux_src=$(source_tree util-linux)
apply_source_patch "${util_linux_src}" "${REPO_ROOT}/contrib/gnome-terminal/patches/util-linux-libuuid-only.patch"
meson_dep util-linux "${util_linux_src}" util-linux \
    -Dlibuuid-only=true -Dbuild-libuuid=enabled -Dbuild-bash-completion=disabled
require_pc uuid

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
gvdb_src=$(source_tree gvdb)
# GLib imports gvdb unconditionally and, when the runner has no intl.pc, its
# nodownload build otherwise tries proxy-libintl. glibc provides the gettext
# ABI used here, so expose it as a prefix-local dependency with no extra -l.
materialize_subproject "${gvdb_src}" "${glib_src}/subprojects/gvdb"
write_simple_pc intl "$(lock_field glib 2)" ""
require_pc zlib libffi libpcre2-8 intl
meson_dep glib "${glib_src}" glib \
    -Dtests=false -Dinstalled_tests=false -Dman=false -Dman-pages=disabled \
    -Ddocumentation=false -Dintrospection=disabled -Dselinux=disabled \
    -Dlibmount=disabled -Dlibelf=disabled -Dsysprof=disabled -Dsystemtap=false \
    -Dglib_debug=disabled -Dnls=disabled
for program in glib-compile-resources glib-compile-schemas gdbus-codegen; do
    require_prefix_program "${program}"
done

fribidi_src=$(source_tree fribidi)
meson_dep fribidi "${fribidi_src}" fribidi \
    -Ddocs=false -Dtests=false -Dbin=false

freetype_src=$(source_tree freetype)
cmake_dep freetype "${freetype_src}" freetype \
    -DFT_DISABLE_ZLIB=OFF -DFT_REQUIRE_ZLIB=ON \
    -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_PNG=ON \
    -DFT_DISABLE_BROTLI=ON -DFT_DISABLE_BZIP2=ON \
    -DZLIB_LIBRARY="${PREFIX}/lib/libz.a" -DZLIB_INCLUDE_DIR="${PREFIX}/include"

harfbuzz_src=$(source_tree harfbuzz)
require_pc freetype2
meson_dep harfbuzz "${harfbuzz_src}" harfbuzz \
    -Dglib=disabled -Dicu=disabled -Dgraphite2=disabled -Dcairo=disabled \
    -Dgobject=disabled -Dintrospection=disabled -Ddocs=disabled \
    -Dtests=disabled -Dutilities=disabled -Dbenchmark=disabled \
    -Dfreetype=enabled

if ! grep -Fxq "$(lock_field freetype 3) ${RECIPE_FINGERPRINT}" \
    "${PREFIX}/.built-freetype-harfbuzz" 2>/dev/null; then
    freetype_build="${WORK}/build/freetype-harfbuzz"
    # FindHarfBuzz.cmake expects the directory containing hb.h; HarfBuzz
    # installs it below include/harfbuzz, not directly below include.
    run cmake -S "${freetype_src}" -B "${freetype_build}" \
        -G Ninja -DCMAKE_TOOLCHAIN_FILE="${CMAKE_TOOLCHAIN}" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
        -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DBUILD_SHARED_LIBS=OFF -DFT_DISABLE_ZLIB=OFF \
        -DFT_REQUIRE_ZLIB=ON -DFT_DISABLE_PNG=ON \
        -DFT_DISABLE_BROTLI=ON -DFT_DISABLE_BZIP2=ON \
        -DFT_DISABLE_HARFBUZZ=OFF \
        -DFT_DYNAMIC_HARFBUZZ=OFF -DFT_REQUIRE_HARFBUZZ=ON \
        "${CMAKE_COMMON_ARGS[@]}" \
        -DHarfBuzz_INCLUDE_DIR="${PREFIX}/include/harfbuzz" \
        -DHarfBuzz_LIBRARY="${PREFIX}/lib/libharfbuzz.a" \
        -DZLIB_LIBRARY="${PREFIX}/lib/libz.a" \
        -DZLIB_INCLUDE_DIR="${PREFIX}/include"
    run cmake --build "${freetype_build}" --parallel "${JOBS}"
    run cmake --install "${freetype_build}"
    printf '%s %s\n' "$(lock_field freetype 3)" "${RECIPE_FINGERPRINT}" \
        >"${PREFIX}/.built-freetype-harfbuzz"
fi

fontconfig_src=$(source_tree fontconfig)
require_pc freetype2 expat
if ! built fontconfig; then
    fontconfig_build="${WORK}/build/fontconfig"
    # Fontconfig's conf.d/link_confs.py install hook ignores DESTDIR and can
    # modify the runner's real /etc/fonts. Build it, then copy only the
    # library, pkg-config file and headers needed by the static prefix.
    run mkdir -p "${fontconfig_build}" "${PREFIX}/lib/pkgconfig" "${PREFIX}/include"
    validate_meson_options "${fontconfig_src}" \
        -Ddefault_library=static -Ddoc=disabled -Dtests=disabled -Dtools=disabled \
        -Dcache-build=disabled -Diconv=disabled -Dnls=disabled -Dsysconfdir=/etc \
        -Ddatadir=/usr/share -Dcache-dir=/var/cache/fontconfig
    run meson setup --wipe "${fontconfig_build}" "${fontconfig_src}" \
        --native-file "${MESON_NATIVE}" \
        --prefix "${PREFIX}" --libdir lib --buildtype release \
        --prefer-static --wrap-mode nodownload -Ddefault_library=static \
        -Ddoc=disabled -Dtests=disabled -Dtools=disabled -Dcache-build=disabled \
        -Diconv=disabled -Dnls=disabled -Dsysconfdir=/etc -Ddatadir=/usr/share \
        -Dcache-dir=/var/cache/fontconfig
    run meson compile -C "${fontconfig_build}" -j "${JOBS}"

    fontconfig_lib=$(find "${fontconfig_build}" -type f -name libfontconfig.a -print -quit)
    fontconfig_pc=$(find "${fontconfig_build}" -type f -name fontconfig.pc -print -quit)
    if [ -z "${fontconfig_lib}" ] || [ -z "${fontconfig_pc}" ]; then
        printf 'build-gnome-terminal-deps.sh: Fontconfig outputs were not found\n' >&2
        exit 1
    fi
    run install -D "${fontconfig_lib}" "${PREFIX}/lib/libfontconfig.a"
    run install -D "${fontconfig_pc}" "${PREFIX}/lib/pkgconfig/fontconfig.pc"
    run mkdir -p "${PREFIX}/include/fontconfig"
    while IFS= read -r header; do
        run install -m 644 "${header}" "${PREFIX}/include/fontconfig/"
    done < <(find "${fontconfig_src}/fontconfig" -maxdepth 1 -type f -name '*.h' -print)
    while IFS= read -r header; do
        run install -m 644 "${header}" "${PREFIX}/include/fontconfig/"
    done < <(find "${fontconfig_build}" -type f -path '*/fontconfig/*.h' -print)
    mark fontconfig
fi

cairo_src=$(source_tree cairo)
require_pc glib-2.0 fontconfig freetype2 libpng pixman-1 zlib
# Cairo 1.18.0's Meson port calls cc.has_function() for these XRender
# entrypoints without a Xrender.h prefix.  The recipe deliberately treats the
# runner's XRender headers/library as the host X11 boundary, so the checks
# fail under -Werror-implicit-function-declaration even though all four
# symbols and their types are present.  Keep the real XRender backend and
# prevent Cairo from declaring fallback types that collide with Xrender.h.
# Use a Cairo-only compiler wrapper.  This keeps the target flags from the
# shared native file and adds four separate defines to every Cairo compiler
# invocation; Meson's command-line array handling is not reliable for this
# set of preprocessor definitions.
CAIRO_NATIVE="${WORK}/cairo-onebin-linux-hybrid-meson.ini"
CAIRO_CC="${WORK}/cairo-zig-cc"
cat >"${CAIRO_CC}" <<EOF
#!/usr/bin/env bash
exec "${CC}" \
    -DHAVE_XRENDERCREATESOLIDFILL \
    -DHAVE_XRENDERCREATELINEARGRADIENT \
    -DHAVE_XRENDERCREATERADIALGRADIENT \
    -DHAVE_XRENDERCREATECONICALGRADIENT \
    "\$@"
EOF
run chmod +x "${CAIRO_CC}"
run sed "s|^c = .*|c = '${CAIRO_CC}'|" "${MESON_NATIVE}" >"${CAIRO_NATIVE}"
MESON_NATIVE_FILE="${CAIRO_NATIVE}"
meson_dep cairo "${cairo_src}" cairo \
    -Dfontconfig=enabled -Dfreetype=enabled -Dpng=enabled -Dzlib=enabled \
    -Dxlib=enabled -Dxcb=disabled -Dxlib-xcb=disabled -Dglib=enabled \
    -Dtee=disabled -Dspectre=disabled -Dsymbol-lookup=disabled \
    -Dtests=disabled -Dgtk2-utils=disabled
unset MESON_NATIVE_FILE

pango_src=$(source_tree pango)
require_pc glib-2.0 fribidi harfbuzz cairo fontconfig freetype2
meson_dep pango "${pango_src}" pango \
    -Dfontconfig=enabled -Dcairo=enabled -Dfreetype=enabled \
    -Dxft=disabled -Dlibthai=disabled -Dintrospection=disabled \
    -Dgtk_doc=false -Dsysprof=disabled -Dinstall-tests=false

gdk_pixbuf_src=$(source_tree gdk-pixbuf)
apply_source_patch "${gdk_pixbuf_src}" "${REPO_ROOT}/contrib/gnome-terminal/patches/gdk-pixbuf-static-loader-deps.patch"
require_pc glib-2.0 gobject-2.0 gio-2.0 libpng
meson_dep gdk-pixbuf "${gdk_pixbuf_src}" gdk-pixbuf \
    -Dpng=enabled -Djpeg=disabled -Dtiff=disabled \
    -Dbuiltin_loaders=png,bmp,gif,ico,ani,pnm,xpm,xbm,tga,icns,qtif \
    -Dintrospection=disabled -Dman=false -Dtests=false \
    -Dinstalled_tests=false -Dgio_sniffing=false -Dgtk_doc=false -Ddocs=false

atk_src=$(source_tree atk)
require_pc glib-2.0 gobject-2.0
meson_dep atk "${atk_src}" atk \
    -Dintrospection=false -Ddocs=false

epoxy_src=$(source_tree epoxy)
meson_dep epoxy "${epoxy_src}" epoxy \
    -Dglx=yes -Degl=yes -Dx11=true -Dtests=false -Ddocs=false

gtk_src=$(source_tree gtk)
apply_source_patch "${gtk_src}" "${REPO_ROOT}/contrib/gnome-terminal/patches/gtk-no-host-atk-bridge.patch"
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
apply_source_patch "${vte_src}" "${REPO_ROOT}/contrib/gnome-terminal/patches/vte-static-library.patch"
# VTE deliberately exposes this switch for linkers without -Bsymbolic-functions.
# Keep the decision in the pinned project's declared option instead of
# patching out its capability check; this prevents the same class of failure
# for this toolchain whenever VTE probes the linker during configure.
meson_dep vte "${vte_src}" vte \
    -Dgtk3=true -Dgtk4=false -Dfribidi=true -Dgnutls=false -Dicu=false \
    -D_systemd=false -Dgir=false -Dvapi=false -Dglade=false -Ddocs=false \
    -D_b_symbolic_functions=false

libhandy_src=$(source_tree libhandy)
require_pc gtk+-3.0 glib-2.0
apply_source_patch "${libhandy_src}" "${REPO_ROOT}/contrib/gnome-terminal/patches/libhandy-static-library.patch"
meson_dep libhandy "${libhandy_src}" libhandy \
    -Dintrospection=disabled -Dvapi=false -Dgtk_doc=false \
    -Dtests=false -Dexamples=false -Dglade_catalog=disabled

for library in \
    libuuid.a libz.a libffi.a libpcre2-8.a libexpat.a libpng16.a libpixman-1.a \
    libglib-2.0.a libfribidi.a libfreetype.a libharfbuzz.a libfontconfig.a \
    libcairo.a libpango-1.0.a libpangocairo-1.0.a libgdk_pixbuf-2.0.a \
    libatk-1.0.a libepoxy.a libgtk-3.a liblz4.a libvte-2.91.a libhandy-1.a; do
    [ -f "${PREFIX}/lib/${library}" ] || {
        printf 'build-gnome-terminal-deps.sh: expected static archive missing: %s\n' "${PREFIX}/lib/${library}" >&2
        exit 1
    }
done

printf 'GNOME Terminal static dependency prefix ready: %s\n' "${PREFIX}"
