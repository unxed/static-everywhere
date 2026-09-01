# Konsole showcase recipe audit

This file records the two pre-CI checks requested for the Konsole showcase.
The hosted build and graphical launch are intentionally not called a success
until the GitHub Actions job produces them.

## Pass 1: f4 qt inventory

The complete f4 reference was read before writing this recipe:

- `.github/workflows/f4-qt-zig-build.yml`
- `tools/build-f4-qt.sh`
- `contrib/f4-qt/project-include.cmake`
- `contrib/f4-qt/import-qt-static-plugins.cmake`
- `contrib/f4-qt/optional-gl.cmake`
- `onebin/toolchain/onebin-linux-hybrid.cmake`
- `tools/preflight-f4-qt.sh`
- `tools/audit-with-hygiene-waivers.sh`

The load-bearing decisions were classified before adapting them:

| f4 qt detail | Konsole decision |
| --- | --- |
| manual trigger and a separate fast preflight | carried into `konsole-zig-build.yml` |
| runner disk cleanup, 300-minute build timeout | carried |
| Zig 0.13.0 and onebin hybrid toolchain | carried; glibc baseline is 2.27 |
| host X11/xcb/ICE/SM contract | carried; no host Qt or KDE package is allowed |
| host OpenGL | carried through the existing optional-GL forwarder; `libGL` is not DT_NEEDED |
| CMake ABI workarounds for Zig | carried: pointer size, multiarch, implicit includes and RPATH |
| compile glibc compatibility shim before Conan | carried, with global shared/executable link flags |
| rebuild target packages despite Conan binary availability | carried for the reduced Qt graph |
| `PKG_CONFIG_PATH` with system multiarch paths | carried for host xcb discovery, with Conan `.pc` paths preferred during KDE build |
| fontconfig HTTP 418 workaround | carried verbatim from f4's upstream builder |
| source-download backup and no `conan cache clean --source` | carried |
| ccache sloppiness/base directory/size and explicit cache save | carried |
| `set -o pipefail` plus a saved build transcript | carried |
| diagnostics on `failure() || cancelled()` | carried, including CMake/autotools/Meson logs, MIME-filtered text and OOM state |
| static Qt platform/plugin registration | carried for qxcb, qxcb-GLX and qxcb-EGL; no f4 QML scanner is copied because Konsole is Widgets-only |
| static graph assertion | carried for Qt/KF6 targets and package directories |
| f4 Go setup, Go tests, embedded packaging and QML-specific hooks | intentionally omitted for the Konsole application; framework QML is retained only where upstream requires it |
| f4 QWindowKit and f4 application-specific tests | intentionally omitted |

The host boundary is therefore: X11/xcb and the OpenGL ABI are host-owned;
Qt, KF6 and the application are built in the CI source graph. CMake's global
prefix exclusion is explicitly cleared because KGuiAddons and KWindowSystem
use the `FindX11`/`FindXCB` MODULEs to discover those host headers and
libraries. The common CMake hook restores the fixed x86_64 multiarch metadata
after Zig's failed ABI probe, so that discovery reaches `/usr/lib`'s
multiarch directory. Conan config prefixes remain first, while the top-level
static graph assertion rejects a host Qt/KF6 target if one is ever selected.
`qt-install-dir` is deliberately absent from kde-builder configuration, so
kde-builder does not select a host or separately managed Qt tree.

## Source-graph audit before the hosted build

The KDE Frameworks `CMakeLists.txt` files were inspected before adding the
corresponding recipe flags. The current upstream graph has several defaults
that are not safe with a Widgets-only, no-QtWayland target:

- KNewStuff requires `Qt6::Qml`, `Qt6::Quick` and `Qt6::QuickWidgets` and
  unconditionally adds its `src/qtquick` directory, so `qtdeclarative=True` is
  required even though Konsole itself has no QML runtime path.
- KConfig, KI18n, KCoreAddons, KIconThemes, KWindowSystem and Sonnet expose
  optional QML/Quick integrations; their project-specific switches are set to
  `OFF` where the source provides them.
- KGuiAddons and KWindowSystem default to Wayland on Linux; their Wayland
  switches are set to `OFF` while QtWayland remains outside this X11 scope.
- With `WITH_X11=ON`, KGuiAddons calls CMake's `FindX11` and `FindXCB`
  MODULEs, so the host `/usr` prefix must be searchable. This is a class-level
  host-ABI discovery rule, not a one-library workaround. Because Zig's CMake
  ABI probe leaves multiarch metadata empty, the common hook restores the
  pointer size, architecture and implicit include contract before these
  finders run. KGuiAddons also checks Qt's `QT_FEATURE_xcb` variable; Conan's
  aggregate Qt config publishes the concrete XCB QPA targets but omits that
  upstream feature variable, so the generated `Qt6GuiConfig.cmake` adapter
  derives it from those targets. Static Qt/KF6 selection remains protected by
  Conan prefix ordering and the final graph assertion.
