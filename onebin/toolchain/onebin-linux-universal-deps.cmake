# onebin-linux-universal-deps.cmake — Profile U dependency producer.
#
# Dependencies are compiled for the same musl target as the final U image,
# but their build systems may still configure helper SHARED/MODULE targets
# even when the recipe requests static libraries.  Profile S's executable
# flags (-static -pie) are correct for final executables.  U modules retain
# ET_DYN while the zig wrappers suppress Zig's implicit libc/startup set
# (-nolibc/-nostdlib), remove musl's libc-folded compatibility -l flags, use
# the C driver for C++ object-only module links, and put the final static
# driver mode after CMake's -shared create flag.  C++ modules carry their
# libc++/libc++abi/libunwind archives; only libc remains process-wide and is
# bound by SoLo from the exported U executable.  This avoids relying on
# hidden static-PIC C++ ABI definitions becoming dynamic exports, while still
# producing no DT_NEEDED.
# This file supplies the policy and shared-object hardening.
cmake_minimum_required(VERSION 3.16)

include("${CMAKE_CURRENT_LIST_DIR}/onebin-linux-static.cmake")

set(_onebin_shared_link_flags
    # Keep the U module boundary hardened.  Static-mode and libc suppression
    # are normalized by zig-cc/zig-c++ after CMake has emitted its complete
    # argv; keeping the hardening here makes the policy visible to all
    # CMake toolchain consumers.  The wrappers also add the target C++
    # runtime archives for every musl C++ module, so this applies to the
    # whole Profile U module family rather than only far2l SDL.
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
