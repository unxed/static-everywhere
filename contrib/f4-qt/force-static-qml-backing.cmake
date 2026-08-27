# static-everywhere: build ZoinGallery's QML backing library statically.
#
# Why
# ---
# ZoinGallery declares its QML backing target as a shared library:
#
#   third_party/ZoinGallery/CMakeLists.txt:289
#   add_library(ZoinGalleryQml SHARED)
#
# Qt then makes the QML plugin match it. From Qt's own source
# (qtdeclarative/src/qml/Qt6QmlMacros.cmake, the block that picks
# lib_type): when the backing target already exists, a STATIC_LIBRARY
# gives a STATIC plugin and a SHARED or MODULE one gives SHARED. So the
# build produced libZoinGalleryQmlplugin.so, and a shared QML plugin
# cannot be registered into a statically linked binary at all -- hence
# `module "ZoinGallery" is not installed`, 43 times, after every Qt module
# had been fixed.
#
# There is no supported switch: ZoinGallery hard-codes SHARED and declares
# no option covering it, and `qt6_add_qml_module` is called without
# STATIC/SHARED, so it inherits the backing target's type.
#
# What this does, and how narrowly
# --------------------------------
# Overrides `add_library` for the duration of ZoinGallery's directory
# scope and rewrites SHARED to STATIC for ONE named target. Every other
# call is passed through untouched, including the MODULE libraries Qt
# creates deliberately elsewhere. The name is listed explicitly rather
# than pattern-matched, so this can never quietly widen.
#
# This is the toolchain overriding an upstream decision, which deserves to
# be said plainly rather than buried: ZoinGallery's choice is right for an
# ordinary desktop build and wrong only for a single-file static artifact,
# which is this project's whole purpose. The durable fix belongs upstream
# -- an option, or honouring BUILD_SHARED_LIBS -- and until then the
# override lives here where it is visible, not in a patch applied to
# somebody else's source tree.
#
# Nothing is disabled. The gallery, its QML module and every type in it
# are built and linked exactly as before; only the linkage changes.

set(_SE_FORCE_STATIC_TARGETS ZoinGalleryQml)

# A static Qt plugin comes with a companion: qt6_add_qml_module creates
# <plugin>_init, an OBJECT library carrying the registration unit, and
# links it into the plugin's interface. A shared plugin has none, which is
# why this only appeared once the rewrite above took effect:
#
#   export called with target "ZoinGalleryQmlplugin" which requires target
#   "ZoinGalleryQmlplugin_init" that is not in any export set.
#
# ZoinGallery installs its plugin into the ZoinGalleryTargets set
# (CMakeLists.txt:772), so the companion has to join it. Both names are
# read from that file rather than pattern-matched, and both are checked
# before use: this file already overrides one upstream decision, and
# guessing a second name would be how it starts causing damage instead of
# fixing it.
set(_SE_PLUGIN_EXPORT_SET_ZoinGalleryQml "ZoinGalleryTargets")

