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

# Some dependency sources use the host dlfcn ABI directly instead of going
# through their own loadso abstraction. In Profile U those calls must use the
# carried loader's interface, including its RTLD_* values; resolving a native
# dlopen symbol later through a static fallback cannot translate the flags
# that the already-compiled caller passes. This opt-in is applied by the
# dependency recipe only to such a producer (currently SDL2), and leaves the
# ordinary CMake compiler/link probes unchanged unless the producer also
# supplies the corresponding cached feature result.
set(ONEBIN_PROFILE_U_DLOPEN_HEADER "" CACHE FILEPATH
    "SoLo dlfcn.h to force-include in a Profile U dynamic-loading dependency")
if(ONEBIN_PROFILE_U_DLOPEN_HEADER AND
   NOT _ONEBIN_PROFILE_U_DLOPEN_FLAGS_ADDED)
    if(NOT EXISTS "${ONEBIN_PROFILE_U_DLOPEN_HEADER}")
        message(FATAL_ERROR
            "onebin Profile U: missing dependency dlfcn header: "
            "${ONEBIN_PROFILE_U_DLOPEN_HEADER}")
    endif()
    set(_onebin_profile_u_dlfcn_flags
        "-include dlfcn.h"
        "-include \"${ONEBIN_PROFILE_U_DLOPEN_HEADER}\"")
    string(JOIN " " _onebin_profile_u_dlfcn_flags_str
           ${_onebin_profile_u_dlfcn_flags})

    # CMake may evaluate a toolchain file more than once while it identifies
    # the compiler.  On the first pass CMAKE_*_FLAGS_INIT is still consumed,
    # but on a later pass CMake already has CMAKE_*_FLAGS in the cache and a
    # change to the *_INIT variables is ignored.  Put the opt-in in the final
    # cache flags as well, preserving the static toolchain's flags and any
    # caller-provided flags.  This keeps every CMake target that includes
    # <dlfcn.h> on the Profile U ABI, not just the target that exposed the
    # original failure.
    foreach(_onebin_profile_u_lang C CXX)
        if(_onebin_profile_u_lang STREQUAL "C")
            set(_onebin_profile_u_flags_var CMAKE_C_FLAGS)
            set(_onebin_profile_u_flags_init_var CMAKE_C_FLAGS_INIT)
        else()
            set(_onebin_profile_u_flags_var CMAKE_CXX_FLAGS)
            set(_onebin_profile_u_flags_init_var CMAKE_CXX_FLAGS_INIT)
        endif()

        string(FIND "${${_onebin_profile_u_flags_var}}"
               "${ONEBIN_PROFILE_U_DLOPEN_HEADER}"
               _onebin_profile_u_header_pos)
        if(_onebin_profile_u_header_pos EQUAL -1)
            if(DEFINED ${_onebin_profile_u_flags_var} AND
               NOT "${${_onebin_profile_u_flags_var}}" STREQUAL "")
                set(_onebin_profile_u_current_flags
                    "${${_onebin_profile_u_flags_var}}")
            else()
                set(_onebin_profile_u_current_flags
                    "${${_onebin_profile_u_flags_init_var}}")
            endif()
            string(APPEND _onebin_profile_u_current_flags " "
                   "${_onebin_profile_u_dlfcn_flags_str}")
            set(${_onebin_profile_u_flags_var}
                "${_onebin_profile_u_current_flags}" CACHE STRING
                "Profile U ${_onebin_profile_u_lang} compiler flags" FORCE)
        endif()
    endforeach()
    set(_ONEBIN_PROFILE_U_DLOPEN_FLAGS_ADDED TRUE)
endif()

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

# The universal dependency graph is otherwise host-independent. A recipe may
# opt in to the narrow graphics host contract when a package performs CMake
# find_library() discovery for runtime-loaded X11/GL objects. This is kept
# separate from the compiler wrapper's libc-header isolation and from the
# final artifact's linker flags.
option(ONEBIN_HOST_GRAPHICS
       "Allow CMake discovery of host X11/OpenGL libraries" OFF)
if(ONEBIN_HOST_GRAPHICS)
    list(APPEND CMAKE_LIBRARY_PATH
         "/usr/lib/${CMAKE_HOST_SYSTEM_PROCESSOR}-linux-gnu"
         "/usr/lib" "/lib/${CMAKE_HOST_SYSTEM_PROCESSOR}-linux-gnu")
endif()
