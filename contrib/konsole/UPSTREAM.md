# Findings worth fixing upstream of this recipe

## 1. Conan's Qt package: `Qt6::Qml` does not carry the QtQmlIntegration include directory

Building ki18n against the Conan `qt/6.11.1` package fails:

```
ki18n/src/i18n-qml/klocalizedqmlcontext.h:16:10:
    fatal error: 'qqmlintegration.h' file not found
```

The compile line is not missing Qml — it lists
`<qt-package>/include/QtQml`, `include/QtCore`, `include/QtNetwork` and
so on. `qqmlintegration.h` simply is not in `include/QtQml`. It belongs
to the **QtQmlIntegration** module and is installed to
`<qt-package>/include/QtQmlIntegration/`, which the package does ship —
the directory is there next to the others.

In an upstream Qt installation `Qt6::Qml` links `Qt6::QmlIntegration`
publicly, so anything linking `Qt6::Qml` inherits that include
directory. The Conan-generated `Qt6Qml` target does not, so a consumer
that follows Qt's own documented usage — link `Qt6::Qml`, include
`<qqmlintegration.h>` — gets a header-not-found.

**Suggested fix:** have the recipe declare `QmlIntegration` as a
component of the `qml` component's requirements, so its `includedirs`
propagate the way upstream's target does.

**Worked around here** by adding the directory through
`CMAKE_CXX_STANDARD_INCLUDE_DIRECTORIES` in
`contrib/konsole/kde-builder.yaml.in`, which injects it into every
compile without disturbing `CMAKE_CXX_FLAGS` from the toolchain file.

## 2. ki18n: the QML subdirectory ignores `BUILD_WITH_QML`

`ki18n/CMakeLists.txt` offers `option(BUILD_WITH_QML ... ON)` and only
calls `find_package(Qt6Qml)` when it is set. But `src/CMakeLists.txt`
gates the subdirectory on the *target* instead:

```cmake
if (TARGET Qt6::Qml)
    add_subdirectory(i18n-qml)
    add_subdirectory(localedata-qml)
endif()
```

With a package whose config defines every component target — Conan's
does — `Qt6::Qml` exists regardless of the option, so `-DBUILD_WITH_QML=OFF`
does not disable the QML build. A consumer who explicitly asked for no
QML still gets it, and still needs the QML dependencies.

**Suggested fix:** gate on the option, or on
`BUILD_WITH_QML AND TARGET Qt6::Qml`, so the option means what it says.

## 3. Conan's aggregate Qt config omits `QT_FEATURE_xcb`

The pinned KGuiAddons source checks `QT_FEATURE_xcb` before compiling its
X11 backend. The Conan `qt/6.11.1` package is built with `with_x11=True` and
does ship the concrete `Qt6::QXcbIntegrationPlugin` and
`Qt6::XcbQpaPrivate` targets, but its aggregate `Qt6Config.cmake` does not
export the upstream feature variable. A consumer can therefore find both
host X11/XCB and still fail KGuiAddons' configure-time feature check.

**Suggested fix:** export Qt feature variables alongside the aggregate
component targets, or derive them in the generated component adapter. This
recipe derives `QT_FEATURE_xcb` only when one of the concrete XCB QPA targets
exists, so disabling X11 cannot accidentally claim that feature is enabled.

## 4. Conan's aggregate Qt config omits standalone private-module adapters

Several KDE Frameworks in the pinned dependency graph call
`find_package(Qt6GuiPrivate)` while Conan's Qt package exposes the corresponding
`Qt6::GuiPrivate` target only from its aggregate `Qt6Config.cmake`. CMake's
CONFIG lookup therefore fails before it can use the target. The recipe emits
adapters for the Qt private-component family and verifies the
`Qt6GuiPrivate` form in its component regression test.

## 5. qca defaults to Qt5 while the KDE graph uses its Qt6 branch

The pinned qca `CMakeLists.txt` defaults `BUILD_WITH_QT6` to `OFF` and
otherwise requires Qt5. Its Qt6 branch instead requires Qt6 Core, Test and
Core5Compat. The kde-builder recipe selects that branch and disables qca's
unneeded test/tool targets; the Conan recipe enables the corresponding
`qt5compat` module.
