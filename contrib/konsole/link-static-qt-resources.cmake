# Qt resources listed as .qrc sources of a STATIC library never reach the
# program. AUTORCC compiles each .qrc into its own object whose only entry
# point is a static initializer; nothing references that object, so the
# linker does not extract it from the archive and the resource tree is empty
# at runtime. A shared build never shows this, because a shared library keeps
# every object it was linked from.
#
# Konsole lists data/data.qrc and desktop/konsole.qrc as konsoleprivate
# sources. The CI smoke run started a window whose menu had only View,
# Settings and Help: KXmlGui logged `cannot find .rc file "konsoleui.rc"`,
# the keyboard translator logged `Unable to load translator "default"`, and
# the bundled colour schemes were missing, all of which live under :/konsole
# and :/kxmlgui5/konsole.
#
# The mechanism is closed for every STATIC target of the project, not for one
# resource name: each such target's .qrc files move to an OBJECT library,
# and its objects become a link item of the static library's consumers --
# the same shape qt_add_resources() uses for static Qt builds. An object
# file on the link line is always linked, so its initializer always runs.
function(_se_collect_directory_targets directory out_var)
    get_property(_se_targets DIRECTORY "${directory}" PROPERTY BUILDSYSTEM_TARGETS)
    get_property(_se_subdirectories DIRECTORY "${directory}" PROPERTY SUBDIRECTORIES)
    foreach(_se_subdirectory IN LISTS _se_subdirectories)
        _se_collect_directory_targets("${_se_subdirectory}" _se_sub_targets)
        list(APPEND _se_targets ${_se_sub_targets})
    endforeach()
    set(${out_var} ${_se_targets} PARENT_SCOPE)
endfunction()

function(_se_link_static_qt_resources)
    _se_collect_directory_targets("${CMAKE_CURRENT_SOURCE_DIR}" _se_targets)
    set(_se_resource_targets)
    foreach(_se_target IN LISTS _se_targets)
        get_target_property(_se_type "${_se_target}" TYPE)
        if(NOT _se_type STREQUAL "STATIC_LIBRARY")
            continue()
        endif()
        get_target_property(_se_sources "${_se_target}" SOURCES)
        if(NOT _se_sources)
            continue()
        endif()
        get_target_property(_se_source_dir "${_se_target}" SOURCE_DIR)
        set(_se_qrc)
        set(_se_other)
        foreach(_se_source IN LISTS _se_sources)
            if(_se_source MATCHES "\\.qrc$" AND NOT _se_source MATCHES "^\\$<")
                get_filename_component(_se_source "${_se_source}" ABSOLUTE
                    BASE_DIR "${_se_source_dir}")
                list(APPEND _se_qrc "${_se_source}")
            else()
                list(APPEND _se_other "${_se_source}")
            endif()
        endforeach()
        if(NOT _se_qrc)
            continue()
        endif()

        set(_se_object "${_se_target}_se_qt_resources")
        add_library("${_se_object}" OBJECT ${_se_qrc})
        # The only compiled sources are the qrc_*.cpp AUTORCC adds at
        # generate time, so CMake cannot infer the language from the list.
        set_target_properties("${_se_object}" PROPERTIES
            LINKER_LANGUAGE CXX
            AUTORCC ON
            AUTOMOC OFF
            AUTOUIC OFF
            POSITION_INDEPENDENT_CODE ON)
        get_target_property(_se_rcc_options "${_se_target}" AUTORCC_OPTIONS)
        if(_se_rcc_options)
            set_property(TARGET "${_se_object}" PROPERTY
                AUTORCC_OPTIONS ${_se_rcc_options})
        endif()
        if(TARGET Qt6::Core)
            target_link_libraries("${_se_object}" PRIVATE Qt6::Core)
        endif()
        set_property(TARGET "${_se_target}" PROPERTY SOURCES ${_se_other})
        set_property(TARGET "${_se_target}" APPEND PROPERTY
            INTERFACE_LINK_LIBRARIES "$<TARGET_OBJECTS:${_se_object}>")
        list(APPEND _se_resource_targets "${_se_target}")
        message(STATUS
            "static-everywhere: ${_se_target} Qt resources are linked into "
            "every consumer: ${_se_qrc}")
    endforeach()
    if(NOT _se_resource_targets)
        message(STATUS "static-everywhere: no STATIC target carries .qrc sources")
    endif()
endfunction()
