# onebin-linux-hybrid.cmake — Profile H: dynamic against a pinned glibc
# baseline, static C/C++ runtime. DESIGN-onebin.md §8. Use with:
#   cmake -DCMAKE_TOOLCHAIN_FILE=.../onebin-linux-hybrid.cmake ...
#
# Requires `zig` on PATH and the four zig-* wrapper scripts next to this
# file — see onebin-linux-static.cmake's header for why they exist.
cmake_minimum_required(VERSION 3.16)

set(CMAKE_SYSTEM_NAME Linux)
set(ONEBIN_PROFILE "hybrid")

set(ONEBIN_GLIBC_BASELINE "2.28" CACHE STRING
    "Oldest glibc this build must run against, as the zig -target suffix")
set(ONEBIN_ZIG_TARGET "x86_64-linux-gnu.${ONEBIN_GLIBC_BASELINE}" CACHE STRING
    "zig -target triple for Profile H")

get_filename_component(_onebin_toolchain_dir "${CMAKE_CURRENT_LIST_FILE}" DIRECTORY)

set(CMAKE_C_COMPILER   "${_onebin_toolchain_dir}/zig-cc"  CACHE FILEPATH "" FORCE)
set(CMAKE_CXX_COMPILER "${_onebin_toolchain_dir}/zig-c++" CACHE FILEPATH "" FORCE)
set(CMAKE_AR      "${_onebin_toolchain_dir}/zig-ar"      CACHE FILEPATH "" FORCE)
set(CMAKE_RANLIB   "${_onebin_toolchain_dir}/zig-ranlib" CACHE FILEPATH "" FORCE)

# Deliberately NOT setting CMAKE_FIND_LIBRARY_SUFFIXES ".a" or
# BUILD_SHARED_LIBS OFF here, unlike the static toolchain file: Profile H's
# entire point is dynamic linking against the host's glibc/ld.so, and a
# hybrid build frequently still needs to find genuinely-dynamic system
# libraries (X11, Wayland, D-Bus client libs, ...). Forcing static-only
# library resolution would break exactly the dependencies this profile is
# supposed to keep dynamic. What stays static is the C/C++ *runtime*
# specifically — see the link flags below — not every dependency.
option(ONEBIN_EXPORT_DYNAMIC "This target exports an ABI to its own plugins" OFF)

set(_onebin_flags
    "-target ${ONEBIN_ZIG_TARGET}"
    "-fstack-protector-strong"
    "-ffile-prefix-map=${CMAKE_SOURCE_DIR}=."
    "-ffile-prefix-map=${CMAKE_BINARY_DIR}=."
    # Neutralizes a real conflict found while building far2l's TTYX broker:
    # a project that does plain `include_directories(/usr/include)` (not
    # `SYSTEM`) for some third-party header gives that directory `-I`
    # priority, which shadows zig's bundled libc++ header shims for any
    # C++ file that also pulls in the STL ("<cerrno> tried including
    # <errno.h> but didn't find libc++'s <errno.h> header"). Adding the
    # same path back in as `-isystem` — confirmed empirically, in either
    # flag order — restores libc++'s priority regardless of what a later
    # plain `-I/usr/include` does. Harmless when nothing needs it.
    "-isystem /usr/include"
)
string(JOIN " " _onebin_flags_str ${_onebin_flags})
set(CMAKE_C_FLAGS_INIT   "${_onebin_flags_str}")
set(CMAKE_CXX_FLAGS_INIT "${_onebin_flags_str}")

set(_onebin_link_flags
    "-static-libgcc"
    "-static-libstdc++"
    "-Wl,--gc-sections"   # zig cc identifies as Clang — see the static file's note
    "-Wl,-z,relro" "-Wl,-z,now" "-Wl,-z,noexecstack"
    # Empirically required (found while building a static-zlib smoketest):
    # zig's bundled glibc CRT startup objects (crti/crtn/start-*.S, etc.)
    # ship with DWARF debug info that embeds *zig's own* build-tree paths
    # (e.g. ".../lib/libc/glibc/sysdeps/x86_64/..."). Those objects were
    # already compiled when zig itself was built, so no -ffile-prefix-map
    # on *this* invocation can touch them — OB0060 fires on paths that do
    # not belong to this project at all. `-s` (strip symbol table and
    # debug info at link time) is the fix that actually reaches them;
    # -ffile-prefix-map alone (as STATUS.md previously assumed) is not
    # sufficient by itself. Confirmed: a hybrid build with
    # -ffile-prefix-map but without -s still FAILs OB0060 with 7 zig-path
    # warnings; adding -s clears it to a clean PASS Level 1, 0 findings.
    # Release binaries should not carry debug info anyway, so this is a
    # no-downside default for CMAKE_BUILD_TYPE=Release, not a workaround.
    "-s"
    # Empirically required (found while building far2l-tty): zig cc
    # -target does NOT search the host's normal system library directories
    # by default, even for a target that otherwise matches the host
    # exactly ("unable to find dynamic system library 'X11' using strategy
    # 'paths_first'. searched paths: none"). Profile H's entire point is
    # dynamic linking against host-provided libraries, so without this the
    # toolchain file would be unable to find anything beyond libc itself.
    "-L/usr/lib/${CMAKE_HOST_SYSTEM_PROCESSOR}-linux-gnu"
    "-L/usr/lib" "-L/lib/${CMAKE_HOST_SYSTEM_PROCESSOR}-linux-gnu"
)

