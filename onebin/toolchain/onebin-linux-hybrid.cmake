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
    "-pie"
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
set(CMAKE_EXE_LINKER_FLAGS_INIT    "${_onebin_link_flags_str}")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "${_onebin_link_flags_str}")
