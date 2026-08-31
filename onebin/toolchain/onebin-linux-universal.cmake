# onebin-linux-universal.cmake — Profile U: static-PIE musl image with a
# carried host-library loader. The first consumer is far2l SDL through SoLo;
# the ordinary Profile S toolchain supplies the ELF boundary and this file
# adds the loader archive/header only when ONEBIN_SOLO_ROOT is provided.
#
# Profile U's host boundary is intentionally stricter than Profile H's:
# artifacts have no PT_INTERP and no DT_NEEDED. Host graphics libraries are
# opened by the carried loader at runtime, not by the kernel's ELF loader.
cmake_minimum_required(VERSION 3.16)

set(ONEBIN_EXPORT_DYNAMIC ON CACHE BOOL
    "Profile U exports the carried loader ABI to its modules" FORCE)
set(ONEBIN_SOLO_ROOT "" CACHE PATH
    "SoLo handoff root containing libdlfcn.a and lib/dlfcn.h")

include("${CMAKE_CURRENT_LIST_DIR}/onebin-linux-universal-deps.cmake")

set(ONEBIN_PROFILE "universal")

# The build still needs host X11/OpenGL metadata to configure SDL's shared
# backend, but these paths are deliberately absent from linker flags. The
# final artifacts are audited for DT_NEEDED; any actual host linkage fails
# there instead of being silently accepted by this discovery-only allowance.
set(CMAKE_FIND_LIBRARY_SUFFIXES ".a" ".so")
list(APPEND CMAKE_LIBRARY_PATH
     "/usr/lib/${CMAKE_HOST_SYSTEM_PROCESSOR}-linux-gnu"
     "/usr/lib" "/lib/${CMAKE_HOST_SYSTEM_PROCESSOR}-linux-gnu")

# The included Profile U dependency toolchain computes the static executable
# boundary and shared/module-safe flags.  The carried loader is attached by a
# deferred target hook below, after far2l's subdirectories have declared the
# executable and SDL module; it must not be a global CMake linker flag.
if(ONEBIN_SOLO_ROOT)
    if(NOT EXISTS "${ONEBIN_SOLO_ROOT}/libdlfcn.a")
        message(FATAL_ERROR
            "onebin Profile U: missing materialized ${ONEBIN_SOLO_ROOT}/libdlfcn.a archive")
    endif()
    if(NOT EXISTS "${ONEBIN_SOLO_ROOT}/lib/dlfcn.h")
        message(FATAL_ERROR
            "onebin Profile U: missing ${ONEBIN_SOLO_ROOT}/lib/dlfcn.h")
    endif()
    set(CMAKE_PROJECT_INCLUDE
        "${CMAKE_CURRENT_LIST_DIR}/onebin-profile-u-far2l.cmake")
endif()

# onebin-linux-universal-deps.cmake keeps -static/-pie on EXE targets and
# asks the zig wrappers to place -static after CMake's -shared create flag
# for SHARED/MODULE targets. Thus every U shared object uses static target
# libraries while retaining its ET_DYN form and no host DT_NEEDED boundary.