# Define the override exactly once. This file is included from every
# project() scope, and overriding a command twice makes `_add_library`
# resolve to the previous override rather than the builtin -- infinite
# recursion, which is precisely what the probe produced on the first
# attempt. A GLOBAL property is used rather than a variable because
# variables do not carry across sibling directory scopes, while a
# function definition does persist once made.
# The override is defined exactly once: this file is included from every
# project() scope, and overriding a command twice makes `_add_library`
# resolve to the previous override rather than the builtin -- infinite
# recursion, which is what the probe produced on the first attempt. A
# GLOBAL property is used because variables do not carry across sibling
# directory scopes, while a function definition persists once made.
#
# The DEFER registration below is deliberately OUTSIDE that guard. An
# earlier version returned early here and so never registered anything in
# ZoinGallery's own scope, which is the only scope that matters.
get_property(_se_add_library_overridden GLOBAL PROPERTY _SE_ADD_LIBRARY_OVERRIDDEN)
if(NOT _se_add_library_overridden)
    set_property(GLOBAL PROPERTY _SE_ADD_LIBRARY_OVERRIDDEN TRUE)

    function(add_library name)
        set(_args ${ARGN})
        if(name IN_LIST _SE_FORCE_STATIC_TARGETS)
            set(_rewritten "")
            set(_did FALSE)
            foreach(_a IN LISTS _args)
                if(_a STREQUAL "SHARED" OR _a STREQUAL "MODULE")
                    list(APPEND _rewritten STATIC)
                    set(_did TRUE)
                else()
                    list(APPEND _rewritten "${_a}")
                endif()
            endforeach()
            if(_did)
                message(STATUS
                    "static-everywhere: building ${name} STATIC instead of "
                    "SHARED (a shared QML plugin cannot register into a "
                    "static binary)")
            endif()
            set(_args ${_rewritten})
        endif()
        _add_library(${name} ${_args})
    endfunction()

    # Deferred so it runs after the project's own install() calls have
    # created the export set. Harmless in scopes with no such target: the
    # TARGET check simply finds nothing.
    # Companions of a static Qt target, found rather than listed.
    #
    # Making the backing target static changes the target graph, not just
    # a flag. Qt attaches generated OBJECT libraries to it -- <t>plugin_init
    # for the plugin registration, <t>_resources_N for each resource set,
    # and more in other configurations -- and every one of them has to be
    # in the same export set as the target that requires it, or the
    # generate step fails.
    #
    # The first version of this named `<t>plugin_init` explicitly and was
    # right for exactly one run; the next failure was
    # `ZoinGalleryQml_resources_5`, the same defect with a different name.
    # So enumerate instead: walk the interface link libraries of each root
    # and take every target whose name is that root plus a suffix. That is
    # what "a companion Qt generated for this target" means, and it needs
    # no list to keep current.
    #
    # Targets the project exports itself are left alone: only names
    # prefixed by a root are touched, so ZoinGalleryCore and the roots
    # themselves are never added twice.
    function(_se_export_static_companions)
        foreach(_t IN LISTS _SE_FORCE_STATIC_TARGETS)
            set(_set "${_SE_PLUGIN_EXPORT_SET_${_t}}")
            set(_roots "${_t}" "${_t}plugin")
            set(_queue ${_roots})
            set(_seen "")
            while(_queue)
                list(POP_FRONT _queue _cur)
                if(NOT TARGET "${_cur}")
                    continue()
                endif()
                if("${_cur}" IN_LIST _seen)
                    continue()
                endif()
                list(APPEND _seen "${_cur}")
                get_target_property(_deps "${_cur}" INTERFACE_LINK_LIBRARIES)
                if(NOT _deps)
                    continue()
                endif()
                foreach(_d IN LISTS _deps)
                    # Strip the genex Qt wraps companions in, e.g.
                    # $<LINK_ONLY:ZoinGalleryQml_resources_5>.
                    string(REGEX REPLACE "^\\$<[A-Za-z_]+:" "" _d "${_d}")
                    string(REGEX REPLACE ">$" "" _d "${_d}")
                    if(NOT TARGET "${_d}")
                        continue()
                    endif()
                    list(APPEND _queue "${_d}")
                    set(_is_companion FALSE)
                    foreach(_r IN LISTS _roots)
                        if("${_d}" MATCHES "^${_r}_")
                            set(_is_companion TRUE)
                        endif()
                    endforeach()
                    if(NOT _is_companion)
                        continue()
                    endif()
                    if(NOT _set)
                        message(FATAL_ERROR
                            "static-everywhere: ${_d} is a generated companion "
                            "of ${_t} but no export set is recorded for it in "
                            "contrib/f4-qt/force-static-qml-backing.cmake. "
                            "Leaving it out fails the generate step with "
                            "'requires target ... that is not in any export "
                            "set'.")
                    endif()
                    # Targets are global while this call is registered per
                    # directory scope, so without this the outer project
                    # would install the nested project's companion a second
                    # time: "includes target ... more than once".
                    get_property(_done GLOBAL PROPERTY "_SE_EXPORTED_${_d}")
                    if(_done)
                        continue()
                    endif()
                    set_property(GLOBAL PROPERTY "_SE_EXPORTED_${_d}" TRUE)
                    install(TARGETS "${_d}" EXPORT "${_set}"
                            OBJECTS DESTINATION "${CMAKE_INSTALL_LIBDIR}")
                    message(STATUS
                        "static-everywhere: added companion ${_d} to the "
                        "${_set} export set")
                endforeach()
            endwhile()
        endforeach()
    endfunction()
endif()

include(GNUInstallDirs)
cmake_language(DEFER DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
               CALL _se_export_static_companions)
