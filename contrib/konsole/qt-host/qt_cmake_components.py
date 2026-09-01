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
