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

# Some Conan packages publish a CONFIG-mode replacement for a CMake package
# that upstream frameworks normally find through a MODULE.  The replacement
# can provide the library target while omitting companion host tools that the
# upstream Find module exposes (for example LibXml2::xmllint).  Seed those
# tools from the host before any package CONFIG/MODULE lookup.  Keep the
# lookup generic so another host tool can be added here without changing every
# framework recipe that consumes it.
function(_se_seed_host_tool variable)
    string(MAKE_C_IDENTIFIER "${variable}" _cache_suffix)
    set(_cache_variable "_SE_HOST_TOOL_${_cache_suffix}")
    find_program(${_cache_variable} NAMES ${ARGN}
                 PATHS /usr/bin /bin
                 NO_DEFAULT_PATH)
    if(DEFINED ${_cache_variable} AND
       NOT "${${_cache_variable}}" STREQUAL "${_cache_variable}-NOTFOUND")
        set(${variable} "${${_cache_variable}}" PARENT_SCOPE)
    endif()
endfunction()

if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    # LibXml2/LibXslt are host-side inputs to kdoctools' DocBook generators.
    # Their CMake CONFIG packages do not consistently carry the executable
    # variables supplied by CMake's FindLibXml2/FindLibXslt modules.
    _se_seed_host_tool(LIBXML2_XMLLINT_EXECUTABLE xmllint)
    if(DEFINED LIBXML2_XMLLINT_EXECUTABLE)
        set(XMLLINT_EXECUTABLE "${LIBXML2_XMLLINT_EXECUTABLE}")
    endif()
    _se_seed_host_tool(LIBXSLT_XSLTPROC_EXECUTABLE xsltproc)
endif()

# zig-cc identifies itself to CMake as Clang, but its compatibility target
# flags make CMake's compiler ABI probe fail. CMake then overwrites the
# target metadata that the Conan toolchain supplied with empty values in
# CMakeFiles/<version>/CMake{,CXX}Compiler.cmake. That is not cosmetic:
# find_library() uses CMAKE_LIBRARY_ARCHITECTURE to find Debian/Ubuntu's
# multiarch libraries, and the implicit include list keeps a host header
# from shadowing a vendored dependency. Restore the fixed target contract
# after project() has loaded the compiler files and before the project's
# find_package() calls run. This must be before the top-level Konsole guard:
# CMAKE_PROJECT_INCLUDE also runs for each KDE framework project.
# The condition leaves native compiler metadata untouched and is intentionally
# limited to this recipe's x86_64 Linux target.
if(CMAKE_SYSTEM_NAME STREQUAL "Linux" AND
   CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|amd64)$")
    if(NOT CMAKE_SIZEOF_VOID_P)
        set(CMAKE_SIZEOF_VOID_P 8)
    endif()
    if(NOT CMAKE_LIBRARY_ARCHITECTURE)
        set(CMAKE_LIBRARY_ARCHITECTURE "x86_64-linux-gnu")
    endif()
    if(NOT CMAKE_C_IMPLICIT_INCLUDE_DIRECTORIES)
        set(CMAKE_C_IMPLICIT_INCLUDE_DIRECTORIES "/usr/include")
    endif()
    if(NOT CMAKE_CXX_IMPLICIT_INCLUDE_DIRECTORIES)
        set(CMAKE_CXX_IMPLICIT_INCLUDE_DIRECTORIES "/usr/include")
    endif()
endif()

_se_promote_conan_package_prefixes()

