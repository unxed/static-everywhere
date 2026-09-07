# Build failure classes and diagnostic inventory — Konsole showcase

This should have existed before the first CI run. It exists now, and the
preflight is checked against it rather than against the last failure.

Legend: **P** = caught by preflight locally · **C** = caught by CI only ·
**—** = not guarded · *(fix)* = the mechanism that closes the class.

## 1. Configure-time (CMake / Conan / kde-builder)

| # | Class | Seen here | Status | Guard |
|---|-------|-----------|--------|-------|
| 1.1 | Option value type rejected by the build driver | `ignore-projects` str vs list | P | kde-builder `--pretend` on the rendered config |
| 1.2 | Option string unparseable by the driver's splitter | comment in folded scalar → shlex | P | `--pretend` + shlex check on every `*-options` |
| 1.3 | Template placeholder unsubstituted / unquoted | `@INSTALL_PREFIX_CMD@` | P | placeholder-sync test |
| 1.4 | Pin not resolvable by the driver | sha vs tag, tag object vs commit | P | `ls-remote --exit-code` + peel, same command as kde-builder |
| 1.5 | Lock file consumers disagree on layout | workflow compared HEAD to tag | P | repository-wide consumer enumeration |
| 1.6 | `find_package` finds the wrong package (host vs vendored) | ICU (headers), X11 by design | P | CONFIG preference + prefix promotion; header side closed by 1.7 |
| 1.7 | Correct package found, wrong headers compiled (search-path order) | ICU 74 vs 78 | P | **staged host-include directory**: only the contract's dependency closure is visible, vendored names excluded; both wrappers redirect every `/usr/include` and their fallback. Reproduced and closed on a host with ICU 74. `scan-kde-graph-host-includes.sh`: 35 modules, 1457 includes, none host-only |
| 1.8 | Package found but include dir one level off | hunspell `include/` vs `include/hunspell/` | P | adapter resolves the declared header; mandatory `header=` |
| 1.9 | Exported target references undeclared dependency | kjobwidgets → Notifications | P (mechanism) / C (effect) | reconcile after each install via `make-install-prefix` |
| 1.10 | Install split across libdirs | `lib` vs `lib/x86_64-linux-gnu` | P | `KDE_INSTALL_LIBDIR` pinned; asserted |
| 1.11 | Static-only path upstream never tests (install of missing target / unexported static helper) | kpackage, knewstuff | P (mechanism) | static-helper export hook; kpackage block check; **no static-build tracker issues exist upstream — expect more** |
| 1.12 | Required component absent from vendored Qt | QuickWidgets/Designer (false alarm) | P | verified against the Conan recipe conditions, not the filtered listing |
| 1.13 | Ignored project required by another | kdoctools | P | live scan of 39 module CMakeLists |
| 1.14 | Feature the consumer needs disabled in a dependency | Qt without SSL for kio | P | asserted in both places it is spelled |
| 1.15 | Deferred callback resolves a recipe file in the dependency source tree | ICU consistency probe | P | captured absolute path helper plus `test-konsole-deferred-recipe-file.sh` |
| 1.16 | CMake probe loses imported target generator expressions in `try_compile` | ICU probe used host headers and no archive | P | concrete FindICU paths plus Conan-shaped imported-target regression |
| 1.17 | Source-module compile driver silently uses the host target | KDE module compile flags had no `-target`, while Conan/link flags did | P | rendered C/C++ flags pin the target for every kde-builder module |
| 1.18 | Audit rejects a valid static ELF before packaging because it exceeds the default input cap | Konsole is 745 MiB after static Qt linking; `--max-file` was parsed but ignored | P | `onebin` forwards and enforces an explicit 1 GiB cap; CLI regression proves non-default caps are active |
| 1.19 | Root-only audit mistakes an application-owned shared library for a host dependency | `libkonsoleapp.so.26.08.0` is installed beside the executable and is checked recursively by the artifact verifier | P | derive the onebin allowlist from every `.so` in the install prefix; the recursive artifact verifier remains authoritative for each internal library's closure |

## 2. Compile-time

