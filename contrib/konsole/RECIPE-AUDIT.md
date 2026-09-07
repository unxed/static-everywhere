# Konsole showcase recipe audit

This file records the two pre-CI checks requested for the Konsole showcase.
The hosted build and graphical launch are intentionally not called a success
until the GitHub Actions job produces them.

## Run 64: one Conan provider graph for CMake and pkg-config

Run `34004127821` at `15b3307` failed in KArchive on `zstd.h` and
`openssl/evp.h`. Its diagnostics ZIP SHA-256 is
`c34bd05d96fb2fa1b83ad3059eeacc133790cb1fdc0d8b1b00f2c3af6a71b584`.
The cache records host LibZstd include/version metadata but a Conan archive;
the OpenSSL target was exposed through a transitive, headerless requirement.

Source review: KArchive `fe0e77af6fec72698999247f3468b984fc011af0`,
top-level and `src/CMakeLists.txt`, and Zstd `v1.5.7`'s
`build/cmake/{CMakeLists.txt,lib/CMakeLists.txt}`. The KArchive revision is
the pre-run upstream snapshot, not an asserted CI source SHA: frameworks
currently track `latest-kf6`. Also inspected Conan `2.29.1` PkgConfigDeps and
the CCI Zstd/xkbcommon recipes: both remove installed upstream `.pc` files.
Zstd exports a static, PIC library and pthread closure; no standalone Zstd
program is needed by KArchive. It is rebuilt with the same pinned Zig target.

The fix generates both metadata formats from Conan's resolved graph, promotes
the three public header consumers to direct requirements, and removes cache
directory guessing. Before KDE starts, the contract checks every generated
pkg-config provider and its Requires closure, plus the declared public-header
paths against their package roots. It fails rather than warning on host
fallback. Host X11/GL lookup remains explicitly available.

CI preflight exercises eight negative/positive metadata fixtures, including
a new arbitrary provider, downloaded cache layout and spaces in paths. A
separate integration test uses the pinned Conan to package empty fixtures
and compares actual CMakeDeps/PkgConfigDeps component headers without compiling
code. These gates do not prove the full build or graphical runtime succeeds.

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
| host X11/xcb/ICE/SM/Canberra contract | carried; no host Qt or KDE package is allowed |
| host OpenGL | carried through the existing optional-GL forwarder; `libGL` is not DT_NEEDED |
| CMake ABI workarounds for Zig | carried: pointer size, multiarch, implicit includes and RPATH |
| compile glibc compatibility shim before Conan | carried, with global shared/executable link flags |
| rebuild target packages despite Conan binary availability | carried for the reduced Qt graph |
| `PKG_CONFIG_PATH` with system multiarch paths | host xcb fallback retained, but KDE uses PkgConfigDeps from the same graph as CMakeDeps; never scans the Conan cache for `.pc` files |
| fontconfig HTTP 418 workaround | carried verbatim from f4's upstream builder |
| source-download backup and no `conan cache clean --source` | carried |
| ccache sloppiness/base directory/size and explicit cache save | carried |
| `set -o pipefail` plus a saved build transcript | carried |
| diagnostics on `failure() || cancelled()` | carried, including CMake/autotools/Meson logs, MIME-filtered text and OOM state |
| static Qt platform/plugin registration | carried for qxcb, qxcb-GLX and qxcb-EGL; no f4 QML scanner is copied because Konsole is Widgets-only |
| static graph assertion | carried for Qt/KF6 targets and package directories |
| f4 Go setup, Go tests, embedded packaging and QML-specific hooks | intentionally omitted for the Konsole application; framework QML is retained only where upstream requires it |
| f4 QWindowKit and f4 application-specific tests | intentionally omitted |

The application runtime host boundary is therefore: X11/xcb, Canberra and
the OpenGL ABI are host-owned; Qt, KF6 and the application are built in the CI
source graph. Build-only host tools and data (gettext, Flex/Bison, DocBook,
XML/XSLT and Perl) are checked separately and are not part of the application
runtime contract.
CMake's global
prefix exclusion is explicitly cleared because KGuiAddons and KWindowSystem
use the `FindX11`/`FindXCB` MODULEs to discover those host headers and
libraries. The common CMake hook restores the fixed x86_64 multiarch metadata
after Zig's failed ABI probe, so that discovery reaches `/usr/lib`'s
multiarch directory. Conan config prefixes remain first, while the top-level
static graph assertion rejects a host Qt/KF6 target if one is ever selected.
`qt-install-dir` is deliberately absent from kde-builder configuration, so
kde-builder does not select a host or separately managed Qt tree.

