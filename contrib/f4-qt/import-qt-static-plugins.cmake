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

# The dependency closure Qt records next to every static archive.
# `required` distinguishes the two callers, and the distinction is real
# rather than cosmetic. For a plugin being imported, a missing .prl means
# its backing library and resources will not be linked and the build dies
# on qInitResources_* -- fatal. For the bulk declaration of module
# archives, plenty of Qt libraries ship no .prl at all, and demanding one
# aborts configure over nothing.
function(_se_prl_closure archive out_var required)
    set(_out "")
    get_filename_component(_dir "${archive}" DIRECTORY)
    get_filename_component(_base "${archive}" NAME_WE)
    set(_prl "${_dir}/${_base}.prl")
    if(NOT EXISTS "${_prl}" AND NOT required)
        set(${out_var} "" PARENT_SCOPE)
        return()
    endif()
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
        # Qt writes install locations as $$[QT_INSTALL_*] tokens. The
        # first version of this substituted three of them BY NAME, which
        # is the same derive-instead-of-read mistake in another costume:
        # QT_INSTALL_PREFIX was not on the list, sailed through
        # unresolved, and 190 link errors later ld.lld was trying to open
        # files literally named `$[QT_INSTALL_PREFIX]/lib/...`.
        #
        # Now every token of the kind is mapped, and -- the part that
        # matters -- anything left matching $$[...] afterwards is FATAL.
        # An unknown token can no longer pass through silently; it stops
        # here with its own name printed.
        set(_qt_pfx "${qt_PACKAGE_FOLDER_RELEASE}")
        string(REPLACE "$$[QT_INSTALL_PREFIX]"     "${_qt_pfx}"          _prl_libs "${_prl_libs}")
        string(REPLACE "$$[QT_INSTALL_LIBS]"       "${_qt_pfx}/lib"      _prl_libs "${_prl_libs}")
        string(REPLACE "$$[QT_INSTALL_PLUGINS]"    "${_qt_pfx}/plugins"  _prl_libs "${_prl_libs}")
        string(REPLACE "$$[QT_INSTALL_QML]"        "${_qt_pfx}/qml"      _prl_libs "${_prl_libs}")
        string(REPLACE "$$[QT_INSTALL_ARCHDATA]"   "${_qt_pfx}"          _prl_libs "${_prl_libs}")
        string(REPLACE "$$[QT_INSTALL_DATA]"       "${_qt_pfx}"          _prl_libs "${_prl_libs}")
        string(REPLACE "$$[QT_INSTALL_BINS]"       "${_qt_pfx}/bin"      _prl_libs "${_prl_libs}")
        string(REPLACE "$$[QT_INSTALL_LIBEXECS]"   "${_qt_pfx}/libexec"  _prl_libs "${_prl_libs}")
        if(_prl_libs MATCHES "\\$\\$\\[([A-Z_]+)\\]")
            message(FATAL_ERROR
                "static-everywhere: ${_prl} contains an unhandled qmake "
                "token $$[${CMAKE_MATCH_1}]. Add it to the mapping in "
                "contrib/f4-qt/import-qt-static-plugins.cmake -- left "
                "unresolved it reaches the linker verbatim and produces "
                "'cannot open $[${CMAKE_MATCH_1}]/...' by the hundred.")
        endif()
        # Any stale absolute prefix from the machine that built the
        # package is remapped the same way.
        string(REGEX REPLACE "/[^ ;]*/p/lib/" "${_qt_pfx}/lib/" _prl_libs "${_prl_libs}")
        separate_arguments(_prl_items UNIX_COMMAND "${_prl_libs}")
        # Three kinds of token live in a Conan-built Qt's QMAKE_PRL_LIBS,
        # and only two of them are for us. Qt's own archives arrive as
        # $$[QT_INSTALL_*] paths (resolved above); system libraries as
        # plain -lGL/-lm (fine as-is); and then Conan's toolchain leaks
        # its build-time target names into qmake's link line --
        # `-lCONAN_LIB::double-conversion_double-conversion_RELEASE` and
        # kin. CMake treats any `::` token in a link interface as a
        # target and stops the generate step on the first one it cannot
        # find, which is how run 2026-08-26/night2 died.
        #
        # Dropping them is correct, not merely convenient: every
        # executable here already links the full Qt component set, whose
        # Conan dependencies carry those very libraries; the .prl entries
        # record what Qt's *own* build linked, and for third-party deps
        # that information is redundant on our side of the seam. If one
        # ever were genuinely missing, the link would fail loudly on an
        # undefined symbol -- unlike this, which failed on bookkeeping.
        foreach(_it IN LISTS _prl_items)
            string(REGEX REPLACE "^-l" "" _bare "${_it}")
            if(_bare MATCHES "::")
                if(TARGET "${_bare}")
                    list(APPEND _out "${_bare}")
                endif()
                continue()
            endif()
            # Existence gate. Conan's recipe does not ship Qt's
            # objects-Release/ trees (zero entries in the package), yet
            # the .prl files reference resource object files inside them.
            # A path that does not exist is a hard `cannot open` from
            # ld.lld -- it cannot be recovered from and says nothing
            # useful. Dropping it either works, or fails loudly later on
            # an undefined symbol, which is the diagnosable failure.
            if(_it MATCHES "^/" AND NOT EXISTS "${_it}")
                continue()
            endif()
            list(APPEND _out "${_it}")
        endforeach()
    endif()

    set(${out_var} ${_out} PARENT_SCOPE)