| # | Class | Seen here | Status | Guard |
|---|-------|-----------|--------|-------|
| 2.1 | Header not found (missing `-I`) | QtQmlIntegration, hunspell | P | 1.8; QmlIntegration injected |
| 2.2 | Wrong header found (shadowing by version) | ICU | P | 1.7 |
| 2.3 | Feature-test macro asymmetry (C vs C++) | `Dl_info` under `_GNU_SOURCE` | P | shim ordering test sweeps both languages |
| 2.4 | Predefined macros missing from a code generator | `moc_predefs.h` empty | P | `-E` wins over `-c`; introspection test |
| 2.5 | Link-only flag misread at compile time | `-nostdlib` dropped libc++ path | P | wrapper drops it on `-c/-S/-E` |
| 2.6 | Compile option de-duplicated by the build system | repeated `-include` | P | `SHELL:` sweep + live cmake probe |
| 2.7 | Warnings-as-errors from a stricter compiler | vte `-Wcast-function-type*` | P (gnome-terminal) | suppressed in native file |
| 2.8 | Code generator segfault (host tool built by us) | meinproc6 | P | tool excluded; forward scan proves nothing requires it |
| 2.9 | Language standard vs input language | `-std=c++17` with C input | P | 2.6 |
| 2.10 | Missing define a static library's headers need | `U_STATIC_IMPLEMENTATION` for static ICU | P | defined for konsole in the project hook; asserted |
| 2.11 | Split translation unit relies on a transitive Qt forward declaration | KIO `file_unix_copy.cpp` after the copy-code split | P | generic idempotent direct-source-include contract plus CMake regression |

## 3. Link-time

| # | Class | Seen here | Status | Guard |
|---|-------|-----------|--------|-------|
| 3.1 | Undefined symbol: transitive static dep not declared | Qt6::Quick → OpenGL; then QmlMeta, Multimedia→Concurrent/DBus | P | `scan-qt-module-edges.sh` reads Qt's module declarations and the Conan recipe and fails on any edge neither declares nor the hook repairs; `link-qt6-orphan-modules.cmake` repairs them and creates targets for modules Conan builds but never exposes. Retroactively predicts the OpenGL edge |
| 3.2 | Undefined symbol: version-suffixed API from wrong headers | `ubidi_*_74` | P | 1.7 |
| 3.3 | Undefined symbol: newer glibc than baseline | `close_range` | P | glibc shim, three recipes |
| 3.4 | Two C++ runtimes in one link | SoLo libstdc++ vs libc++ | P | runtime checker at handoff |
| 3.5 | Linker flag unsupported by the driver | `--push-state`, `-Xlinker` | P | wrapper translation; WHOLE_ARCHIVE redefined |
| 3.6 | Non-PIC objects in a shared MODULE | konsolepart.so links static KF6 | P | zig refuses non-PIC for x86_64-linux-gnu at all ("requires position independent code"); pinned by `test-toolchain-pic-enforced.sh` so a zig upgrade cannot relax it silently |
| 3.7 | Duplicate symbol across static archives | — | — | zig 0.13 rejects `--trace`/`-t`/`-Map`/`--why-extract` outright (adding `--trace` broke kiconthemes); trace on demand by replaying the FAILED link line from `build.log` (`ninja -v`) with ld.lld |
| 3.8 | Archive order (static libs before their users) | — | — | CMake handles for declared deps; undeclared ones are 3.1 |
| 3.9 | `-o -` / stdout output mishandled by driver | stray `-` file | P | wrapper |
| 3.10 | Whole-archive / plugin registration missing at runtime | QPA plugins | P | user's `9299262` |
| 3.11 | Optional host-library forwarder attached only to executables | `libkonsoleapp.so` retained `libGL.so.1` while `konsole` itself passed | P/C | loadable-target forwarder contract covers executable, SHARED and MODULE consumers; CXX-only miniature build audits all three |
| 3.12 | Executable link loses PIE because flags reach only package builds | Konsole installed as ET_EXEC (`OB0054`) | P/C | explicit `-pie` plus the glibc shim in the shared kde-builder executable-link contract; YAML/shlex and wrapper-link regression |

## 4. Runtime (post-link, in the artifact)

