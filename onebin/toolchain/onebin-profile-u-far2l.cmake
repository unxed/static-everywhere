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
    target_compile_options(far2l PRIVATE "-include" "${_solo_header}")
    target_compile_options(far2l_sdl PRIVATE "-include" "${_solo_header}")

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