- KArchive defaults BZip2, LZMA, OpenSSL and Zstd to required. BZip2, LZMA and
  Zlib are direct Conan requirements because KArchive compiles sources that
  include their headers; the recipe disables the unused OpenSSL/Zstd paths.
- KCoreAddons, Solid and KIO directly include or link LibMount. It is also a
  direct Conan requirement, with a CMake target alias for the upstream
  `LibMount::LibMount` spelling. This avoids Conan's `headers=False` treatment
  of a dependency reached only through Qt, which otherwise leaves a target
  visible while dropping the include directory.
- Solid requires Flex, Bison and LibMount; its optional UDev backend is
  disabled for this target. KNotifications' Linux build also requires the
  QtDBus CMake package and Canberra development files even with application
  DBus disabled, so those build inputs are installed explicitly.
- Breeze Icons enables `WITH_ICON_GENERATION` by default. Its source
  `CMakeLists.txt` invokes `tools/generate-24px-versions.py`, whose pinned
  source imports `lxml`; the generated build command uses the system Python
  interpreter rather than the Conan venv. The apt package/module mapping is
  recorded in `host-python-modules.txt`, installed in both workflow jobs and
  imported by an early gate. This makes missing system Python modules a
  fail-fast, auditable class of host build-tool errors.
- Designer plugins and text-to-speech are optional framework features and are
  disabled to keep the built graph aligned with Konsole's actual application
  targets.

Wayland is intentionally not part of this acceptance pass. There is no
architectural blocker to adding it later: the recipe will need QtWayland,
Wayland protocol development inputs, and a compositor-backed runtime smoke
test rather than treating the current X11 result as equivalent.

## Pass 2: reverse check of the Konsole recipe

After the implementation was written, every item above was checked against
the actual new workflow, build script, Conan recipe, KDE-builder template,
CMake hook and verification scripts. The following checks were run before any
GitHub workflow dispatch:

1. `bash -n` passed for all four Konsole shell scripts.
2. `python3 -m py_compile` passed for the Conan recipe.
3. The rendered kde-builder YAML and workflow parsed with PyYAML; the
   configuration has `include-dependencies: true`, `BUILD_SHARED_LIBS=OFF`,
   an explicitly cleared `CMAKE_IGNORE_PREFIX_PATH`, the Zig target-metadata
   restoration hook for host ABI discovery, and a pinned Konsole revision.
4. `tools/preflight-konsole.sh` passed its plan assertions, including the
   glibc target, shim, cache preservation, static Qt options, CMake hook,
   hygiene audit and graphical smoke command. It also verified that no Go
   step is present.
5. A host CMake discovery regression with intentionally erased Zig ABI
   metadata found the real X11 library through `FindX11` in the multiarch
   directory.
6. A miniature CMake project with a fake aggregate Qt config verified that
   the component adapter preserves Qt's XCB feature metadata when the
   concrete QPA targets are present.
7. A miniature CMake project with fake static qxcb/GL plugin archives
   configured and built successfully. It exercised the Itanium symbol parser,
   `.prl` closure, executable-only `INTERFACE_SOURCES`, optional-GL CXX
   compilation and static-graph assertion.
8. `./tools/test-optional-gl-cxx-only.sh` passed.
9. `make -C onebin test` passed: 273 tests passed and 3 were skipped by their
   existing fixture/locale guards.
10. The f4 reference itself was not modified. No hosted build was dispatched
   during either pass.

The host Python module manifest is checked against both workflow apt install
blocks, and the hosted preflight imports every declared module with
`/usr/bin/python3`; therefore a newly declared KDE generator dependency cannot
silently be present only in the Conan virtual environment.

The reverse check also found and fixed three preflight issues before this
record was finalized: the missing `zig-c++` plan variable, a false host-path
grep caused by the plan's inherited `PATH`, and YAML `@...@` placeholders that
were not valid unquoted scalars. The current preflight renders the template
and parses it, so those failures cannot reach the two-hour job silently.

After the final workflow edit, the preflight package-install block received a
separate shell-continuation audit: every package line except the final package
has a trailing `\\`, and the two independent gates (workflow/templated YAML
parse plus the full Konsole preflight) were rerun. No workflow dispatch is
made until both gates pass.

The remaining proof is necessarily hosted: the full Conan Qt graph, the
source-built KF6 dependency closure, the final onebin audit, and a Konsole
window captured from Xvfb.
