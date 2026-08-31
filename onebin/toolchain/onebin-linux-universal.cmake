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

include("${CMAKE_CURRENT_LIST_DIR}/onebin-linux-static.cmake")

set(ONEBIN_PROFILE "universal")

# The build still needs host X11/OpenGL metadata to configure SDL's shared
# backend, but these paths are deliberately absent from linker flags. The
# final artifacts are audited for DT_NEEDED; any actual host linkage fails
# there instead of being silently accepted by this discovery-only allowance.
set(CMAKE_FIND_LIBRARY_SUFFIXES ".a" ".so")
list(APPEND CMAKE_LIBRARY_PATH
     "/usr/lib/${CMAKE_HOST_SYSTEM_PROCESSOR}-linux-gnu"
     "/usr/lib" "/lib/${CMAKE_HOST_SYSTEM_PROCESSOR}-linux-gnu")

# The included Profile S file computes the static link flags before forcing
# the U export policy above. Add the two U-specific pieces explicitly and
# keep them on the executable only: far2l's SDL module resolves the bridge
# from the exported main executable.
if(ONEBIN_SOLO_ROOT)
    if(NOT EXISTS "${ONEBIN_SOLO_ROOT}/libdlfcn.a")
        message(FATAL_ERROR
            "onebin Profile U: missing materialized ${ONEBIN_SOLO_ROOT}/libdlfcn.a archive")
    endif()
    if(NOT EXISTS "${ONEBIN_SOLO_ROOT}/lib/dlfcn.h")
        message(FATAL_ERROR
            "onebin Profile U: missing ${ONEBIN_SOLO_ROOT}/lib/dlfcn.h")
    endif()
    if(NOT CMAKE_C_FLAGS_INIT MATCHES "lib/dlfcn\\.h")
        string(APPEND CMAKE_C_FLAGS_INIT
               " -include ${ONEBIN_SOLO_ROOT}/lib/dlfcn.h")
    endif()
    if(NOT CMAKE_CXX_FLAGS_INIT MATCHES "lib/dlfcn\\.h")
        string(APPEND CMAKE_CXX_FLAGS_INIT
               " -include ${ONEBIN_SOLO_ROOT}/lib/dlfcn.h")
    endif()
    if(NOT CMAKE_EXE_LINKER_FLAGS_INIT MATCHES "dlfcn")
        string(APPEND CMAKE_EXE_LINKER_FLAGS_INIT
               " -Wl,--whole-archive ${ONEBIN_SOLO_ROOT}/libdlfcn.a"
               " -Wl,--no-whole-archive")
    endif()
endif()

# CMake has a separate flag family for add_library(... MODULE ...). The
# included static toolchain predates MODULE consumers, so mirror its static
# hardening flags here instead of letting a module acquire a dynamic linker
# or host DT_NEEDED entries by accident.
set(CMAKE_MODULE_LINKER_FLAGS_INIT "${CMAKE_SHARED_LINKER_FLAGS_INIT}")