| # | Class | Status | Guard |
|---|-------|--------|-------|
| 4.1 | Dynamic dependency leaked into "static" binary or an internal runtime library is omitted | P/C | recursive ELF closure rejects host Qt/KF6/OpenGL leaks; every application-owned loadable target gets `$ORIGIN/../lib` through a deferred target-property callback, the Konsole bundle carries every install-prefix `.so`, and host SONAMEs come from one shared explicit contract |
| 4.2 | Host-loaded library ABI (X11/GL) | by design | hybrid profile contract |
| 4.3 | Missing runtime data (ICU data, QPA plugins, KF6 plugins in MODULE form) | C (made observable) | The smoke run on the runner sees every build-time path -- Conan cache (ICU `.dat`, fontconfig's `res/etc`, Qt plugin prefix) and the install tree -- so it passes for binaries broken elsewhere. A second smoke run copies only the portable runtime bundle, hides the Conan cache and build install tree, and disables `LD_LIBRARY_PATH`; warnings naming a compiled-in path fail it. Pre-checked from recipes/code: ICU `data_packaging` default `archive` would leave konsole's unchecked `ubidi_*` calls with no data -- now `static`; fontconfig falls back to `/usr/share/fonts` with a warning (degraded, not fatal, recorded); QPA xcb is imported; KF6 MODULE plugins are bundled |

## Diagnostic inventory — what each tool can emit, and what we collect

| Tool | Emits | Collected | Notes |
|------|-------|-----------|-------|
| kde-builder | `kde-logs/<date>/<module>/{cmake,build,install,git-*}.log`, `status-list.log`, `screen.log`, `kde-state/log` | yes (failing module first, unconditional) | |
| ninja | FAILED command (default); **every command with `-v`**; `.ninja_log`; `build.ninja` | **now**: `-v`, `.ninja_log`, `build.ninja` | `-v` is the compile-line evidence that was missing for the ICU question |
| CMake | `CMakeCache.txt`, `CMakeConfigureLog.yaml`, **`CMakeCXXCompiler.cmake`** (implicit dirs as detected!), `compile_commands.json`, `--debug-find` | **now**: compiler files, compile_commands | `--debug-find` not enabled: too large for every module; enable per failing module on demand |
| Conan | install log, `conan_toolchain.cmake`, `*-data.cmake`, `CMakePresets.json`, `conan graph info` | **now**: toolchain, data, presets | graph info not collected; listing is `-newer`-filtered (proved misleading once) |
| zig/clang | `-v` (search paths), `-H` (header trace), `-###` | no | `-H` on one failing TU is the direct answer to 1.7; add on demand via `ninja -v` line replay |
| lld | `--trace`, `-Map`, `--why-extract`, `--verbose` | no | add `-Wl,--trace` to the failing link on demand |
| moc | `moc_predefs.h` | yes | |
| ccache | `ccache -s`, `CCACHE_LOGFILE` | stats step only | |

## Konsole tracker survey

Searched bugs.kde.org and invent.kde.org for Konsole build failures
involving static linking, ICU, `BUILD_SHARED_LIBS`, link errors. No issue
documents a static Konsole/KF6 build. KDE TechBase's linker-debugging page
(2012) prescribes exactly `VERBOSE=1` and `-Wl,-t`, neither of which this
pipeline had. Conclusion: the static path is untested upstream; every
static-only defect must be assumed present until proven absent. 3.6 is now proven absent by the toolchain; 1.11's remaining modules were scanned for static helpers (none).


## Systemic review after ~20 red runs — what each fix should have been

Read back, the konsole failures fall into four generators, not twenty bugs.
Each entry names the *general* fix; the per-module patches were symptoms.

| Generator | Symptoms it produced | Systemic fix | Status |
|---|---|---|---|
| **A. The compile driver did not describe the target** | ICU 74 vs 78 headers; `statx` undefined; host `/usr/include` shadowing | `--target` on every module compile (95dad58) **plus** the glibc shim on every module link (15b3307) **plus** the staged host contract. Together these make a module's environment identical to the Conan graph's | done |
| **B. Conan metadata is not CMake metadata** | QtQmlIntegration; hunspell include dir; `Qt6::Quick -> OpenGL`, `QmlMeta`, Multimedia edges; `zstd.h`/`openssl/evp.h` not found in karchive; split KIO includes | One rule: **every Conan package's CMake *and* pkg-config metadata must be visible to every KDE module** (cb703b6 did this) and **every Qt inter-module edge must be diffed against Qt's own sources** (`scan-qt-module-edges.sh`). New packages must not need a new patch | done |
| **C. The build tree is the install prefix** | `OB0060`: `kde-install/libexec/kf6/kdesu`, plugin dirs compiled into binaries | **Build with a neutral prefix and stage with DESTDIR**: `-DCMAKE_INSTALL_PREFIX=/usr` in `cmake-options`, `DESTDIR=$KDE_INSTALL_DIR` exported by `tools/kde-install-and-reconcile.sh` (kde-builder has no DESTDIR of its own — verified in its source), `CMAKE_PREFIX_PATH` and the smoke/artifact paths moved to `$KDE_INSTALL_DIR/usr`. Then no compiled-in path is ever a build path, for every module, permanently. **Caveat to check first:** kde-builder passes its own `-DCMAKE_INSTALL_PREFIX` from `install-dir`; confirm ours comes later on the command line, or set `install-dir` to the staged prefix instead | **open — next step** |
| **D. A check that only runs in CI is not a check** | every one of the above cost 2–3 h to observe | Everything the build does must be runnable locally: `kde-builder --pretend` on the rendered config, the flag probe through the wrappers, the graph include scan, the Qt edge scan, the ICU probe. The rule: **if a failure can be produced by a command, that command belongs in the preflight** | done |

The remaining red is generator C alone. It is one coordinated change, and it
removes the whole `OB0060` class rather than each embedded path.