# Declare /usr/include implicit -- as a NORMAL variable, here, after
# project(). The -D form in cmake-options sets only the cache, and
# CMakeCXXCompiler.cmake (CMake cannot introspect zig-c++) then runs
# `set(CMAKE_CXX_IMPLICIT_INCLUDE_DIRECTORIES "")` as a normal variable,
# which shadows the cache for the rest of configure. konsole's cache held
# the value and its compile line still carried -I/usr/include, so
# TerminalDisplay.cpp read the host's ICU 74 headers and linked Conan's
# ICU 78: undefined ubidi_*_74. Proved on a minimal project: a cache
# value shadowed to "" re-emits -I/usr/include; a normal set from this
# hook removes it. Truthful, too: the zig wrappers append
# `-idirafter /usr/include`, so it genuinely is an implicit path.
foreach(_se_lang C CXX)
    set(CMAKE_${_se_lang}_IMPLICIT_INCLUDE_DIRECTORIES "/usr/include")
endforeach()
# Say so, with what this hook saw: three local models of the include order
# each predicted no host header on the line, and CI compiled against the
# host's ICU 74 regardless. The next cmake.log must show whether this ran
# and what the guarded block above concluded, rather than leaving it to be
# inferred from a link error forty minutes later.
message(STATUS "static-everywhere: implicit include dirs set to /usr/include "
    "(system=${CMAKE_SYSTEM_NAME} processor=${CMAKE_SYSTEM_PROCESSOR} "
    "project=${PROJECT_NAME})")

# A static build drags each module's private STATIC helpers into its
# export set, and CMake then requires them to be exported too -- which
# upstream, building shared, never has to do. knewstuff stopped on
# knscore_jobs_static; kpackage has the mirror-image bug. Handled for
# every module by a deferred pass at the end of configure, above the
# konsole-only guards below so it reaches the dependency modules.
include("${CMAKE_CURRENT_LIST_DIR}/export-static-helpers.cmake")

# A source file that is split out of a larger translation unit can stop
# receiving a Qt class definition through an accidental transitive include.
# Keep this repair generic: it is an idempotent source/header contract, not a
# compiler-wide forced include or a workaround for one diagnostic spelling.
# The anchor makes an upstream source reshuffle fail loudly instead of
# silently writing the header in an arbitrary place.
function(_se_ensure_direct_include source_file header anchor)
    if(NOT EXISTS "${source_file}")
        message(FATAL_ERROR
                "static-everywhere: expected source file for direct include "
                "contract does not exist: ${source_file}")
    endif()
    file(READ "${source_file}" _se_source)
    string(REGEX MATCH
           "#[ \\t]*include[ \\t]*[<\"]([^>\"]*/)?${header}[>\"]"
           _se_direct_include "${_se_source}")
    if(_se_direct_include)
        return()
    endif()
    string(FIND "${_se_source}" "${anchor}" _se_anchor_pos)
    if(_se_anchor_pos LESS 0)
        message(FATAL_ERROR
                "static-everywhere: direct include contract for ${header} "
                "lost its insertion anchor in ${source_file}")
    endif()
    string(REPLACE "${anchor}" "${anchor}\n#include <${header}>"
           _se_source "${_se_source}")
    file(WRITE "${source_file}" "${_se_source}")
    message(STATUS
            "static-everywhere: added direct Qt include <${header}> to "
            "${source_file}")
endfunction()

# KIO's new file_unix_copy.cpp uses QUrl by value. At 8f3af2189 the file was
# split from file_unix.cpp without carrying its direct Qt include, so the
# forward declaration from qmetatype.h is insufficient. Apply the same
# source/header contract above to every checkout of this source shape before
# KIO adds the target; future split files can use the helper without another
# diagnostic-specific branch.
if(PROJECT_NAME STREQUAL "KIO")
    _se_ensure_direct_include(
        "${CMAKE_CURRENT_SOURCE_DIR}/src/kioworkers/file/file_unix_copy.cpp"
        "QUrl"
        "#include \"file.h\"")
endif()

