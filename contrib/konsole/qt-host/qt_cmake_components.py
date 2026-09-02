"""Generate compatibility files for Qt component-style CMake packages."""


def component_config(module: str) -> str:
    """Return a Qt6<module>Config.cmake compatibility adapter."""
    return f'''# Conan's Qt package exports one Qt6Config.cmake aggregate.
# KDE projects also use find_package(Qt6{module}), so bridge that upstream
# component spelling to the aggregate without selecting a host Qt package.
if(NOT DEFINED _STATIC_EVERYWHERE_QT6_CONFIG_INCLUDED)
    include("${{CMAKE_CURRENT_LIST_DIR}}/Qt6Config.cmake")
    set(_STATIC_EVERYWHERE_QT6_CONFIG_INCLUDED TRUE)
endif()

if(TARGET Qt6::{module})
    set(Qt6{module}_FOUND TRUE)
else()
    set(Qt6{module}_FOUND FALSE)
endif()

if(DEFINED Qt6_VERSION_STRING)
    set(Qt6{module}_VERSION_STRING "${{Qt6_VERSION_STRING}}")
    set(Qt6{module}_VERSION "${{Qt6_VERSION_STRING}}")
endif()

if("{module}" STREQUAL "Gui" AND
   (TARGET Qt6::QXcbIntegrationPlugin OR TARGET Qt6::XcbQpaPrivate))
    # Conan's aggregate Qt config carries the XCB targets but does not carry
    # Qt's upstream QT_FEATURE_xcb variable. KDE's KGuiAddons checks that
    # variable before compiling its X11 backend; derive it from the concrete
    # QPA targets so the adapter remains correct when X11 is disabled too.
    set(QT_FEATURE_xcb ON)
endif()
'''


def component_version_config() -> str:
    """Return a version-file adapter matching the aggregate Qt package."""
    return 'include("${CMAKE_CURRENT_LIST_DIR}/Qt6ConfigVersion.cmake")\n'


def legacy_package_config(
    package: str,
    target: str,
    variable_prefix: str,
    version: str,
    header: str = "",
    path_suffixes: str = "",
) -> str:
    """Return a CONFIG adapter for a legacy variable-based CMake consumer.

    ``header`` and ``path_suffixes`` matter when the consumer includes the
    header unqualified while the package installs it in a subdirectory.
    Conan's imported target carries ``<pkg>/include``; sonnet writes
    ``#include <hunspell.hxx>`` and the file is at
    ``<pkg>/include/hunspell/hunspell.hxx``, so handing over the target's
    include directory is one level too high and the compile fails with
    "'hunspell.hxx' file not found". Upstream's FindHUNSPELL resolves this
    with find_path and PATH_SUFFIXES; so does this adapter when told which
    header to look for.
    """
    header_probe = ""
    if header:
        # NO_DEFAULT_PATH on purpose: resolve inside the package or not at
        # all. Falling back to the host would silently compile against a
        # different hunspell than the one being linked.
        header_probe = f'''

    find_path(_static_everywhere_{variable_prefix}_header_dir
              NAMES {header}
              HINTS ${{_static_everywhere_includes}}
                    "${{{package}_PACKAGE_FOLDER_RELEASE}}/include"
              PATH_SUFFIXES {path_suffixes or "."}
              NO_DEFAULT_PATH)
    if(_static_everywhere_{variable_prefix}_header_dir)
        set({variable_prefix}_INCLUDE_DIRS
            "${{_static_everywhere_{variable_prefix}_header_dir}}")
    endif()'''

    return f'''# Conan's CMakeDeps package config exports the imported target
# but the upstream Find module also expects legacy variables.
include("${{CMAKE_CURRENT_LIST_DIR}}/{package}-config.cmake")

if(TARGET {target})
    get_target_property(_static_everywhere_includes
                        {target} INTERFACE_INCLUDE_DIRECTORIES)
    if(_static_everywhere_includes AND
       NOT "${{_static_everywhere_includes}}" MATCHES "-NOTFOUND$")
        set({variable_prefix}_INCLUDE_DIRS "${{_static_everywhere_includes}}")
    endif(){header_probe}
    set({variable_prefix}_LIBRARIES {target})
    set({variable_prefix}_FOUND TRUE)
    set({variable_prefix}_VERSION "{version}")
    set({variable_prefix}_VERSION_STRING "{version}")
    set(PKG_{variable_prefix}_VERSION "{version}")
else()
    set({variable_prefix}_FOUND FALSE)
endif()
'''