Konsole's own Linux sources optionally enable `xkbcommon` through
`pkg_check_modules` and link its legacy `${XKBCOMMON_LIBRARIES}` variables.
The build forces Conan's xkbcommon package through Zig, puts its generated
`.pc` directory before `/usr`, and checks that the module is discoverable;
this prevents the optional input-mode feature from silently selecting the
host xkbcommon ABI.

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
- KArchive's `WITH_*` switches select REQUIRED versus RECOMMENDED; OFF does
  **not** disable the corresponding backend. All five compression/crypto
  inputs (BZip2, LZMA, Zlib, OpenSSL, Zstd) are direct Conan requirements.
  OpenSSL and Zstd are explicitly required; their public headers must survive
  Conan's dependency traits. Konsole's own xkbcommon header consumer is also
  a direct requirement.
- KDocTools' `src/CMakeLists.txt` adds `${LIBXML2_INCLUDE_DIR}` and builds
  `meinproc6` from sources that include libxml2 headers. Libxml2 is therefore
  a direct Conan requirement even though Qt already brings it transitively;
  otherwise Conan's `headers=False` edge leaves the static library linkable
  but drops the include directory and the failure appears only while building
  KDocTools.
- KCoreAddons, Solid and KIO directly include or link LibMount. It is also a
  direct Conan requirement, with a CMake target alias for the upstream
  `LibMount::LibMount` spelling. This avoids Conan's `headers=False` treatment
  of a dependency reached only through Qt, which otherwise leaves a target
  visible while dropping the include directory.
- KWallet's default Linux build also enables three runtime targets that are
  not used by Konsole: `ksecretd`, `kwalletd6` and `kwallet-query`. The first
  two make the source graph require `LibGcrypt` and `libsecret-1`; the latter
  dependency brings GLib and its own Meson/toolchain graph. The recipe keeps
  the `KF6::Wallet` API available for optional KIO integration but explicitly
  disables those unused runtime targets. This is a source-derived feature
  selection, not a workaround for a missing package, and prevents a whole
  class of service-only dependencies from entering the static application
  build.
- The same rule applies to optional integrations in the remaining graph:
  Kirigami's OpenMP palette accelerator, KPty's UTEMPTER support, and
  KCoreAddons/KIO's UDev and ACL probes are disabled with the generic CMake
  `CMAKE_DISABLE_FIND_PACKAGE_<name>` switches. They are not required by
  Konsole, and disabling the whole optional family prevents an installed
  runner library from silently becoming a host-linked target.
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
- KDocTools requires `LibXslt`, `LibXml2`, `xmllint`, DocBook XML 4.5, DocBook
  XSL, Perl and the `URI::Escape` Perl module. Its pinned `CMakeLists.txt`
  makes those inputs required for
  DocBook processing, and the package's `FindDocBookXML4.cmake`/
  `FindDocBookXSL.cmake` modules use the standard `/usr/share/xml` paths.
  The complete apt-package/probe mapping is recorded in
  `host-docbook-tools.txt` and checked in both workflow jobs before the KDE
  graph starts. This closes the class of missing external documentation
  tool/data failures instead of discovering each one at a later configure.
  Because the recipe supplies Conan's static packages through CMakeDeps, a
  Conan `LibXml2Config.cmake` can supply the library while omitting CMake's
  companion `xmllint` variable. The common CMake hook seeds host tool
  variables before package lookup, and a regression test covers this
  CONFIG/MODULE mismatch as a class of failures.
- Conan's CMakeDeps can also generate CONFIG files for packages that KDE
  intentionally consumes through an upstream `Find<Package>.cmake` MODULE.
  CONFIG-first lookup can then expose a target while dropping the finder's
  legacy include/library variables. A reusable legacy CONFIG-adapter
  generator bridges the imported target, include directories, libraries and
  version variables while preserving CONFIG-first lookup for KDE targets;
  the regression test exercises this class with both forms.
- KNotifications has no feature switch around its Linux audio support: its
  source unconditionally calls `find_package(Canberra REQUIRED)`, and both
  KNotifications and KNotifyConfig link `Canberra::Canberra` when found.
  `libcanberra-dev` is consequently a declared host input and
  `libcanberra.so.0` is the only additional host runtime allowance. This is
  recorded explicitly so a later audit cannot mistake it for an accidental
  host fallback.