# Define KF6::Notifications before anything includes an export that names
# it.
#
# kjobwidgets requires KF6Notifications -- find_package(... REQUIRED) at
# CMakeLists.txt:53 -- and records KF6::Notifications in the link
# interface it exports. Its generated KF6JobWidgetsConfig.cmake declares
# only Qt6Widgets and KF6CoreAddons, so a consumer that calls
# find_package(KF6JobWidgets) receives a targets file naming a target
# nobody defined, and kio stopped there:
#
#   The link interface of target "KF6::JobWidgets" contains:
#     KF6::Notifications
#   but the target was not found.
#
# The first attempt at this was to stop kjobwidgets finding the package,
# on the assumption the dependency was optional because the config did
# not declare it. It is not optional; it is REQUIRED, and disabling it
# only moved the failure one module earlier. The config is simply missing
# a find_dependency call -- upstream's bug, filed in UPSTREAM.md.
#
# QUIET and not REQUIRED: this runs for every module in the graph,
# including the ones built before knotifications exists. Where the
# package is absent this does nothing, and where it is present the target
# is defined before any export can refer to it.
find_package(KF6Notifications QUIET CONFIG)
if(PROJECT_NAME STREQUAL "KPackage")
    set(_se_kpackage_cmake
        "${CMAKE_CURRENT_SOURCE_DIR}/src/kpackage/CMakeLists.txt")
    if(EXISTS "${_se_kpackage_cmake}")
        file(READ "${_se_kpackage_cmake}" _se_kpackage_content)
        set(_se_kpackage_stale_block [=[
if (NOT BUILD_SHARED_LIBS)
    install(TARGETS kpackage_common_STATIC EXPORT KF6PackageTargets ${KF_INSTALL_TARGETS_DEFAULT_ARGS})
endif()
]=])
        string(FIND "${_se_kpackage_content}" "${_se_kpackage_stale_block}"
               _se_kpackage_block_pos)
        if(_se_kpackage_block_pos GREATER -1)
            string(REPLACE "${_se_kpackage_stale_block}" ""
                   _se_kpackage_content "${_se_kpackage_content}")
            file(WRITE "${_se_kpackage_cmake}" "${_se_kpackage_content}")
            message(STATUS
                    "static-everywhere: removed stale KPackage kpackage_common_STATIC install target")
        else()
            string(FIND "${_se_kpackage_content}" "kpackage_common_STATIC"
                   _se_kpackage_symbol_pos)
            if(_se_kpackage_symbol_pos GREATER -1)
                message(FATAL_ERROR
                        "static-everywhere: found kpackage_common_STATIC in "
                        "KPackage, but its expected stale install block changed")
            endif()
        endif()
    endif()
endif()

if(PROJECT_NAME STREQUAL "KPackage")
    set(_se_kpackage_cmake
        "${CMAKE_CURRENT_SOURCE_DIR}/src/kpackage/CMakeLists.txt")
    if(NOT EXISTS "${_se_kpackage_cmake}")
        message(FATAL_ERROR
                "static-everywhere: KPackage project has no "
                "${_se_kpackage_cmake}")
    endif()
endif()
if(NOT PROJECT_IS_TOP_LEVEL)
    return()
endif()

if(NOT PROJECT_NAME STREQUAL "konsole")
    return()
endif()

get_filename_component(_SE_REPO_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)

# Source overlays are generated from the exact commit in deps.lock and are
# checked by preflight before the expensive graph build starts. Apply every
# overlay in lexical order, so adding a new source-level contract cannot be
# forgotten in this hook. The reverse check makes the operation idempotent for
# a cached kde-builder checkout.
file(GLOB _SE_KONSOLE_SOURCE_PATCHES LIST_DIRECTORIES false
    "${CMAKE_CURRENT_LIST_DIR}/patches/*.patch")
list(SORT _SE_KONSOLE_SOURCE_PATCHES)
if(NOT _SE_KONSOLE_SOURCE_PATCHES)
    message(FATAL_ERROR
        "static-everywhere: no pinned Konsole source patches found")
