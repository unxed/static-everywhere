# static-everywhere: import the Qt platform and xcb GL plugins.
#
# Conan's CMakeDeps package files expose Qt's static archives but do not
# reproduce the Q_IMPORT_PLUGIN unit that Qt's own package exports. A static
# Widgets executable therefore builds successfully and then dies before main
# with "Could not find the Qt platform plugin xcb". The xcb GL integrations
# are a second, independent failure: without them a window can exist but Qt
# cannot create the OpenGL context used to paint it.

if(NOT PROJECT_IS_TOP_LEVEL)
    return()
endif()

function(_se_konsole_plugin_class archive out_var)
    file(STRINGS "${archive}" _symbols REGEX "_Z[0-9]+qt_static_plugin_")
    string(REGEX MATCH "_Z([0-9]+)qt_static_plugin_" _match "${_symbols}")
    if(NOT _match)
        message(FATAL_ERROR
            "static-everywhere: ${archive} has no qt_static_plugin_<Class> "
            "symbol; it cannot be imported as a static Qt plugin")
    endif()
    set(_length "${CMAKE_MATCH_1}")
    string(FIND "${_symbols}" "${_match}" _at)
    string(LENGTH "_Z${_length}" _prefix_length)
    math(EXPR _at "${_at} + ${_prefix_length}")
    string(SUBSTRING "${_symbols}" ${_at} ${_length} _full)
    string(REPLACE "qt_static_plugin_" "" _class "${_full}")
    if(NOT _class MATCHES "^[A-Za-z_][A-Za-z0-9_]*$")
        message(FATAL_ERROR
            "static-everywhere: malformed plugin class '${_class}' in "
            "${archive}; the Itanium symbol length was not parsed correctly")
    endif()
    set(${out_var} "${_class}" PARENT_SCOPE)
endfunction()

function(_se_konsole_prl_closure archive out_var)
    get_filename_component(_dir "${archive}" DIRECTORY)
    get_filename_component(_base "${archive}" NAME_WE)
    set(_prl "${_dir}/${_base}.prl")
    if(NOT EXISTS "${_prl}")
        message(FATAL_ERROR
            "static-everywhere: ${_prl} is missing. Qt's .prl is the source "
            "of truth for a static plugin's backing-library closure")
    endif()

    file(STRINGS "${_prl}" _line REGEX "^QMAKE_PRL_LIBS[ \\t]*=")
    if(NOT _line)
        set(${out_var} "" PARENT_SCOPE)
        return()
    endif()
    string(REGEX REPLACE "^QMAKE_PRL_LIBS[ \\t]*=[ \\t]*" "" _libs "${_line}")
    set(_qt_prefix "${qt_PACKAGE_FOLDER_RELEASE}")
    if(NOT _qt_prefix)
        set(_qt_prefix "${Qt6_PACKAGE_FOLDER_RELEASE}")
    endif()
    if(NOT _qt_prefix OR _qt_prefix MATCHES "^/(usr|lib)(/|$)")
        message(FATAL_ERROR
            "static-everywhere: Qt package folder is missing or host-owned: "
            "'${_qt_prefix}'")
    endif()
    string(REPLACE "$$[QT_INSTALL_PREFIX]" "${_qt_prefix}" _libs "${_libs}")
    string(REPLACE "$$[QT_INSTALL_LIBS]" "${_qt_prefix}/lib" _libs "${_libs}")
    string(REPLACE "$$[QT_INSTALL_PLUGINS]" "${_qt_prefix}/plugins" _libs "${_libs}")
    string(REPLACE "$$[QT_INSTALL_ARCHDATA]" "${_qt_prefix}" _libs "${_libs}")
    if(_libs MATCHES "\\$\\$\\[([A-Z_]+)\\]")
        message(FATAL_ERROR
            "static-everywhere: unhandled qmake token in ${_prl}: "
            "$$[${CMAKE_MATCH_1}]")
    endif()

    # Conan may leave its build-time target names in QMAKE_PRL_LIBS. They are
    # not paths and must not become CMake target references unless that target
    # actually exists. Qt's component interface already carries these Conan
    # libraries; retaining an unknown :: token makes generation fail.
    string(REGEX REPLACE "/[^ ;]*/p/lib/" "${_qt_prefix}/lib/" _libs "${_libs}")
    separate_arguments(_items UNIX_COMMAND "${_libs}")
    set(_result "")
    foreach(_item IN LISTS _items)
        string(REGEX REPLACE "^-l" "" _bare "${_item}")
        if(_bare MATCHES "::" AND NOT TARGET "${_bare}")
            continue()
        endif()
        if(_item MATCHES "^/" AND NOT EXISTS "${_item}")
            continue()
        endif()
        list(APPEND _result "${_item}")
    endforeach()
    set(${out_var} "${_result}" PARENT_SCOPE)