- QCA's source defaults `BUILD_PLUGINS=auto`; on the runner this selected its
  system OpenSSL plugin even though the current Konsole graph does not use
  QCA once the KWallet services are disabled. The qca override selects Qt6,
  disables its tests/tools, and sets `BUILD_PLUGINS=none`, closing the class
  of auto-detected crypto/plugin host dependencies.
- Designer plugins and text-to-speech are optional framework features and are
  disabled to keep the built graph aligned with Konsole's actual application
  targets.
- The top-level Konsole `CMakeLists.txt` requests only Qt Core, Multimedia,
  PrintSupport and Widgets, but the pinned KDE Frameworks graph adds a
  mandatory QtSvg request in KIconThemes. `qt/*:qtsvg=True` is therefore an
  explicit recipe input and the component-adapter regression exercises
  `find_package(Qt6Svg)`; this prevents a framework-only Qt module from being
  discovered one CI failure too late.
- Several KDE Frameworks in the same graph request private Qt modules with
  standalone lookups such as `find_package(Qt6GuiPrivate)`, while Conan's
  aggregate Qt config exposes the target only through `Qt6Config.cmake`.
  The recipe now emits compatibility adapters for the private-component
  family and the regression exercises `Qt6GuiPrivate`, so this package-form
  mismatch is handled as a class.
- The transitive `qca` project defaults to Qt5, but its Qt6 branch is the one
  consumed by this KDE graph and requires the Qt Core5Compat module. Its
  project-specific kde-builder override selects Qt6 and disables qca-only
  tests/tools; `qt/*:qt5compat=True` makes that source-level requirement
  available in Conan before qca configures.
- Sonnet's `src/plugins/CMakeLists.txt` treats Aspell, Hspell, Hunspell and
  Voikko as optional individually, but has a fatal invariant when none of
  them is available. The ConanCenter Hunspell 1.7.2 recipe installs the
  `include/hunspell/hunspell.hxx` header and static `hunspell` library that
  Sonnet's `FindHUNSPELL.cmake` discovers. Hunspell is therefore a direct
  Conan requirement and is explicitly rebuilt with Zig; this closes the
  whole "optional backend set is empty" class without depending on a host
  spellchecker installation.

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
   `.prl` closure, loadable-target `INTERFACE_SOURCES`, optional-GL CXX
   compilation and static-graph assertion. The Konsole-specific probe also
   verifies that its registration unit exists before CMake validates consumer
   sources, that all three QPA imports are present, that repeated imports are
   not emitted, and that even a visible Conan `::` target is filtered from the
   link interface.
8. `./tools/test-optional-gl-cxx-only.sh` passed.
9. `make -C onebin test` passed: 273 tests passed and 3 were skipped by their
   existing fixture/locale guards.
10. The f4 reference itself was not modified. No hosted build was dispatched
   during either pass.

The host Python, Perl and DocBook manifests are checked against both workflow
apt install blocks. Hosted preflight imports every declared Python module with
`/usr/bin/python3`, loads every declared Perl module, and probes every
declared DocBook tool/data path before the KDE graph starts; a dependency
therefore cannot silently be present only in the Conan virtual environment or
absent from the runner.

After hosted run 33532968168 exposed the CONFIG/MODULE mismatch, a miniature
CMake project with a fake CONFIG-only LibXml2 package verified that the host
`xmllint` variables survive a package lookup that omits them. The regression
is now part of `tools/preflight-konsole.sh`.

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

## Run 65: build succeeded, artifact audit was too narrow

Run `34010516240` at `cb703b6` built all 38 projects and installed Konsole,
but the post-build audit rejected `libkonsoleapp.so.26.08.0` as an
undeclared dependency. The pinned Konsole source explicitly declares
`konsoleapp` as `SHARED`, installs it under `lib/`, and links the executable
to it; this is an application-owned runtime library, not a host KDE/Qt
dependency. The old checker only inspected the executable and had no model of
the install prefix.

The runtime contract now walks the complete `DT_NEEDED` closure, recursively
audits internal libraries found in the supplied install prefix, and keeps the
host allowlist only for X11/GL-adjacent system ABI. The build also restores an
origin-relative RPATH for the Konsole application and creates a portable
bundle containing the executable, all install-prefix shared objects, KDE
modules and data. CI smoke-tests that bundle and uploads it, so downloading
the artifact does not require manually setting `LD_LIBRARY_PATH` or
`XDG_DATA_DIRS`.

