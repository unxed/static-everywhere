# static-everywhere: export the private static helpers that a static
# build drags into an export set.
#
# The shape, seen in knewstuff and general to any KDE module built with
# BUILD_SHARED_LIBS=OFF: a library links an internal STATIC helper
# PRIVATE --
#
#   add_library(knscore_jobs_static STATIC ...)
#   target_link_libraries(KF6NewStuffCore PRIVATE knscore_jobs_static)
#   install(TARGETS KF6NewStuffCore EXPORT KF6NewStuffCoreTargets ...)
#
# For a *shared* KF6NewStuffCore the helper is absorbed and never
# mentioned again. For a *static* one CMake must record it as
# $<LINK_ONLY:knscore_jobs_static> in the exported interface, and then
# requires it to be in an export set too:
#
#   install(EXPORT "KF6NewStuffCoreTargets" ...) includes target
#   "KF6NewStuffCore" which requires target "knscore_jobs_static" that
#   is not in any export set.
#
# Upstream builds shared, so upstream never sees it. The fix is the one
# upstream would apply -- install the helper into the same export set --
# done here for every such helper in every module, at the end of the
# top-level directory when all targets exist, so a second module with the
# same shape does not cost another two-hour run.
#
# CMake cannot be asked which export set a target went into, so the set
# is read from the consumer's own CMakeLists.txt: the same
# `install(TARGETS X EXPORT Set` line the module wrote. If that cannot be
# found the helper is reported and left alone; guessing a set name would
# only move the error.

function(_se_export_private_static_helpers)
    get_property(_se_dirs GLOBAL PROPERTY _se_all_dirs)
    _se_collect_targets("${CMAKE_SOURCE_DIR}" _se_targets)

    # Helpers: STATIC libraries with no install rule of their own.
    set(_se_helpers)
    foreach(_t IN LISTS _se_targets)
        get_target_property(_type "${_t}" TYPE)
        if(NOT _type STREQUAL "STATIC_LIBRARY")
            continue()
        endif()
        get_target_property(_installed "${_t}" _se_installed)
        if(_installed)
            continue()
        endif()
        list(APPEND _se_helpers "${_t}")
    endforeach()
    if(NOT _se_helpers)
        return()
    endif()

    foreach(_consumer IN LISTS _se_targets)
        get_target_property(_type "${_consumer}" TYPE)
        if(NOT _type STREQUAL "STATIC_LIBRARY")
            continue()
        endif()
        get_target_property(_links "${_consumer}" LINK_LIBRARIES)
        if(NOT _links)
            continue()
        endif()
        foreach(_helper IN LISTS _se_helpers)
            if(NOT "${_helper}" IN_LIST _links)
                continue()
            endif()
            # The consumer's export set, from the file that declared it.
            get_target_property(_src "${_consumer}" SOURCE_DIR)
            file(READ "${_src}/CMakeLists.txt" _text)
            string(REGEX MATCH
                "install[ \t]*\\([ \t]*TARGETS[ \t]+${_consumer}[ \t]+EXPORT[ \t]+([A-Za-z0-9_]+)"
                _m "${_text}")
            if(NOT _m)
                message(STATUS
                    "static-everywhere: ${_consumer} links private static helper "
                    "${_helper}, but its export set could not be read from "
                    "${_src}/CMakeLists.txt; leaving it alone")
                continue()
            endif()
            set(_set "${CMAKE_MATCH_1}")
            get_target_property(_done "${_helper}" _se_exported_into)
            if(_done)
                continue()
            endif()
            install(TARGETS "${_helper}" EXPORT "${_set}"
                    ${KF_INSTALL_TARGETS_DEFAULT_ARGS})
            set_property(TARGET "${_helper}" PROPERTY _se_exported_into "${_set}")
            message(STATUS
                "static-everywhere: exported private static helper ${_helper} "
                "into ${_set} alongside ${_consumer}")
        endforeach()
    endforeach()
endfunction()

# All targets in the tree, recursively, since add_subdirectory scopes
# hide them from a single BUILDSYSTEM_TARGETS query.
function(_se_collect_targets _dir _out)
    get_property(_here DIRECTORY "${_dir}" PROPERTY BUILDSYSTEM_TARGETS)
    get_property(_subs DIRECTORY "${_dir}" PROPERTY SUBDIRECTORIES)
    set(_all ${_here})
    foreach(_s IN LISTS _subs)
        _se_collect_targets("${_s}" _sub_targets)
        list(APPEND _all ${_sub_targets})
    endforeach()
    set("${_out}" "${_all}" PARENT_SCOPE)
endfunction()

# Record which targets the module installs itself, so helpers already
# handled upstream are not exported twice. install() is a command, not a
# property, so wrap it: any install(TARGETS ...) marks its targets.
if(NOT COMMAND _se_original_install)
    function(install)
        if(ARGV0 STREQUAL "TARGETS")
            set(_i 1)
            while(_i LESS ARGC)
                set(_a "${ARGV${_i}}")
                if(_a MATCHES "^(EXPORT|RUNTIME|LIBRARY|ARCHIVE|OBJECTS|FRAMEWORK|BUNDLE|PRIVATE_HEADER|PUBLIC_HEADER|RESOURCE|FILE_SET|INCLUDES|DESTINATION|PERMISSIONS|CONFIGURATIONS|COMPONENT|NAMELINK_.*|OPTIONAL|EXCLUDE_FROM_ALL)$")
                    break()
                endif()
                if(TARGET "${_a}")
                    set_property(TARGET "${_a}" PROPERTY _se_installed TRUE)
                endif()
                math(EXPR _i "${_i} + 1")
            endwhile()
        endif()
        _install(${ARGV})
    endfunction()
endif()

cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}"
               CALL _se_export_private_static_helpers)
