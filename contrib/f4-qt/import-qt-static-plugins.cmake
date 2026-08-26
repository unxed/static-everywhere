# static-everywhere: import Qt's static platform plugins.
#
# Why this file exists
# --------------------
# With a static Qt, every test executable aborts before running a line of
# its own code:
#
#   qt.qpa.plugin: Could not find the Qt platform plugin "offscreen" in ""
#   This application failed to start because no Qt platform plugin could
#   be initialized.
#   11% tests passed, 8 tests failed out of 9
#
# A static build has no plugin .so files to discover at runtime. Qt's
# answer is Q_IMPORT_PLUGIN: a translation unit compiled into the
# executable that references the plugin's static registration, pulling the
# archive off the link line and registering it before main() runs. Qt's
# own CMake package does this automatically -- qt_import_plugins, driven
# by Qt6GuiPlugins.cmake, which every consumer of a static Qt6::Gui gets
# for free.
#
# Conan's CMakeDeps generator replaces Qt's package files with its own,
# and that machinery does not survive the substitution. This is the same
# root cause as the missing Qt6::Quick -> Qt6::OpenGL edge next door: not
# a Qt bug and not a Conan bug exactly, but a seam between them where
# something Qt's own CMake would have done for us silently stops
# happening. Shared builds never notice, because there the plugins are
# real .so files found through QT_PLUGIN_PATH.
#
# f4 itself does no plugin deployment under F4_PORTABLE_STATIC -- correctly,
# because with Qt's own CMake it would not have to.
#
# What is imported, and why only these
# ------------------------------------
# offscreen  -- f4's tests set QT_QPA_PLATFORM=offscreen (qt/host/
#               CMakeLists.txt:410) and so does the smoke step. This is
#               the plugin whose absence produced the failure above.
# xcb        -- what the application actually uses on a desktop. Without
#               it the binary builds and passes CI and then cannot open a
#               window on a user's machine, which is the worse failure of
#               the two because nothing catches it here.
#
# Image-format and style plugins (Svg, Gif, Ico, sqlite) are declared by
# Conan but deliberately NOT imported yet: nothing has failed for want of
# them, and importing plugins nobody needs makes the binary larger for no
# reason. The mechanism is in place, so adding one later is a line here
# rather than another investigation.
#
# Conan declares Qt6::QXcbIntegrationPlugin as a component but has no
# component for offscreen at all, even though libqoffscreen.a is right
# there in the package. So xcb comes from its target and offscreen is
# picked up from the package folder by hand; both are checked, and both
# fail loudly rather than silently producing a binary that cannot start.

if(NOT PROJECT_IS_TOP_LEVEL)
    return()
endif()

function(_static_everywhere_import_qt_plugins)
    if(NOT TARGET Qt6::Gui)
        message(FATAL_ERROR
            "static-everywhere: Qt6::Gui does not exist at the end of the "
            "top-level directory scope. This injection (see "
            "contrib/f4-qt/import-qt-static-plugins.cmake) attaches static "
            "plugin imports to Qt6::Gui's interface so every consumer gets "
            "them. If the component was renamed, update this file -- a "
            "static Qt cannot start without an imported platform plugin.")
    endif()

    # Shared Qt finds its plugins at runtime and needs none of this.
    get_target_property(_qt_core_type Qt6::Core TYPE)
    if(_qt_core_type STREQUAL "SHARED_LIBRARY")
        message(STATUS
            "static-everywhere: Qt is shared, skipping static plugin import")
        return()
    endif()

    set(_imports "")
    set(_libs "")

    # xcb: declared by Conan as a component target.
    if(TARGET Qt6::QXcbIntegrationPlugin)
        string(APPEND _imports "Q_IMPORT_PLUGIN(QXcbIntegrationPlugin)\n")
        list(APPEND _libs Qt6::QXcbIntegrationPlugin)
    else()
        message(FATAL_ERROR
            "static-everywhere: Qt6::QXcbIntegrationPlugin not found. Without "
            "it the binary links and passes CI and then cannot open a window "
            "on a desktop, which is why this is fatal rather than a warning.")
    endif()

    # offscreen: no Conan component exists, so take the archive directly.
    find_library(_se_qoffscreen
        NAMES qoffscreen
        PATHS "${qt_PACKAGE_FOLDER_RELEASE}/plugins/platforms"
              "${Qt6_PACKAGE_FOLDER_RELEASE}/plugins/platforms"
        NO_DEFAULT_PATH)
    if(NOT _se_qoffscreen)
        message(FATAL_ERROR
            "static-everywhere: libqoffscreen.a not found in the Qt package. "
            "f4's tests and the smoke step both set QT_QPA_PLATFORM=offscreen, "
            "so without it every GUI test aborts before running. Conan ships "
            "the archive but declares no component for it; if that changed, "
            "prefer the component and simplify this file.")
    endif()
    string(APPEND _imports "Q_IMPORT_PLUGIN(QOffscreenIntegrationPlugin)\n")
    list(APPEND _libs "${_se_qoffscreen}")

    set(_gen "${CMAKE_BINARY_DIR}/static_everywhere_qt_plugin_import.cpp")
    file(GENERATE OUTPUT "${_gen}" CONTENT
"// Generated by contrib/f4-qt/import-qt-static-plugins.cpp -- do not edit.
#include <QtPlugin>
${_imports}")

    # INTERFACE_SOURCES is how Qt's own qt_import_plugins does this: the
    # translation unit is compiled into every consumer of Qt6::Gui, which
    # is what makes the registration run in tests, in the app, and in
    # anything added later. Verified separately that a source attached to
    # an imported target's interface does reach two distinct consumers.
    set_property(TARGET Qt6::Gui APPEND PROPERTY INTERFACE_SOURCES "${_gen}")
    set_property(TARGET Qt6::Gui APPEND PROPERTY INTERFACE_LINK_LIBRARIES ${_libs})

    message(STATUS
        "static-everywhere: imported static Qt platform plugins "
        "(xcb, offscreen) into Qt6::Gui's interface")
endfunction()

cmake_language(DEFER DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
               CALL _static_everywhere_import_qt_plugins)