# The linker flags above are not enough on their own: CMake's own
# find_library() (which find_package(X11) and friends use at *configure*
# time, before any compiler flag is involved) searches CMAKE_LIBRARY_PATH,
# a mechanism entirely separate from linker -L flags. Without this,
# find_package() fails outright rather than merely linking incorrectly.
#
# Deliberately NOT also adding CMAKE_INCLUDE_PATH here: doing so widens
# every C++ translation unit's header search order, not just the ones that
# actually need a host header, and that breaks zig's bundled libc++ ("tried
# including <errno.h> but didn't find libc++'s <errno.h> header") for any
# file that pulls in both a host header and libc++ — found while building
# far2l's TTYX broker. A target that genuinely needs a host include
# directory should add it itself (target_include_directories), which
# find_package(X11) already does when it succeeds via CMAKE_LIBRARY_PATH
# alone; this stays narrow rather than fixing one target by breaking
# others.
list(APPEND CMAKE_LIBRARY_PATH
    "/usr/lib/${CMAKE_HOST_SYSTEM_PROCESSOR}-linux-gnu" "/usr/lib" "/lib/${CMAKE_HOST_SYSTEM_PROCESSOR}-linux-gnu")
if(ONEBIN_EXPORT_DYNAMIC)
    list(APPEND _onebin_link_flags "-Wl,--export-dynamic")
else()
    # See onebin-linux-static.cmake's matching comment: zig 0.13.0's linker
    # does not support --exclude-libs at all, regardless of target.
    message(STATUS
        "onebin: -Wl,--exclude-libs,ALL requested by default but omitted — "
        "zig's linker does not currently support it (verified against zig 0.13.0).")
endif()
string(JOIN " " _onebin_link_flags_str ${_onebin_link_flags})
# SHARED/MODULE-only flags: same as above MINUS the host -L dirs.
# Found building far2l_sdl.so: those host -L dirs (needed by EXE
# targets like far2l_ttyx.broker for X11 discovery) come from CMake
# BEFORE a target's own target_link_directories() -- where far2l's
# pkg-config -L to THIS PROJECT'S OWN static libs lands. GNU ld
# resolves a bare -lNAME against the FIRST -L dir with any match, so
# far2l_sdl.so was linking the HOST's libfontconfig.so/libfreetype.so
# instead of our pinned static .a, silently. SHARED/MODULE targets in
# this project's own dependency chain (fontconfig, harfbuzz, ...) are
# always found via pkg-config -L already; dropping the blanket host
# -L here removes the shadowing without losing anything EXE targets
# still need.
list(REMOVE_ITEM _onebin_link_flags
    "-L/usr/lib/${CMAKE_HOST_SYSTEM_PROCESSOR}-linux-gnu"
    "-L/usr/lib" "-L/lib/${CMAKE_HOST_SYSTEM_PROCESSOR}-linux-gnu")
string(JOIN " " _onebin_link_flags_nohostl ${_onebin_link_flags})
set(CMAKE_EXE_LINKER_FLAGS_INIT    "${_onebin_link_flags_str} -pie")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "${_onebin_link_flags_nohostl}")
# Found building far2l_sdl.so (add_library(... MODULE ...) — a dlopen'd
# plugin, CMake's third linker-flags variable family besides EXE/SHARED):
# CMake uses CMAKE_MODULE_LINKER_FLAGS for MODULE targets, not
# CMAKE_SHARED_LINKER_FLAGS. Without this, MODULE targets got none of
# the hardening/strip flags above — confirmed missing -s produced 951
# embedded build-path strings and a non-$ORIGIN RPATH baked in from
# pkg-config-derived -L dirs, both real onebin audit failures.
set(CMAKE_MODULE_LINKER_FLAGS_INIT "${_onebin_link_flags_nohostl}")

# CMake auto-embeds an RPATH for every target_link_directories()/-L dir
# a project adds (default CMAKE_SKIP_RPATH=OFF), which is exactly how
# far2l_sdl.so ended up with a non-$ORIGIN RPATH pointing at this
# project's own sandbox library paths (from far2l's own
# target_link_directories(far2l_sdl PRIVATE ${SDL2_LIBRARY_DIRS} ...)).
# Static/allowlisted-dynamic Profile H artifacts should never carry a
# baked build-tree RPATH at all — turn the whole mechanism off globally
# rather than special-case every downstream project's CMakeLists.
set(CMAKE_SKIP_RPATH ON)