Run 69 (2026-09-07): build `34066071126` compiled and installed all 38 KDE
projects, but the artifact verifier correctly rejected the result because the
installed Konsole executable had an absolute build/Conan RPATH instead of
`$ORIGIN/../lib`. The previous fix only changed global `CMAKE_*` defaults from
the early `CMAKE_PROJECT_INCLUDE` hook; KDE's later CMake settings could
overwrite those defaults before target generation. The recipe now defers a
walk of all application-owned EXECUTABLE, SHARED and MODULE targets and sets
their five RPATH properties explicitly, including immediately before each
`install(TARGETS ...)` rule because CMake snapshots those properties there.
`test-konsole-runtime-rpath.sh`
configures, builds and installs a miniature instance of all three target kinds
with link-path RPATH defaults deliberately enabled, then checks each installed
ELF for only the origin-relative path. This closes the class of target-level
RPATH drift rather than special-casing `konsole` or `libkonsoleapp.so`.

The same audit enumerated the complete host edge (`libxcb-res`, `libXfixes`,
`libxcb-glx`, `libEGL`, `librt`, `libutil` and the dynamic loader) instead of
discovering those names one at a time in later runs; they are explicit parts
of the hybrid X11/EGL and glibc host contract.

## Run 66: KIO split source omitted a direct Qt include

Run `34039464605` at `6e738aaab73a4a28967e86b1bddc7ffadf544004` passed the
entire fast preflight and then stopped before Konsole at KIO project 29/38.
The diagnostic artifact was `konsole-zig-build-diagnostic-logs`, ID
`9993285611`, SHA-256 digest
`sha256:f1eba5a4a3b557ac1ce1152c1ebda10d926c75a1020b91339496bfd98d588ed`.

KIO had updated to `8f3af2189`, whose new
`src/kioworkers/file/file_unix_copy.cpp` uses `QUrl` by value without
including `<QUrl>`. The compiler consequently reported an incomplete `QUrl`
type even though KIO already links Qt Network. No Konsole executable was
produced because the dependency graph stopped before the application build.

The fix repairs the class of split-translation-unit include omissions through
one idempotent CMake source/include contract and a configure-only regression;
it is not a one-line diagnostic suppression. The next hosted run must prove
that KIO gets past this compile stage and that the later artifact stages still
produce the portable binary.

## Run 67: optional-GL forwarding stopped at the executable boundary

Run `34047753271` at `544d182130f90fb716861afa5f523cc2c6b6d922` built the
complete Qt/KF6 graph and installed Konsole, but the artifact contract rejected
the loadable closure because `libkonsoleapp.so.26.08.0` had
`DT_NEEDED libGL.so.1`. The executable itself had no `libGL` dependency, which
made the earlier executable-only optional-GL regression pass while leaving the
real shared application library unsafe. The pinned Konsole CMake at
`v26.08.0` (`9a304001aad60b7a3a39bca39ce3a3764ec058d5`) declares
`konsoleapp` as `SHARED` and links it to static Qt through the same graph as the
executable; its build files therefore expose the whole failure class.

The fix moves the contract to every loadable consumer of `Qt6::Gui`:
executables, SHARED libraries and MODULEs receive the generated forwarder and
render-backend constructor, carry `CMAKE_DL_LIBS`, and have transitive system
`OpenGL::GL`/`libGL` link items removed so a linker without `--as-needed` cannot
recreate `DT_NEEDED`. Static libraries remain source-free because they are not
loader boundaries and would multiply the definitions into every consumer.
The existing CXX-only miniature regression now builds one executable, one
shared library and one MODULE, checks that each exports a forwarded GL symbol,
and rejects `libGL` in each `DT_NEEDED` list. This guards the mechanism rather
than allowlisting the one observed soname.

## Run 68: artifact verifier drifted from the host ABI contract

Run `34057485004` at `c8db751a878294badb6965600b86d1acc53bf938` built all 38
projects successfully and installed Konsole, but the post-build artifact
verifier rejected `libxcb-cursor.so.0` as undeclared. The onebin audit already
allowed that host library, and the host package contract already installed
`libxcb-cursor-dev`; only the verifier's duplicated allowlist was stale.

The fix removes that class of drift rather than adding one more exception:
`contrib/konsole/host-runtime-sonames.txt` is now the single explicit hybrid
runtime SONAME contract. Both `build-konsole.sh` and
`verify-konsole-artifact.sh` parse it, reject malformed entries and forbid
`libGL` there. `test-konsole-host-runtime-contract.sh` is run by preflight and
asserts that the list is non-empty, duplicate-free, contains the required X11,
EGL and Canberra boundary, and is consumed by both paths. The build still
rejects any host SONAME outside that file.
