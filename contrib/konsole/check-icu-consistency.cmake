# static-everywhere: prove at configure time that the ICU headers and the
# ICU archives on konsole's link agree.
#
# Why this file exists
# --------------------
# konsole's link failed on undefined ubidi_open_74 while FindICU reported
# 78.1 from the same Conan package, the compile line carried that
# package's include dir and no host path, and one package supplied both
# headers and archives. Every inference from the artifact contradicted
# another. ICU renames every entry point with its major version, so a
# header/archive mismatch is exactly what "_74 undefined" means -- and it
# is decidable in one try_compile, at konsole's configure, in seconds,
# naming the versions instead of leaving a link error to be interpreted.
#
# The probe calls ubidi_open() through the real headers and links the real
# ICU targets. It cannot pass while the two disagree.
if(TARGET ICU::uc)
    include(CheckCXXSourceCompiles)

    # CMakeDeps can define ICU::uc before FindICU sees the package.  Such a
    # target commonly has generator expressions in its include directories
    # and no IMPORTED_LOCATION; CheckCXXSourceCompiles runs a separate
    # project and cannot reliably carry either detail into that project.  In
    # that case the old target-property probe silently compiled host ICU
    # headers and linked nothing.  Use FindICU's already-normalized values,
    # which are precisely the include directory and library that the
    # consumer's CMake lookup selected.  Target properties remain a fallback
    # for a plain FindICU installation that did not publish the variables.
    set(_se_icu_inc "${ICU_INCLUDE_DIRS}")
    if(NOT _se_icu_inc)
        get_target_property(_se_icu_inc ICU::uc INTERFACE_INCLUDE_DIRECTORIES)
    endif()
    set(_se_icu_lib "")
    if(CMAKE_BUILD_TYPE)
        string(TOUPPER "${CMAKE_BUILD_TYPE}" _se_icu_config)
        set(_se_icu_config_var "ICU_UC_LIBRARY_${_se_icu_config}")
        if(DEFINED ${_se_icu_config_var})
            set(_se_icu_lib "${${_se_icu_config_var}}")
        endif()
    endif()
    if(NOT _se_icu_lib)
        foreach(_se_icu_var ICU_UC_LIBRARY_RELEASE ICU_UC_LIBRARY_DEBUG
                            ICU_UC_LIBRARY ICU_UC_LIBRARIES)
            if(DEFINED ${_se_icu_var} AND NOT "${${_se_icu_var}}" MATCHES
               "-NOTFOUND$")
                set(_se_icu_lib "${${_se_icu_var}}")
                break()
            endif()
        endforeach()
    endif()
    if(NOT _se_icu_lib)
        get_target_property(_se_icu_lib ICU::uc IMPORTED_LOCATION_RELEASE)
        if(NOT _se_icu_lib OR "${_se_icu_lib}" MATCHES "-NOTFOUND$")
            get_target_property(_se_icu_lib ICU::uc IMPORTED_LOCATION)
        endif()
    endif()

    # If a fallback target property contains a generator expression, evaluate
    # it for the target/configuration before handing it to try_compile.  An
    # unevaluated expression is not a usable compiler include or archive path.
    if("${_se_icu_inc}" MATCHES "\\$<")
        string(GENEX_EVAL _se_icu_inc EXPRESSION "${_se_icu_inc}"
               TARGET ICU::uc)
    endif()
    if("${_se_icu_lib}" MATCHES "\\$<")
        string(GENEX_EVAL _se_icu_lib EXPRESSION "${_se_icu_lib}"
               TARGET ICU::uc)
    endif()
    if(NOT _se_icu_inc OR NOT _se_icu_lib)
        message(FATAL_ERROR
            "static-everywhere: FindICU did not expose a usable ICU include "
            "directory and uc library for the configure-time consistency "
            "probe (includes='${_se_icu_inc}', library='${_se_icu_lib}').")
    endif()
    foreach(_se_icu_dir IN LISTS _se_icu_inc)
        if(NOT IS_DIRECTORY "${_se_icu_dir}")
            message(FATAL_ERROR
                "static-everywhere: ICU include directory does not exist: "
                "'${_se_icu_dir}'")
        endif()
    endforeach()
    foreach(_se_icu_archive IN LISTS _se_icu_lib)
        if(IS_ABSOLUTE "${_se_icu_archive}" AND
           NOT EXISTS "${_se_icu_archive}")
            message(FATAL_ERROR
                "static-everywhere: ICU uc library does not exist: "
                "'${_se_icu_archive}'")
        endif()
    endforeach()

    set(_se_icu_saved_required_includes "${CMAKE_REQUIRED_INCLUDES}")
    set(_se_icu_saved_required_libraries "${CMAKE_REQUIRED_LIBRARIES}")
    set(CMAKE_REQUIRED_INCLUDES ${_se_icu_inc})
    set(CMAKE_REQUIRED_LIBRARIES "${_se_icu_lib};${CMAKE_DL_LIBS}")
    unset(_se_icu_header_matches_library CACHE)
    unset(_se_icu_header_matches_library)
    check_cxx_source_compiles("
        #include <unicode/ubidi.h>
        #include <unicode/uvernum.h>
        int main() { UBiDi* b = ubidi_open(); ubidi_close(b); return 0; }
    " _se_icu_header_matches_library)
    if(NOT _se_icu_header_matches_library)
        message(FATAL_ERROR
            "static-everywhere: the ICU headers and the ICU library disagree.\n"
            "  ICU_VERSION as found: ${ICU_VERSION}\n"
            "  include dirs:         ${_se_icu_inc}\n"
            "  uc library:           ${_se_icu_lib}\n"
            "ICU renames every entry point with its major version, so a call "
            "that compiles but does not link means the headers and the archive "
            "come from different ICU versions. Check the package and static "
            "Qt binary selected by Conan for the same graph.")
    endif()
    set(CMAKE_REQUIRED_INCLUDES "${_se_icu_saved_required_includes}")
    set(CMAKE_REQUIRED_LIBRARIES "${_se_icu_saved_required_libraries}")
    message(STATUS "static-everywhere: ICU headers and library agree (version ${ICU_VERSION})")
endif()
