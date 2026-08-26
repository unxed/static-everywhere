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


# One plugin archive, imported from Qt's own metadata -- nothing derived.
#
# Two guesses of mine failed in real runs, one per source of truth this
# helper now replaces them with:
#
#   - The Q_IMPORT_PLUGIN class was derived from Conan's component name,
#     and Qt6::QIcoPlugin's real class is QICOPlugin -- the link died on
#     qt_static_plugin_QIcoPlugin(). The archive itself exports exactly
#     one qt_static_plugin_<Class> symbol; file(STRINGS) reads it out of
#     the binary, so the name cannot be wrong.
#   - The archive was treated as a leaf, and it is not: a QML plugin
#     references its module's backing library (where this Qt build also
#     compiled the module's resources -- qInitResources_* lives there,
#     and no separate resource objects exist anywhere in the package).
#     Qt ships the full closure next to every plugin in its .prl file;
#     parse that instead of hand-wiring dependencies.
function(_se_import_plugin_archive archive imports_var libs_var)
    # The defining symbol is a mangled C++ function,
    # _Z<len>qt_static_plugin_<Class>v, and the Itanium length prefix is
    # what makes extraction exact: a greedy [A-Za-z0-9_]+ would swallow
    # the trailing mangling and yield "<Class>v" -- the mock's first run
    # produced exactly that off-by-suffix, which is the same family of
    # mistake as deriving QIcoPlugin from a component name.
    file(STRINGS "${archive}" _syms REGEX "_Z[0-9]+qt_static_plugin_")
    string(REGEX MATCH "_Z([0-9]+)qt_static_plugin_" _m "${_syms}")
    if(NOT _m)
        message(FATAL_ERROR
            "static-everywhere: no mangled qt_static_plugin_<Class> symbol "
            "in ${archive}. Without it Q_IMPORT_PLUGIN cannot reference the "
            "plugin, so this is not a Qt static plugin archive at all.")
    endif()
    set(_len "${CMAKE_MATCH_1}")
    string(FIND "${_syms}" "${_m}" _at)
    string(LENGTH "_Z${_len}" _pfx)
    math(EXPR _at "${_at} + ${_pfx}")
    string(SUBSTRING "${_syms}" ${_at} ${_len} _full)
    string(REPLACE "qt_static_plugin_" "" _cls "${_full}")
    if(NOT _cls MATCHES "^[A-Za-z_][A-Za-z0-9_]*$")
        message(FATAL_ERROR
            "static-everywhere: extracted plugin class '${_cls}' from "
            "${archive} is not an identifier -- the symbol parse went wrong; "
            "raw match context: ${_syms}")
    endif()

    set(_new_imports "Q_IMPORT_PLUGIN(${_cls})\n")
    set(_new_libs "${archive}")

    get_filename_component(_dir "${archive}" DIRECTORY)
    get_filename_component(_base "${archive}" NAME_WE)
    set(_prl "${_dir}/${_base}.prl")
    if(NOT EXISTS "${_prl}")
        message(FATAL_ERROR
            "static-everywhere: ${_prl} not found. Qt records every static "
            "plugin's dependency closure in its .prl; without it the plugin "
            "links but its module's backing library does not, and the build "
            "dies on qInitResources_* exactly as run 2026-08-26 did.")
    endif()
    file(STRINGS "${_prl}" _prl_libs REGEX "^QMAKE_PRL_LIBS[ \t]*=")
    if(_prl_libs)
        string(REGEX REPLACE "^QMAKE_PRL_LIBS[ \t]*=[ \t]*" "" _prl_libs "${_prl_libs}")
        # Qt writes install locations as $$[QT_INSTALL_*] tokens; resolve
        # them against this package. Any stale absolute prefix from the
        # machine that built the package is remapped the same way.
        string(REPLACE "$$[QT_INSTALL_LIBS]" "${qt_PACKAGE_FOLDER_RELEASE}/lib" _prl_libs "${_prl_libs}")
        string(REPLACE "$$[QT_INSTALL_PLUGINS]" "${qt_PACKAGE_FOLDER_RELEASE}/plugins" _prl_libs "${_prl_libs}")
        string(REPLACE "$$[QT_INSTALL_QML]" "${qt_PACKAGE_FOLDER_RELEASE}/qml" _prl_libs "${_prl_libs}")
        string(REGEX REPLACE "/[^ ;]*/p/lib/" "${qt_PACKAGE_FOLDER_RELEASE}/lib/" _prl_libs "${_prl_libs}")
        separate_arguments(_prl_items UNIX_COMMAND "${_prl_libs}")
        list(APPEND _new_libs ${_prl_items})
    endif()

    set(${imports_var} "${${imports_var}}${_new_imports}" PARENT_SCOPE)
    set(${libs_var} ${${libs_var}} ${_new_libs} PARENT_SCOPE)
