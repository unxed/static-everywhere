# onebin-linux-static.cmake — Profile S: musl, fully static, -static-pie.
# DESIGN-onebin.md §8. Use with:
#   cmake -DCMAKE_TOOLCHAIN_FILE=.../onebin-linux-static.cmake ...
#
# Requires `zig` on PATH (https://ziglang.org/download/) and the four
# zig-* wrapper scripts next to this file — CMAKE_C_COMPILER must be a
# single executable, and "zig cc" is two words.
cmake_minimum_required(VERSION 3.16)

set(CMAKE_SYSTEM_NAME Linux)
set(ONEBIN_PROFILE "static")

# The zig -target triple. musl, not glibc: 01-SPEC-audit.md's whole Profile
# S argument is "zero host dependencies", and musl is what actually gets
# you there cleanly — see STATIC-EVERYWHERE.md's musl-vs-glibc discussion.
set(ONEBIN_ZIG_TARGET "x86_64-linux-musl" CACHE STRING
    "zig -target triple for Profile S (e.g. x86_64-linux-musl, aarch64-linux-musl)")

get_filename_component(_onebin_toolchain_dir "${CMAKE_CURRENT_LIST_FILE}" DIRECTORY)

set(CMAKE_C_COMPILER   "${_onebin_toolchain_dir}/zig-cc"  CACHE FILEPATH "" FORCE)
set(CMAKE_CXX_COMPILER "${_onebin_toolchain_dir}/zig-c++" CACHE FILEPATH "" FORCE)
# CMAKE_AR/CMAKE_RANLIB must be absolute paths set before project() — this
# file, evaluated during the first project() call, is exactly that point.
set(CMAKE_AR      "${_onebin_toolchain_dir}/zig-ar"      CACHE FILEPATH "" FORCE)
set(CMAKE_RANLIB   "${_onebin_toolchain_dir}/zig-ranlib" CACHE FILEPATH "" FORCE)

# Prefer .a over .so when CMake resolves find_library()/find_package() —
# nothing should get linked in dynamically by accident.
set(CMAKE_FIND_LIBRARY_SUFFIXES ".a")
set(BUILD_SHARED_LIBS OFF)

# DESIGN-onebin.md §8 / 04-REFERENCE-far2l.md §7.1: --exclude-libs,ALL is a
# default, not a rule. An application that exports an ABI to its own
# dlopen'd plugins needs those symbols in .dynsym; turn this ON and, if the
# project has one, prefer a real version script over a blanket
# --export-dynamic (export what was promised, not everything that survived
# --gc-sections).
option(ONEBIN_EXPORT_DYNAMIC "This target exports an ABI to its own plugins" OFF)

# -D__MUSL__ when the target is musl.
#
# musl deliberately defines no macro identifying itself, which leaves
# portable code with no way to ask "is this musl?" in the preprocessor.
# Downstream projects settled on __MUSL__ as the de-facto name and test
# for it; nothing defines it, so those tests silently take the glibc
# branch on a musl build.
#
# far2l is exactly that case. utils/include/debug.h guards its
# <execinfo.h> include with a list that includes !defined(__MUSL__) --
# the intent is unmistakable, since musl has no backtrace() at all -- and
# the guard never fires. Supplying the macro makes the guard mean what it
# says. This is not a patch to far2l (contrib/far2l/patches/README.md:
# that source is built as-is); it supplies an input the source already
# tests for, and the finding is written up in contrib/far2l/UPSTREAM.md.
set(_onebin_libc_identity "")
if(ONEBIN_ZIG_TARGET MATCHES "musl")
    set(_onebin_libc_identity "-D__MUSL__")
endif()

set(_onebin_flags
    "-target ${ONEBIN_ZIG_TARGET}"
    "${_onebin_libc_identity}"
    "-fstack-protector-strong"
    # So our own reference builds don't trip our own OB0060 (embedded
    # build-time path) — DESIGN-onebin.md §8's own explicit reminder.
    "-ffile-prefix-map=${CMAKE_SOURCE_DIR}=."
    "-ffile-prefix-map=${CMAKE_BINARY_DIR}=."
)
string(JOIN " " _onebin_flags_str ${_onebin_flags})
set(CMAKE_C_FLAGS_INIT   "${_onebin_flags_str}")
set(CMAKE_CXX_FLAGS_INIT "${_onebin_flags_str}")

set(_onebin_link_flags
    # zig 0.13.0 silently ignores a bare "-static-pie" for
    # -target *-linux-musl ("argument unused during compilation") and
    # produces a plain static, non-PIE binary instead — empirically
    # verified, not documented anywhere obvious. -fPIE -pie -static is the
    # combination that actually produces a "static-pie linked" ELF.
    "-fPIE" "-pie" "-static"
    # zig cc identifies itself as Clang; build systems that add
    # --gc-sections "unless the compiler is Clang" (far2l among them,
    # 04-REFERENCE-far2l.md) silently skip it. Set it here instead of
    # trusting the project to.
    "-Wl,--gc-sections"
    "-Wl,-z,relro" "-Wl,-z,now" "-Wl,-z,noexecstack"
)
if(ONEBIN_EXPORT_DYNAMIC)
    list(APPEND _onebin_link_flags "-Wl,--export-dynamic")
else()
    # --exclude-libs,ALL is DESIGN-onebin.md §8's documented default for
    # this case — but zig 0.13.0's linker driver rejects it outright
    # ("error: unsupported linker arg: --exclude-libs"), with or without
    # -fuse-ld=lld, on every target tried. Not passing a flag the linker
    # cannot accept is not the same decision as deciding the flag is
    # unwanted; if a future zig release supports it, add it back here.
    message(STATUS
        "onebin: -Wl,--exclude-libs,ALL requested by default but omitted — "
        "zig's linker does not currently support it (verified against zig 0.13.0).")
endif()
string(JOIN " " _onebin_link_flags_str ${_onebin_link_flags})
set(CMAKE_EXE_LINKER_FLAGS_INIT    "${_onebin_link_flags_str}")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "${_onebin_link_flags_str}")

# WHOLE_ARCHIVE without --push-state.
#
# CMake's default expansion of $<LINK_LIBRARY:WHOLE_ARCHIVE,...> for a
# GNU-like linker is
#
#   --push-state --whole-archive <item> --pop-state
#
# and zig 0.13 rejects --push-state outright: "unsupported linker arg".
# It accepts --whole-archive and --no-whole-archive, which is what the
# push/pop pair exists to bracket, so define the feature in those terms.
#
# The pair is exact rather than convenient: --no-whole-archive restores
# the default, which is the state every link here starts in, so nothing
# that follows the item is swept in.
foreach(_onebin_lang C CXX)
    set(CMAKE_${_onebin_lang}_LINK_LIBRARY_USING_WHOLE_ARCHIVE_SUPPORTED TRUE)
    set(CMAKE_${_onebin_lang}_LINK_LIBRARY_USING_WHOLE_ARCHIVE
        "LINKER:--whole-archive"
        "<LINK_ITEM>"
        "LINKER:--no-whole-archive")
endforeach()
unset(_onebin_lang)
