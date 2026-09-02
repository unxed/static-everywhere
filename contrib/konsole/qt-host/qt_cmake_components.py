"""Generate compatibility files for Qt component-style CMake packages."""


def component_shim_names(public_components):
    """Return every Qt6 component adapter to generate, private ones included.

    Derived rather than listed. The private family used to be a hand
    written set of twenty names, grown one CI round at a time: a KDE
    framework asked for Qt6GuiPrivate, the build failed two hours in, the
    name was appended, repeat. A list maintained that way is only ever
    correct about the past.

    Every public component can have a private counterpart, and the
    adapter is conditional -- it reports NOT FOUND when the target does
    not exist, which is what a real Qt installation does too. So
    generating the whole family costs nothing and cannot be incomplete,
    while a list can.
    """
    public = {name for name in public_components if not name.endswith("Private")}
    return sorted(public | {f"{name}Private" for name in public})


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
    header: str,
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
    if not header:
        raise ValueError(
            f"legacy_package_config({package!r}) needs the header its "
            "consumers include. Without it the adapter hands over the "
            "imported target's include directory, which is the package "
            "root and often one level above the header -- the sonnet "
            "'hunspell.hxx' file not found failure. State the header and "
            "the adapter resolves to the directory that holds it."
        )
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
    else()
        # Loudly, not silently. An adapter that reports the package as
        # found while handing over no usable include directory pushes the
        # failure into some consumer's compile, hours later, as a bare
        # "file not found" with no mention of this package.
        message(FATAL_ERROR
            "{variable_prefix}: {header} is not under the {package} package. "
            "The adapter would report the package as found with no usable "
            "include directory, and the failure would surface later as a "
            "missing header in whatever consumes it.")
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
