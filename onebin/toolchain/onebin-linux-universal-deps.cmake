# onebin-linux-universal-deps.cmake — Profile U dependency producer.
#
# Dependencies are compiled for the same musl target as the final U image,
# but their build systems may still configure helper SHARED/MODULE targets
# even when the recipe requests static libraries.  Profile S's executable
# flags (-static -pie) are correct for final executables, while U modules
# need the driver to select static target libraries after CMake's -shared
# create flag as well.  The zig wrappers enforce that final argv ordering;
# this file supplies the policy and shared-object hardening.
cmake_minimum_required(VERSION 3.16)

include("${CMAKE_CURRENT_LIST_DIR}/onebin-linux-static.cmake")

set(_onebin_shared_link_flags
    # SHARED/MODULE targets still have to be self-contained in Profile U.
    # The -static policy is normalized by zig-cc/zig-c++ after CMake has
    # emitted its complete argv; keeping it here also makes the intended
    # policy visible to CMake toolchain consumers.
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