endfunction()

# The plugin class name, read out of the archive itself. The defining
# symbol is a mangled C++ function _Z<len>qt_static_plugin_<Class>v, and
# the Itanium length prefix makes extraction exact. `required` mirrors
# _se_prl_closure: fatal when importing a plugin, tolerant when sweeping
# a directory where not every archive is a plugin.
function(_se_plugin_class archive out_var required)
    # The defining symbol is a mangled C++ function,
    # _Z<len>qt_static_plugin_<Class>v, and the Itanium length prefix is
    # what makes extraction exact: a greedy [A-Za-z0-9_]+ would swallow
    # the trailing mangling and yield "<Class>v" -- the mock's first run
    # produced exactly that off-by-suffix, which is the same family of
    # mistake as deriving QIcoPlugin from a component name.
    file(STRINGS "${archive}" _syms REGEX "_Z[0-9]+qt_static_plugin_")
    string(REGEX MATCH "_Z([0-9]+)qt_static_plugin_" _m "${_syms}")
    if(NOT _m)
        if(NOT required)
            set(${out_var} "" PARENT_SCOPE)
            return()
        endif()
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

    set(${out_var} "${_cls}" PARENT_SCOPE)
endfunction()

function(_se_import_plugin_archive archive imports_var libs_var)
    _se_plugin_class("${archive}" _cls TRUE)

    set(_new_imports "Q_IMPORT_PLUGIN(${_cls})\n")
    set(_new_libs "${archive}")

    _se_prl_closure("${archive}" _prl_closure TRUE)
    list(APPEND _new_libs ${_prl_closure})

    set(${imports_var} "${${imports_var}}${_new_imports}" PARENT_SCOPE)
    set(${libs_var} ${${libs_var}} ${_new_libs} PARENT_SCOPE)
endfunction()


