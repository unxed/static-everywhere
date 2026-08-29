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
| f4 Go setup, Go tests, embedded packaging and QML-specific hooks | intentionally omitted: Konsole has no Go or QML application graph |
| f4 QWindowKit and f4 application-specific tests | intentionally omitted |

The host boundary is therefore: X11/xcb and the OpenGL ABI are host-owned;
Qt, KF6 and the application are built in the CI source graph. `qt-install-dir`
is deliberately absent from kde-builder configuration, so kde-builder does
not select a host or separately managed Qt tree.

## Pass 2: reverse check of the Konsole recipe

After the implementation was written, every item above was checked against
the actual new workflow, build script, Conan recipe, KDE-builder template,
CMake hook and verification scripts. The following checks were run before any
GitHub workflow dispatch:

1. `bash -n` passed for all four Konsole shell scripts.
2. `python3 -m py_compile` passed for the Conan recipe.
3. The rendered kde-builder YAML and workflow parsed with PyYAML; the
   configuration has `include-dependencies: true`, `BUILD_SHARED_LIBS=OFF`,
   `CMAKE_IGNORE_PREFIX_PATH=/usr;/lib;/lib64`, and a pinned Konsole revision.
4. `tools/preflight-konsole.sh` passed its plan assertions, including the
   glibc target, shim, cache preservation, static Qt options, CMake hook,
   hygiene audit and graphical smoke command. It also verified that no Go
   step is present.
5. A miniature CMake project with fake static qxcb/GL plugin archives
   configured and built successfully. It exercised the Itanium symbol parser,
   `.prl` closure, executable-only `INTERFACE_SOURCES`, optional-GL CXX
   compilation and static-graph assertion.
6. `./tools/test-optional-gl-cxx-only.sh` passed.
7. `make -C onebin test` passed: 273 tests passed and 3 were skipped by their
   existing fixture/locale guards.
8. The f4 reference itself was not modified. No hosted build was dispatched
   during either pass.

The reverse check also found and fixed three preflight issues before this
record was finalized: the missing `zig-c++` plan variable, a false host-path
grep caused by the plan's inherited `PATH`, and YAML `@...@` placeholders that
were not valid unquoted scalars. The current preflight renders the template
and parses it, so those failures cannot reach the two-hour job silently.

The remaining proof is necessarily hosted: the full Conan Qt graph, the
source-built KF6 dependency closure, the final onebin audit, and a Konsole
window captured from Xvfb.
