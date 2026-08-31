# static-everywhere: the one CMAKE_PROJECT_INCLUDE hook for Konsole.
#
# Conan's CMakeToolchain publishes dependency `builddirs` in
# CMAKE_MODULE_PATH. Those entries are package-specific directories such as
# `<prefix>/lib/cmake/Qt6Core`; CMake's CONFIG-mode find_package does not use
# CMAKE_MODULE_PATH to locate a package config file. Promote the owning
# prefixes before any framework's CMakeLists.txt calls find_package(), so
# standalone package names work for the whole KDE dependency graph rather than
# requiring a new per-package *_DIR workaround after every CI failure.
function(_se_promote_conan_package_prefixes)
    set(_prefixes)
    foreach(_module_path IN LISTS CMAKE_MODULE_PATH)
        if(IS_ABSOLUTE "${_module_path}" AND
           "${_module_path}" MATCHES "^(.+)/lib(64)?/cmake/[^/]+/?$")
            set(_prefix "${CMAKE_MATCH_1}")
            if(NOT _prefix MATCHES "^/(usr|lib)(/|$)")
                list(APPEND _prefixes "${_prefix}")
            endif()
        endif()
    endforeach()
    list(REMOVE_DUPLICATES _prefixes)
    if(_prefixes)
        list(PREPEND CMAKE_PREFIX_PATH ${_prefixes})
        set(CMAKE_PREFIX_PATH "${CMAKE_PREFIX_PATH}" PARENT_SCOPE)
        message(STATUS
                "static-everywhere: promoted Conan package prefixes for CONFIG lookup: "
                "${_prefixes}")
    endif()
endfunction()

_se_promote_conan_package_prefixes()

if(NOT PROJECT_IS_TOP_LEVEL)
    return()
endif()

if(NOT PROJECT_NAME STREQUAL "konsole")
    return()
endif()

get_filename_component(_SE_REPO_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
include("${CMAKE_CURRENT_LIST_DIR}/import-static-qt-plugins.cmake")

# This is deliberately the f4 implementation, not a new GL policy. It
# removes libGL from DT_NEEDED and loads the host OpenGL implementation at
# runtime; X11 remains a normal host dependency. Widgets does not use the
# Quick fallback path, but the constructor is harmless and keeps the same
# host-OpenGL behavior as the reference recipe.
include("${_SE_REPO_ROOT}/contrib/f4-qt/optional-gl.cmake")

function(_se_konsole_assert_static_graph)
    set(_qt_components Core Gui Multimedia PrintSupport Widgets Xml)
    foreach(_component IN LISTS _qt_components)
        if(TARGET "Qt6::${_component}")
            get_target_property(_type "Qt6::${_component}" TYPE)
            if(NOT _type STREQUAL "STATIC_LIBRARY" AND
               NOT _type STREQUAL "INTERFACE_LIBRARY" AND
               NOT _type STREQUAL "OBJECT_LIBRARY")
                message(FATAL_ERROR
                    "static-everywhere: Qt6::${_component} is ${_type}; "
                    "host/shared Qt is forbidden")
            endif()
        endif()
    endforeach()

    set(_kf_components Bookmarks BookmarksWidgets ConfigCore ConfigWidgets
        CoreAddons Crash GuiAddons I18n IconThemes IconWidgets KIOWidgets
        NewStuffCore NewStuffWidgets Notifications NotifyConfig Parts Pty
        Service TextWidgets WindowSystem XmlGui)
    foreach(_component IN LISTS _kf_components)
        if(TARGET "KF6::${_component}")
            get_target_property(_type "KF6::${_component}" TYPE)
            if(NOT _type STREQUAL "STATIC_LIBRARY" AND
               NOT _type STREQUAL "INTERFACE_LIBRARY" AND
               NOT _type STREQUAL "OBJECT_LIBRARY")
                message(FATAL_ERROR
                    "static-everywhere: KF6::${_component} is ${_type}; "
                    "host/shared KDE Frameworks are forbidden")
            endif()
        endif()
    endforeach()

    foreach(_target Qt6::Core Qt6::Gui Qt6::Multimedia Qt6::PrintSupport
                    Qt6::Widgets KF6::CoreAddons KF6::ConfigCore KF6::I18n
                    KF6::KIOCore KF6::KIOWidgets KF6::WindowSystem)
        if(TARGET "${_target}")
            foreach(_location_property IMPORTED_LOCATION_RELEASE IMPORTED_LOCATION)
                get_target_property(_location "${_target}" "${_location_property}")
                if(_location AND "${_location}" MATCHES "^/(usr|lib)(/|$)")
                    message(FATAL_ERROR
                        "static-everywhere: ${_target} imports a host library "
                        "from ${_location}")
                endif()
            endforeach()
        endif()
    endforeach()

    foreach(_var Qt6_DIR ECM_DIR KF6_DIR KF6Config_DIR KF6CoreAddons_DIR
                    KF6I18n_DIR KF6KIO_DIR ICU_DIR)
        if(DEFINED ${_var} AND "${${_var}}" MATCHES "^/(usr|lib)(/|$)")
            message(FATAL_ERROR
                "static-everywhere: ${_var} resolves to the host path "
                "${${_var}}")
        endif()
    endforeach()
    message(STATUS "static-everywhere: Qt/KF6 graph is non-host and static")
endfunction()

cmake_language(DEFER DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
               CALL _se_konsole_assert_static_graph)