endif()
foreach(_se_konsole_source_patch IN LISTS _SE_KONSOLE_SOURCE_PATCHES)
    get_filename_component(_se_konsole_source_patch_name
        "${_se_konsole_source_patch}" NAME)
    execute_process(
        COMMAND git -C "${CMAKE_CURRENT_SOURCE_DIR}" apply
                --check --whitespace=error "${_se_konsole_source_patch}"
        RESULT_VARIABLE _se_konsole_patch_applies
        OUTPUT_QUIET ERROR_QUIET)
    if(_se_konsole_patch_applies EQUAL 0)
        execute_process(
            COMMAND git -C "${CMAKE_CURRENT_SOURCE_DIR}" apply
                    --whitespace=error "${_se_konsole_source_patch}"
            RESULT_VARIABLE _se_konsole_patch_result
            OUTPUT_QUIET ERROR_QUIET)
        if(NOT _se_konsole_patch_result EQUAL 0)
            message(FATAL_ERROR
                "static-everywhere: failed to apply pinned Konsole source patch "
                "${_se_konsole_source_patch_name}")
        endif()
        message(STATUS
            "static-everywhere: applied Konsole source patch "
            "${_se_konsole_source_patch_name}")
    else()
        execute_process(
            COMMAND git -C "${CMAKE_CURRENT_SOURCE_DIR}" apply
                    --reverse --check --whitespace=error
                    "${_se_konsole_source_patch}"
            RESULT_VARIABLE _se_konsole_patch_reverses
            OUTPUT_QUIET ERROR_QUIET)
        if(NOT _se_konsole_patch_reverses EQUAL 0)
            message(FATAL_ERROR
                "static-everywhere: pinned Konsole source patch "
                "${_se_konsole_source_patch_name} applies neither forward "
                "nor reverse; source revision or patch drifted")
        endif()
        message(STATUS
            "static-everywhere: Konsole source patch already applied "
            "${_se_konsole_source_patch_name}")
    endif()
endforeach()

# KIconTheme::initTheme() has an upstream contract: it must run before the
# application object so its Q_COREAPP_STARTUP_FUNCTION is registered in time.
# The remaining KDE/Qt GUI helpers must run after QApplication exists. Static
# builds make violating either half fatal instead of allowing a plugin/runtime
# path lookup to be deferred as it often is with shared builds. Keep both
# checks structural, so a future source overlay cannot silently change this
# startup contract.
set(_se_konsole_main_source "${CMAKE_CURRENT_SOURCE_DIR}/src/main.cpp")
if(NOT EXISTS "${_se_konsole_main_source}")
    message(FATAL_ERROR
        "static-everywhere: Konsole main source is missing: "
        "${_se_konsole_main_source}")
endif()
file(READ "${_se_konsole_main_source}" _se_konsole_main_content)
string(FIND "${_se_konsole_main_content}"
    "new QApplication(argc, argv)" _se_konsole_app_pos)
if(_se_konsole_app_pos LESS 0)
    message(FATAL_ERROR
        "static-everywhere: Konsole main has no QApplication construction")
endif()
string(FIND "${_se_konsole_main_content}" "KIconTheme::initTheme()"
    _se_konsole_icon_theme_pos)
if(_se_konsole_icon_theme_pos LESS 0)
    message(FATAL_ERROR
        "static-everywhere: Konsole has no KIconTheme::initTheme() call")
endif()
if(NOT _se_konsole_icon_theme_pos LESS _se_konsole_app_pos)
    message(FATAL_ERROR
        "static-everywhere: KIconTheme::initTheme() must precede QApplication")
endif()
foreach(_se_konsole_gui_helper
        "KStyleManager::initStyle()"
        "QApplication::setStyle")
    string(FIND "${_se_konsole_main_content}" "${_se_konsole_gui_helper}"
        _se_konsole_gui_helper_pos)
    if(_se_konsole_gui_helper_pos GREATER -1 AND
       _se_konsole_gui_helper_pos LESS _se_konsole_app_pos)
        message(FATAL_ERROR
            "static-everywhere: Konsole GUI helper runs before QApplication: "
            "${_se_konsole_gui_helper}")
    endif()