# Declare the Qt6::<name> targets Qt's own package files reference and
# Conan's generated ones do not.
#
# Qt records, for every QML module, the link target its plugin defines.
# qt6_import_qml_plugins looks that target up and -- if it is absent --
# warns and moves on, which is how a build links cleanly and then reports
# `module "QtQuick" is not installed` at runtime. Conan's CMakeDeps
# publishes its own component set instead of Qt's, so 31 of these were
# missing in one run.
#
# Rather than guess the names, take them from what is on disk: every
# plugin archive under qml/, and every Qt module archive under lib/. Both
# spellings are declared, because Qt asks for a module by its lowercase
# name (Qt6::quicktooling) while the archive is CamelCase
# (libQt6QuickTooling.a). Each target carries its .prl closure through the
# same parser used everywhere else in this file, so a plugin's backing
# library and resources come with it.
#
# Existing targets are never touched: where Conan already declares a
# component, Conan's version wins.
function(_se_declare_missing_qt_targets)
    set(_declared 0)
    file(GLOB_RECURSE _qml_archives
         "${qt_PACKAGE_FOLDER_RELEASE}/qml/*.a")
    file(GLOB _lib_archives
         "${qt_PACKAGE_FOLDER_RELEASE}/lib/libQt6*.a")
    foreach(_a IN LISTS _qml_archives _lib_archives)
        get_filename_component(_base "${_a}" NAME_WE)
        string(REGEX REPLACE "^lib" "" _base "${_base}")
        set(_names "${_base}")
        # libQt6QuickTooling.a -> QuickTooling and quicktooling
        string(REGEX REPLACE "^Qt6" "" _mod "${_base}")
        if(NOT _mod STREQUAL _base)
            string(TOLOWER "${_mod}" _mod_lower)
            list(APPEND _names "${_mod}" "${_mod_lower}")
        endif()
        string(TOLOWER "${_base}" _base_lower)
        list(APPEND _names "${_base_lower}")
        list(REMOVE_DUPLICATES _names)

        set(_closure "")
        foreach(_n IN LISTS _names)
            if(TARGET "Qt6::${_n}")
                continue()
            endif()
            if(NOT _closure)
                _se_prl_closure("${_a}" _closure FALSE)
            endif()
            add_library("Qt6::${_n}" STATIC IMPORTED)
            set_target_properties("Qt6::${_n}" PROPERTIES
                IMPORTED_LOCATION "${_a}")
            # Run night#6: with the targets declared, Qt linked the
            # archives -- and QML still said `plugin "qtquick2plugin"
            # not found` at runtime. Linking is only half of what
            # qt6_import_qml_plugins does; the other half is emitting
            # Q_IMPORT_PLUGIN(<class>) into a generated unit, and the
            # class comes from the target's QT_PLUGIN_CLASS_NAME. A
            # target without it is linked and silently never registered,
            # so the plugin's archive is in the binary while its static
            # instance does not exist. The class is read from the
            # archive's own mangled symbol, tolerant here because module
            # libraries under lib/ legitimately have none.
            _se_plugin_class("${_a}" _pcls FALSE)
            if(_pcls)
                set_property(TARGET "Qt6::${_n}" PROPERTY
                             QT_PLUGIN_CLASS_NAME "${_pcls}")
            endif()
            if(_closure)
                set_property(TARGET "Qt6::${_n}" PROPERTY
                             INTERFACE_LINK_LIBRARIES ${_closure})
            endif()
            math(EXPR _declared "${_declared} + 1")
        endforeach()
    endforeach()
    message(STATUS
        "static-everywhere: declared ${_declared} Qt6::* targets Conan's "
        "generator omits, so Qt's own qt6_import_qml_plugins can link them")
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

        # Everything QML is Qt's own job, and it does it: the package ships
    # Qt6QmlMacros.cmake, and qt6_import_qml_plugins runs automatically
    # from _qt_internal_finalize_executable for every executable.
    #
    # An earlier version of this file reimplemented that -- driving
    # qmlimportscanner by hand and registering the tree's own module
    # plugins -- on the belief that Conan had dropped Qt's machinery.
    # That belief came from grepping the diagnostic artifact's package
    # listing, which the collector deliberately prunes of */lib/cmake/*.
    # Absence from the listing was read as absence from the package. The
    # reimplementation duplicated Qt's work and then failed on its own
    # terms, trying to link a MODULE_LIBRARY into an executable.
    #
    # What Qt's machinery cannot do by itself is the one thing left here:
    # it skips any plugin whose Qt6::<name> link target does not exist,
    # and says so 31 times before carrying on --
    #
    #   The qml plugin 'qtquick2plugin' is a dependency of 'f4-qt-host',
    #   but the link target it defines (Qt6::qtquick2plugin) does not
    #   exist in the current scope. The plugin will not be linked.
    #
    # -- because Conan's CMakeDeps declares its own component set and not
    # the per-plugin targets Qt's own package files reference. So supply
    # the targets and let Qt do the importing.
    _se_declare_missing_qt_targets()

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
        "interface (xcb, offscreen, svg, svgicon, gif, ico, "
        "${_qml_plugin_count} QML module plugins from the Qt package, and "
        "in-tree plugins: ${_intree_plugins})")
endfunction()

cmake_language(DEFER DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
               CALL _static_everywhere_import_qt_plugins)
