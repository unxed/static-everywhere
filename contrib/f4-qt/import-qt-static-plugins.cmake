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
# gif, ico, svg, svgicon -- image formats, and the reason they are here
# without a failure to point at. ZoinGallery's QtDecoder enumerates
# QImageReader::supportedImageFormats() and decodes whatever Qt reports
# (Decoders/QtDecoder.cpp:13). Without these archives Qt reports fewer
# formats, so f4 quietly stops opening GIF, ICO and SVG files. Nothing
# crashes, no test fails, and CI would never have told us -- for an image
# viewer that is a worse outcome than the abort that started this file.
# Waiting for a failure only works when there is going to be one.
#
# jpeg, png, webp, tiff and heif need nothing here: Qt builds jpeg and png
# into Qt6Gui when using system libraries (there is no qjpeg/qpng archive
# in the package at all), and the rest come from ZoinGallery's own
# decoders via libwebp/libtiff/libheif.
#
# sqlite and the TLS backends are deliberately left out: f4 has no
# QSqlDatabase use anywhere, and its only https strings are comments and
# a map URL handed to the desktop browser -- no QNetworkAccessManager, no
# QSslSocket. Both were checked in the sources rather than assumed.
#
# The full candidate set is 23 archives under the package's plugins/
# directory; these are the ones f4 can be shown to reach.
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

    # Image and icon formats, all declared by Conan as components.
    foreach(_p QSvgPlugin QSvgIconPlugin QGifPlugin QIcoPlugin)
        if(NOT TARGET Qt6::${_p})
            message(FATAL_ERROR
                "static-everywhere: Qt6::${_p} not found. Without it Qt drops "
                "the format from QImageReader::supportedImageFormats() and f4 "
                "silently stops opening those files -- there is no crash to "
                "notice, which is why this is fatal.")
        endif()
        # The Q_IMPORT_PLUGIN class name is the component name minus Qt6::.
        string(APPEND _imports "Q_IMPORT_PLUGIN(${_p})\n")
        list(APPEND _libs Qt6::${_p})
    endforeach()

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

    # QML module plugins. A static Qt needs these imported exactly as the
    # platform plugin does, and there are 54 archives under the package's
    # qml/ tree -- f4's own sources import 16 modules directly and pull
    # more transitively, so hand-listing them is not an option.
    #
    # Qt solves this with qt_import_qml_plugins(), which runs
    # qmlimportscanner and imports what it reports. That macro lives in
    # Qt6QmlMacros.cmake, which Conan's package does not ship -- but
    # qmlimportscanner itself IS in the package, so use Qt's own tool and
    # supply only the small part around it.
    #
    # This is the third instance of one seam: Qt6GuiPlugins.cmake missing
    # cost the platform plugins, the Qt6::Quick -> Qt6::OpenGL edge cost a
    # run, and Qt6QmlMacros.cmake missing costs this.
    find_program(_se_qmlscanner qmlimportscanner
        PATHS "${qt_PACKAGE_FOLDER_RELEASE}/libexec"
              "${Qt6_PACKAGE_FOLDER_RELEASE}/libexec"
        NO_DEFAULT_PATH)
    if(NOT _se_qmlscanner)
        message(FATAL_ERROR
            "static-everywhere: qmlimportscanner not found in the Qt package. "
            "Without it the QML module plugins cannot be determined, and a "
            "static build fails at runtime with 'QQmlApplicationEngine failed "
            "to load component'.")
    endif()

    set(_qml_roots "")
    foreach(_dir "${CMAKE_SOURCE_DIR}/qml"
                 "${CMAKE_SOURCE_DIR}/../../third_party/ZoinGallery")
        if(IS_DIRECTORY "${_dir}")
            list(APPEND _qml_roots -rootPath "${_dir}")
        endif()
    endforeach()
    if(NOT _qml_roots)
        message(FATAL_ERROR
            "static-everywhere: found no QML source directory to scan. The "
            "paths in contrib/f4-qt/import-qt-static-plugins.cmake are "
            "relative to f4's layout; if that moved, update them.")
    endif()

    execute_process(
        COMMAND "${_se_qmlscanner}" ${_qml_roots}
                -importPath "${qt_PACKAGE_FOLDER_RELEASE}/qml"
        OUTPUT_VARIABLE _scan_json
        ERROR_VARIABLE _scan_err
        RESULT_VARIABLE _scan_rc)
    if(NOT _scan_rc EQUAL 0)
        message(FATAL_ERROR
            "static-everywhere: qmlimportscanner failed (${_scan_rc}):\n${_scan_err}")
    endif()

    # Strictly parsed, and loud on anything unexpected. The JSON shape is
    # qmlimportscanner's own and could change between Qt versions; a
    # mismatch must stop here with the payload in hand, not resurface as a
    # runtime QML load error two hours later.
    string(JSON _n_imports ERROR_VARIABLE _json_err LENGTH "${_scan_json}")
    if(_json_err)
        message(FATAL_ERROR
            "static-everywhere: could not parse qmlimportscanner output "
            "(${_json_err}). Raw output follows:\n${_scan_json}")
    endif()
    set(_qml_plugin_count 0)
    set(_seen_classnames "")
    math(EXPR _last "${_n_imports} - 1")
    foreach(_i RANGE 0 ${_last})
        string(JSON _entry GET "${_scan_json}" ${_i})
        string(JSON _cls ERROR_VARIABLE _no_cls GET "${_entry}" classname)
        string(JSON _plug ERROR_VARIABLE _no_plug GET "${_entry}" plugin)
        string(JSON _path ERROR_VARIABLE _no_path GET "${_entry}" path)
        # Entries without a plugin are header-only modules; skip quietly.
        if(_no_cls OR _no_plug OR _no_path)
            continue()
        endif()
        # Only plugins that live in the Qt package. The scanner also
        # reports the tree's own modules (F4QtHost, ZoinGallery, ZGStyle,
        # QWindowKit); those are built and linked by this very build, and
        # their reported paths point at source or build directories where
        # no archive exists yet -- treating them like Qt's would abort
        # configure on a file that is not supposed to be there.
        string(FIND "${_path}" "${qt_PACKAGE_FOLDER_RELEASE}/qml" _in_qt)
        if(NOT _in_qt EQUAL 0)
            continue()
        endif()
        # The scanner can report one module several times (two root paths,
        # repeated imports). Q_IMPORT_PLUGIN expands to a definition, so a
        # duplicate is a redefinition error in the generated file, not a
        # harmless repeat.
        if("${_cls}" IN_LIST _seen_classnames)
            continue()
        endif()
        list(APPEND _seen_classnames "${_cls}")
        find_library(_se_qmlplug_${_plug} NAMES "${_plug}"
                     PATHS "${_path}" NO_DEFAULT_PATH)
        if(NOT _se_qmlplug_${_plug})
            message(FATAL_ERROR
                "static-everywhere: qmlimportscanner reports module plugin "
                "'${_plug}' in '${_path}' but no archive was found there. A "
                "missing QML plugin does not fail the link; it fails at "
                "startup with 'QQmlApplicationEngine failed to load "
                "component'.")
        endif()
        string(APPEND _imports "Q_IMPORT_PLUGIN(${_cls})\n")
        list(APPEND _libs "${_se_qmlplug_${_plug}}")
        math(EXPR _qml_plugin_count "${_qml_plugin_count} + 1")
    endforeach()

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
        "static-everywhere: imported static Qt plugins into Qt6::Gui's "
        "interface (xcb, offscreen, svg, svgicon, gif, ico, and "
        "${_qml_plugin_count} QML module plugins)")
endfunction()

cmake_language(DEFER DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
               CALL _static_everywhere_import_qt_plugins)
