# onebin-profile-u-far2l.cmake — attach the carried SoLo loader to far2l.
#
# This file is installed through CMAKE_PROJECT_INCLUDE by the Profile U
# far2l toolchain.  It deliberately waits until the top-level directory has
# finished: far2l and far2l_sdl are declared in subdirectories after the
# first project() call.  Keeping the loader at target scope is essential;
# putting a C++ archive in CMAKE_EXE_LINKER_FLAGS_INIT also contaminates
# CMake's C compiler try_compile targets, which have no C++ runtime.

# The deferred callback below runs in the top-level directory, while the
# upstream targets are declared by subdirectories.  CMP0079 NEW makes
# target_link_libraries preserve that cross-directory call instead of
# rejecting it during the deferred pass.
if(POLICY CMP0079)
    cmake_policy(SET CMP0079 NEW)
endif()

if(NOT PROJECT_IS_TOP_LEVEL)
    return()
endif()

function(_onebin_profile_u_attach_far2l)
    if(NOT ONEBIN_SOLO_ROOT)
        message(FATAL_ERROR
            "Profile U far2l hook requires ONEBIN_SOLO_ROOT; the carried "
            "SoLo loader cannot be linked implicitly")
    endif()

    set(_solo_archive "${ONEBIN_SOLO_ROOT}/libdlfcn.a")
    set(_solo_header "${ONEBIN_SOLO_ROOT}/lib/dlfcn.h")
    if(NOT EXISTS "${_solo_archive}")
        message(FATAL_ERROR
            "Profile U far2l hook: missing materialized SoLo archive: "
            "${_solo_archive}")
    endif()
    if(NOT EXISTS "${_solo_header}")
        message(FATAL_ERROR
            "Profile U far2l hook: missing SoLo header: ${_solo_header}")
    endif()
    if(NOT TARGET far2l)
        message(FATAL_ERROR
            "Profile U far2l hook: upstream target 'far2l' was not found; "
            "the loader must be attached to the main executable")
    endif()
    if(NOT TARGET far2l_sdl)
        message(FATAL_ERROR
            "Profile U far2l hook: upstream target 'far2l_sdl' was not "
            "found; the SDL module must use the carried dlfcn interface")
    endif()

    if(NOT TARGET onebin_profile_u_solo_dlfcn)
        add_library(onebin_profile_u_solo_dlfcn STATIC IMPORTED GLOBAL)
        set_property(TARGET onebin_profile_u_solo_dlfcn PROPERTY
                     IMPORTED_LOCATION "${_solo_archive}")
    endif()

    # dlfcn.h replaces the libc dl* declarations with SoLo's bridge for
    # application and module sources.  It is target-scoped, so CMake's own
    # C and C++ compiler probes remain ordinary probes.
    #
    # The libc header is force-included FIRST, and the order is the whole
    # point rather than a detail.  SoLo's header is written to be read
    # after it: it opens with `#undef RTLD_LAZY` and friends before
    # redefining them, and it wraps its own `Dl_info` in
    # `#if !defined(_DLFCN_H)`.  Both only make sense once the libc
    # header has already been seen.
    #
    # Force-including SoLo alone put it first, so `_DLFCN_H` was still
    # undefined, SoLo defined `Dl_info`, and then far2l's own
    # `utils/include/debug.h` pulled in <dlfcn.h>, which defined the same
    # typedef again:
    #
    #   generic-musl/dlfcn.h:33:3: error: typedef redefinition with
    #                              different types
    #
    # Reading the libc header first lets musl own `Dl_info` and the
    # `_DLFCN_H` guard, after which SoLo's `#undef`s and `#define dlopen
    # stub_dlopen` layer cleanly on top -- which is the arrangement its
    # author documented in the header itself.
    # _GNU_SOURCE, because the two headers must agree about Dl_info.
    #
    # musl declares Dl_info only under _GNU_SOURCE or _BSD_SOURCE. On
    # Linux the compiler defines _GNU_SOURCE implicitly for C++ but not
    # for strict C, and far2l sets it only on Cygwin and Haiku. So a C
    # source built as -std=c11 read musl's header, took the _DLFCN_H
    # guard, and got no Dl_info -- after which SoLo's own definition was
    # skipped for exactly that reason and its declaration
    #
    #   int stub_dladdr(const void*, Dl_info*);
    #
    # named a type that existed in neither header. The C++ half compiled
    # the whole time, which is what made it look like a C-only oddity
    # rather than the same asymmetry seen from the other side.
    #
    # Defining it puts C and C++ on the same footing here; C++ already
    # had it.

    # SHELL: on both, because CMake de-duplicates compile options.
    #
    # Written as four plain arguments, the second "-include" is dropped
    # as a repeat and its filename is left behind as a bare argument,
    # which the driver then treats as an input file. A .h input is a C
    # header, so the compile dies with
    #
    #   error: invalid argument '-std=c++17' not allowed with 'C'
    #
    # -- a message that says nothing about include ordering and points at
    # the wrong flag entirely. SHELL: keeps each option and its argument
    # together as one unit, which is what that prefix exists for.
    foreach(_solo_target far2l far2l_sdl)
        target_compile_options(${_solo_target} PRIVATE
            "-D_GNU_SOURCE"
            "SHELL:-include dlfcn.h"
            "SHELL:-include ${_solo_header}")
    endforeach()

    # CMake emits the correct --whole-archive / --no-whole-archive pair
    # around this one imported archive, and only for far2l.  The executable's
    # ENABLE_EXPORTS property (set upstream) exposes the bridge to the
    # dlopen'd SDL module.
    target_link_libraries(
        far2l PRIVATE
        "$<LINK_LIBRARY:WHOLE_ARCHIVE,onebin_profile_u_solo_dlfcn>")

    message(STATUS
        "Profile U far2l: attached target-scoped SoLo loader to far2l and "
        "its SDL module")
endfunction()

cmake_language(DEFER DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
               CALL _onebin_profile_u_attach_far2l)
