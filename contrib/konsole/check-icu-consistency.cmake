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
    get_target_property(_se_icu_inc ICU::uc INTERFACE_INCLUDE_DIRECTORIES)
    set(CMAKE_REQUIRED_INCLUDES ${_se_icu_inc})
    # The resolved archive path, not the imported target: an imported
    # target without IMPORTED_CONFIGURATIONS does not resolve inside
    # try_compile, and the probe then fails for a reason that has nothing
    # to do with ICU -- which it did on the first run of this file.
    get_target_property(_se_icu_lib ICU::uc IMPORTED_LOCATION_RELEASE)
    if(NOT _se_icu_lib)
        get_target_property(_se_icu_lib ICU::uc IMPORTED_LOCATION)
    endif()
    if(NOT _se_icu_lib)
        set(_se_icu_lib ICU::uc)
    endif()
    set(CMAKE_REQUIRED_LIBRARIES "${_se_icu_lib}")
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
            "ICU renames every entry point with its major version, so a call "
            "that compiles but does not link means the headers and the archive "
            "come from different ICU versions. konsole's link failed with "
            "'undefined symbol: ubidi_open_74' this way. Check which icu "
            "package Conan resolved (qt's recipe requires icu/[>=74.2], this "
            "recipe pins icu/78.1) and whether the cached qt binary was built "
            "against a different one.")
    endif()
    unset(CMAKE_REQUIRED_INCLUDES)
    unset(CMAKE_REQUIRED_LIBRARIES)
    message(STATUS "static-everywhere: ICU headers and library agree (version ${ICU_VERSION})")
endif()