endforeach()
message(STATUS
    "static-everywhere: Konsole icon-theme bootstrap precedes QApplication; "
    "remaining GUI helpers run after it")

# Konsole deliberately keeps its application facade as a shared library:
# the executable and the installed KPart both use the same implementation.
# The global recipe disables RPATH for KDE frameworks, but that policy cannot
# be applied to this application's own relocatable runtime: without an
# origin-relative install RPATH, bin/konsole needs a manually prepared
# LD_LIBRARY_PATH to find lib/libkonsoleapp.so. Keep the system boundary
# dynamic (X11/OpenGL/Canberra); only the library shipped beside the
# application is made relocatable.
set(CMAKE_SKIP_RPATH OFF CACHE BOOL "" FORCE)
set(CMAKE_SKIP_INSTALL_RPATH OFF CACHE BOOL "" FORCE)
set(CMAKE_BUILD_RPATH_USE_ORIGIN ON)
set(CMAKE_INSTALL_RPATH "\$ORIGIN/../lib")
set(CMAKE_INSTALL_RPATH_USE_LINK_PATH OFF)
message(STATUS "static-everywhere: Konsole runtime RPATH is $ORIGIN/../lib")
include("${CMAKE_CURRENT_LIST_DIR}/runtime-rpath.cmake")

include("${CMAKE_CURRENT_LIST_DIR}/import-static-qt-plugins.cmake")

# This is deliberately the f4 implementation, not a new GL policy. It
# removes libGL from DT_NEEDED and loads the host OpenGL implementation at
# runtime; X11 remains a normal host dependency. Widgets does not use the
# Quick fallback path, but the constructor is harmless and keeps the same
# host-OpenGL behavior as the reference recipe.

include("${_SE_REPO_ROOT}/contrib/f4-qt/optional-gl.cmake")
# Conan's qt recipe omits the Qt6::Quick -> Qt6::OpenGL edge; libQt6Quick.a
# references QOpenGLFramebufferObject and QOpenGLPaintDevice from
# libQt6OpenGL.a, and only a static link notices. konsolepart.so failed on
# exactly the symbols f4-qt's file documents, down to
# qsgdefaultpainternode.cpp. Reused rather than re-derived.
include("${_SE_REPO_ROOT}/contrib/f4-qt/link-qt6-opengl.cmake")
# The other edges the Conan recipe omits, found by tools/scan-qt-module-edges.sh
# from Qt's own module declarations rather than from a link error:
# Quick -> QmlMeta (a module Conan never exposes), Multimedia -> Concurrent,
# Multimedia -> DBus.
include("${CMAKE_CURRENT_LIST_DIR}/link-qt6-orphan-modules.cmake")

# Static ICU wants U_STATIC_IMPLEMENTATION. Conan's ICU config carries that
# define; konsole finds ICU through CMake's FindICU MODULE, which hands
# over include dirs and libraries and nothing else, so the define never
# arrives. Not the cause of ubidi_*_74 -- that is a header version -- but
# a class on the list (BUILD-FAILURE-CLASSES.md 2.10) that would surface
# next as visibility/export mismatches against libicu*.a. Closed here,
# scoped to the one consumer, rather than discovered by a run.
add_compile_definitions(U_STATIC_IMPLEMENTATION)

# ICU headers and archives must be the same version -- decided here, at
# configure, rather than by an "undefined ubidi_open_74" at link. Deferred
# so ICU::uc exists (konsole's find_package(ICU) runs later).
include("${CMAKE_CURRENT_LIST_DIR}/defer-recipe-file.cmake")
_se_konsole_defer_recipe_file(
    "${CMAKE_CURRENT_LIST_DIR}/check-icu-consistency.cmake")
message(STATUS "static-everywhere: U_STATIC_IMPLEMENTATION defined for konsole's static ICU")

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
               CALL _se_konsole_set_runtime_rpath)

cmake_language(DEFER DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
               CALL _se_konsole_assert_static_graph)
