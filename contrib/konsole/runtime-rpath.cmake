# Keep every loadable target owned by the Konsole application relocatable.
#
# CMAKE_PROJECT_INCLUDE runs during project(), while KDE's CMake settings and
# Konsole's targets are declared afterwards. Applying only CMAKE_* variables
# there is therefore not a reliable target contract: later settings can
# change the defaults before the target is generated. The deferred callback
# walks the complete application directory tree and sets the target
# properties after all of those declarations, so new shared/module targets
# receive the same rule automatically.
function(_se_konsole_collect_loadable_targets directory out_var)
    get_property(_targets DIRECTORY "${directory}" PROPERTY BUILDSYSTEM_TARGETS)
    set(_loadable_targets)
    foreach(_target IN LISTS _targets)
        get_target_property(_type "${_target}" TYPE)
        if(_type STREQUAL "EXECUTABLE" OR
           _type STREQUAL "SHARED_LIBRARY" OR
           _type STREQUAL "MODULE_LIBRARY")
            list(APPEND _loadable_targets "${_target}")
        endif()
    endforeach()

    get_property(_subdirectories DIRECTORY "${directory}" PROPERTY SUBDIRECTORIES)
    foreach(_subdirectory IN LISTS _subdirectories)
        _se_konsole_collect_loadable_targets(
            "${_subdirectory}" _subdirectory_loadable_targets)
        list(APPEND _loadable_targets ${_subdirectory_loadable_targets})
    endforeach()
    set(${out_var} "${_loadable_targets}" PARENT_SCOPE)
endfunction()

function(_se_konsole_set_runtime_rpath_for_target target)
    if(NOT TARGET "${target}")
        return()
    endif()
    get_target_property(_type "${target}" TYPE)
    if(NOT _type STREQUAL "EXECUTABLE" AND
       NOT _type STREQUAL "SHARED_LIBRARY" AND
       NOT _type STREQUAL "MODULE_LIBRARY")
        return()
    endif()
    set_target_properties("${target}" PROPERTIES
        BUILD_RPATH_USE_ORIGIN ON
        INSTALL_RPATH "\$ORIGIN/../lib"
        INSTALL_RPATH_USE_LINK_PATH OFF
        SKIP_BUILD_RPATH OFF
        SKIP_INSTALL_RPATH OFF
    )
endfunction()

function(_se_konsole_set_runtime_rpath)
    _se_konsole_collect_loadable_targets(
        "${CMAKE_CURRENT_SOURCE_DIR}" _se_konsole_loadable_targets)
    foreach(_target IN LISTS _se_konsole_loadable_targets)
        _se_konsole_set_runtime_rpath_for_target("${_target}")
    endforeach()
    list(LENGTH _se_konsole_loadable_targets _loadable_count)
    message(STATUS
        "static-everywhere: applied Konsole runtime RPATH to "
        "${_loadable_count} loadable targets")
endfunction()
