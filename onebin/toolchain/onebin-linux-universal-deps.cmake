# onebin-linux-universal-deps.cmake — Profile U dependency producer.
#
# Dependencies are compiled for the same musl target as the final U image,
# but their build systems may still configure helper SHARED/MODULE targets
# even when the recipe requests static libraries.  Profile S's executable
# flags (-static -pie) are correct for final executables and invalid for
# CMake's SHARED/MODULE link rules.  Keep those flags on EXE targets and use
# shared-object-safe hardening for the other target kinds.
cmake_minimum_required(VERSION 3.16)

include("${CMAKE_CURRENT_LIST_DIR}/onebin-linux-static.cmake")

set(_onebin_shared_link_flags
    # SHARED/MODULE targets still have to be self-contained in Profile U.
    # The -static/-pie executable pair is invalid with CMake's -shared link
    # rule, but -static by itself is valid there and tells the compiler driver
    # to select static target libraries for the shared object.  A linker-only
    # -Bstatic is insufficient for Zig's driver: the module can still acquire
    # the target libc.so while every explicitly listed third-party library
    # remains .a.  That is exactly the partial-static failure Profile U is
    # meant to catch.
    "-static"
    "-Wl,-z,relro"
    "-Wl,-z,now"
    "-Wl,-z,noexecstack"
)
string(JOIN " " _onebin_shared_link_flags_str ${_onebin_shared_link_flags})
set(CMAKE_SHARED_LINKER_FLAGS_INIT
    "${_onebin_shared_link_flags_str}")
set(CMAKE_MODULE_LINKER_FLAGS_INIT
    "${_onebin_shared_link_flags_str}")

set(CMAKE_SKIP_RPATH ON)
