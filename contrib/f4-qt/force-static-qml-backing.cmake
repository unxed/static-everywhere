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

# Define the override exactly once. This file is included from every
# project() scope, and overriding a command twice makes `_add_library`
# resolve to the previous override rather than the builtin -- infinite
# recursion, which is precisely what the probe produced on the first
# attempt. A GLOBAL property is used rather than a variable because
# variables do not carry across sibling directory scopes, while a
# function definition does persist once made.
get_property(_se_add_library_overridden GLOBAL PROPERTY _SE_ADD_LIBRARY_OVERRIDDEN)
if(_se_add_library_overridden)
    return()
endif()
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
                "static-everywhere: building ${name} STATIC instead of SHARED "
                "(a shared QML plugin cannot register into a static binary)")
        endif()
        set(_args ${_rewritten})
    endif()
    _add_library(${name} ${_args})
endfunction()