endfunction()

function(_se_konsole_import_one archive imports_var libs_var)
    _se_konsole_plugin_class("${archive}" _class)
    _se_konsole_prl_closure("${archive}" _closure)
    string(APPEND _imports "Q_IMPORT_PLUGIN(${_class})\n")
    set(_new_libs "${archive}")
    list(APPEND _new_libs ${_closure})
    set(${imports_var} "${${imports_var}}${_imports}" PARENT_SCOPE)
    set(${libs_var} ${${libs_var}} ${_new_libs} PARENT_SCOPE)
endfunction()

function(_se_konsole_import_static_qt_plugins)
    if(NOT TARGET Qt6::Core OR NOT TARGET Qt6::Gui)
        message(FATAL_ERROR
            "static-everywhere: Qt6::Core and Qt6::Gui must exist before "
            "Konsole's static plugin hook runs")
    endif()
    get_target_property(_core_type Qt6::Core TYPE)
    if(_core_type STREQUAL "SHARED_LIBRARY")
        message(FATAL_ERROR
            "static-everywhere: Konsole was configured with shared Qt; the "
            "showcase requires Conan's static Qt graph")
    endif()

    set(_qt_prefix "${qt_PACKAGE_FOLDER_RELEASE}")
    if(NOT _qt_prefix)
        set(_qt_prefix "${Qt6_PACKAGE_FOLDER_RELEASE}")
    endif()
    if(NOT _qt_prefix OR _qt_prefix MATCHES "^/(usr|lib)(/|$)")
        message(FATAL_ERROR
            "static-everywhere: Qt6 package folder is not a non-host path: "
            "'${_qt_prefix}'")
    endif()

    set(_imports "")
    set(_libs "")
    foreach(_entry
            platforms/qxcb
            xcbglintegrations/qxcb-glx-integration
            xcbglintegrations/qxcb-egl-integration)
        get_filename_component(_dir "${_entry}" DIRECTORY)
        get_filename_component(_name "${_entry}" NAME)
        unset(_archive CACHE)
        unset(_archive)
        find_library(_archive NAMES "${_name}"
            PATHS "${_qt_prefix}/plugins/${_dir}" NO_DEFAULT_PATH)
        if(NOT _archive)
            message(FATAL_ERROR
                "static-everywhere: required Qt static plugin archive "
                "plugins/${_entry}/lib${_name}.a is missing")
        endif()
        if(NOT _archive MATCHES "\\.a$")
            message(FATAL_ERROR
                "static-everywhere: Qt plugin ${_entry} resolved to a shared "
                "object (${_archive}); the showcase requires static Qt")
        endif()
        _se_konsole_import_one("${_archive}" _imports _libs)
    endforeach()

    # Conan declares this component on some Qt versions. Keeping it in the
    # interface is harmless and preserves any dependency metadata the recipe
    # does know about, while the archive above guarantees the actual import.
    if(TARGET Qt6::QXcbIntegrationPlugin)
        list(APPEND _libs Qt6::QXcbIntegrationPlugin)
    endif()

    set(_generated "${CMAKE_BINARY_DIR}/static_everywhere_konsole_qt_plugins.cpp")
    file(GENERATE OUTPUT "${_generated}" CONTENT
        "// Generated by static-everywhere; do not edit.\n#include <QtPlugin>\n${_imports}")
    # The generated source is for executables only. Unrestricted
    # INTERFACE_SOURCES would put the registration unit into intermediate
    # static libraries and can create both duplicate registrations and a
    # CMake dependency cycle.
    set_property(TARGET Qt6::Gui APPEND PROPERTY INTERFACE_SOURCES
        "$<$<STREQUAL:$<TARGET_PROPERTY:TYPE>,EXECUTABLE>:${_generated}>")
    set_property(TARGET Qt6::Gui APPEND PROPERTY INTERFACE_LINK_LIBRARIES ${_libs})
    message(STATUS
        "static-everywhere: imported qxcb, qxcb-glx-integration and "
        "qxcb-egl-integration into Qt6::Gui")
endfunction()

cmake_language(DEFER DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
               CALL _se_konsole_import_static_qt_plugins)