endfunction()

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

    # Platform and image-format plugins, uniformly through the helper.
    # xcb keeps its Conan component on the link line as well: the
    # component carries the XcbQpa dependency closure Conan knows about,
    # and linking both the archive and the component is harmless.
    foreach(_pl platforms/qxcb platforms/qoffscreen
                imageformats/qsvg imageformats/qgif imageformats/qico
                iconengines/qsvgicon)
        get_filename_component(_pl_dir "${_pl}" DIRECTORY)
        get_filename_component(_pl_name "${_pl}" NAME)
        find_library(_se_plug_${_pl_name} NAMES "${_pl_name}"
            PATHS "${qt_PACKAGE_FOLDER_RELEASE}/plugins/${_pl_dir}"
                  "${Qt6_PACKAGE_FOLDER_RELEASE}/plugins/${_pl_dir}"
            NO_DEFAULT_PATH)
        if(NOT _se_plug_${_pl_name})
            message(FATAL_ERROR
                "static-everywhere: plugins/${_pl_dir}/lib${_pl_name}.a not "
                "found in the Qt package. Each of these is load-bearing: the "
                "platform plugins are what lets a static Qt start at all, and "
                "the image plugins are formats ZoinGallery's QtDecoder "
                "silently loses without them.")
        endif()
        _se_import_plugin_archive("${_se_plug_${_pl_name}}" _imports _libs)
    endforeach()
    if(TARGET Qt6::QXcbIntegrationPlugin)
        list(APPEND _libs Qt6::QXcbIntegrationPlugin)
    endif()

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
        # harmless repeat. The scanner's classname is used only for this
        # dedup key; the imported name comes from the archive itself.
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
        _se_import_plugin_archive("${_se_qmlplug_${_plug}}" _imports _libs)
        math(EXPR _qml_plugin_count "${_qml_plugin_count} + 1")
    endforeach()

    set(_gen "${CMAKE_BINARY_DIR}/static_everywhere_qt_plugin_import.cpp")
    file(GENERATE OUTPUT "${_gen}" CONTENT
"// Generated by contrib/f4-qt/import-qt-static-plugins.cpp -- do not edit.
#include <QtPlugin>
${_imports}")

    # INTERFACE_SOURCES is how Qt's own machinery does this -- but only
    # half of it, and the other half is not optional. Qt wraps the entry
    # in a generator expression restricting it to EXECUTABLE targets, and
    # a real run showed why. Unrestricted, the unit compiled into
    # ZoinGalleryCore.a -- a static library between Qt6::Gui and the
    # executables -- and ninja stopped on a dependency cycle: the library
    # owns an object of the generated file, the generated file's ordering
    # ties to the autogen timestamps of the test targets, and the tests
    # link the library. Even without AUTOMOC in the loop it would be
    # wrong: an executable and a pulled archive member each carrying the
    # same registration object is a duplicate definition at link.
    # Executables are where plugin registration belongs, and they are the
    # only place Qt itself puts it.
    set_property(TARGET Qt6::Gui APPEND PROPERTY INTERFACE_SOURCES
        "$<$<STREQUAL:$<TARGET_PROPERTY:TYPE>,EXECUTABLE>:${_gen}>")
    set_property(TARGET Qt6::Gui APPEND PROPERTY INTERFACE_LINK_LIBRARIES ${_libs})

    message(STATUS
        "static-everywhere: imported static Qt plugins into Qt6::Gui's "
        "interface (xcb, offscreen, svg, svgicon, gif, ico, and "
        "${_qml_plugin_count} QML module plugins)")
endfunction()

cmake_language(DEFER DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
               CALL _static_everywhere_import_qt_plugins)
