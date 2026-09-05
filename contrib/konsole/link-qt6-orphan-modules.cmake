# static-everywhere: repair the Qt inter-module edges the Conan recipe
# omits, for a static link.
#
# Why this file exists
# --------------------
# A static link needs every archive a module's code references on the
# line. Conan's qt recipe declares each component's requirements by hand,
# and the list lags Qt: Quick needs OpenGL (fixed earlier in
# contrib/f4-qt/link-qt6-opengl.cmake, from a link error), and
# tools/scan-qt-module-edges.sh -- which reads Qt's own module
# declarations and the recipe -- then found the rest before a build:
#
#   Quick      -> QmlMeta      (Conan builds libQt6QmlMeta.a, exposes no target)
#   Multimedia -> Concurrent   (component exists, edge missing)
#   Multimedia -> DBus         (component exists, edge missing)
#
# konsole links Qt6::Quick (via KF6) and Qt6::Multimedia directly, and
# konsolepart.so links with --no-undefined, so each of these is a set of
# undefined symbols. The table below is what the scan reports; the scan
# reads this file back and fails if Qt declares an edge neither Conan nor
# this table covers, so the two cannot drift apart.
#
# Modules Conan never exposes get an imported target created here from
# the archive in the Qt package folder, if it exists. Missing archive ->
# no target -> the scan's next run says so; nothing is guessed.

function(_se_repair_qt_edges)
    if(NOT TARGET Qt6::Core)
        return()
    endif()

    # Where the Qt package lives: from the Core target's imported location.
    get_target_property(_core Qt6::Core IMPORTED_LOCATION_RELEASE)
    if(NOT _core)
        get_target_property(_core Qt6::Core IMPORTED_LOCATION)
    endif()
    if(NOT _core)
        message(STATUS "static-everywhere: Qt6::Core has no imported location; cannot locate orphan Qt archives")
        return()
    endif()
    get_filename_component(_qt_lib "${_core}" DIRECTORY)

    # Orphan modules: built by Conan, never exposed as a component.
    foreach(_orphan QmlMeta)
        if(NOT TARGET Qt6::${_orphan})
            if(EXISTS "${_qt_lib}/libQt6${_orphan}.a")
                add_library(Qt6::${_orphan} STATIC IMPORTED)
                set_target_properties(Qt6::${_orphan} PROPERTIES
                    IMPORTED_LOCATION "${_qt_lib}/libQt6${_orphan}.a")
                message(STATUS "static-everywhere: created Qt6::${_orphan} from ${_qt_lib}/libQt6${_orphan}.a (Conan exposes no component for it)")
            else()
                message(STATUS "static-everywhere: libQt6${_orphan}.a not found in ${_qt_lib}; Qt6::${_orphan} not created")
            endif()
        endif()
    endforeach()

    # Edges: consumer -> dependency, appended to the consumer's link interface.
    set(_edges
        "Quick|QmlMeta"
        "QmlMeta|Qml"
        "QmlMeta|QmlModels"
        "Multimedia|Concurrent"
        "Multimedia|DBus")
    foreach(_edge IN LISTS _edges)
        string(REPLACE "|" ";" _pair "${_edge}")
        list(GET _pair 0 _from)
        list(GET _pair 1 _to)
        if(TARGET Qt6::${_from} AND TARGET Qt6::${_to})
            get_target_property(_links Qt6::${_from} INTERFACE_LINK_LIBRARIES)
            if(NOT _links)
                set(_links "")
            endif()
            if(NOT "Qt6::${_to}" IN_LIST _links)
                set_property(TARGET Qt6::${_from} APPEND PROPERTY
                    INTERFACE_LINK_LIBRARIES "Qt6::${_to}")
                message(STATUS "static-everywhere: added Qt6::${_to} to Qt6::${_from}'s link interface (edge the Conan qt recipe omits)")
            endif()
        endif()
    endforeach()
endfunction()

if(PROJECT_IS_TOP_LEVEL)
    cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL _se_repair_qt_edges)
endif()
