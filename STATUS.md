# STATUS

<!-- ------------------------------------------------------------------ -->
## ⟶ RESUME HERE — current state, for a session starting with no context

Everything below this section is a reverse-chronological log (newest
first). Read *this* section first; consult the log below only for the
detail behind a specific claim.

### 180 MB of one warning, and the error somewhere inside it

The gnome-terminal run produced a diagnostics artifact too large to
download. Its content was a single warning repeated: `cast from 'void
(*)(void *)' to 'void (*)()'`, from every `G_DEFINE_AUTOPTR_CLEANUP_FUNC`
expansion in GTK's `gtk-autocleanups.h`, roughly 2800 per translation
unit.

Measured rather than guessed: `-Wcast-function-type-strict` is not in
`-Wall` or `-Wextra` — it fires only when asked for by name. vte asks,
through `cc.get_supported_arguments()`. gcc has no such flag, so upstream
silently drops it and never sees this; clang has it, so we get all of it,
about third-party macro expansions we neither own nor can change.

Set `-Wno-cast-function-type-strict` in the meson native file's built-in
options, which meson places after the project's own arguments — verified
against a meson project that enables the warning via
`add_project_arguments`, where the `-Wno-` wins.

### The class is worse than the warning

An artifact nobody can download is worth less than a truncated one that
says so. The collector now caps each copied log at 200k lines, keeping
the first and last 50k with an explicit notice of how many were dropped
and a pointer to `06-errors-*.txt` — which is extracted from the original
log, not from the truncated copy, so the failure survives the cap.
Verified on a 250k-line log: head, tail and the final line all present.

So the noise has three independent defences now: it is not generated, it
would not fill the artifact if it were, and the error is extracted
separately regardless. The vte failure itself is still unnamed — the last
artifact predates all of this — but it can no longer hide behind volume.

### The same asymmetry, seen from the other side: strict C had no `Dl_info`

C++ now compiles; a C source did not:

```
solo-src/lib/dlfcn.h:58:39: error: unknown type name 'Dl_info'
   58 |     int stub_dladdr(const void* addr, Dl_info* info);
```

Both force-includes were present — `<built-in>:2` in the diagnostic shows
the shim arriving second, as intended. The problem is what the first one
declared.

musl declares `Dl_info` only under `_GNU_SOURCE` or `_BSD_SOURCE`. On
Linux the compiler defines `_GNU_SOURCE` implicitly for C++ but not for
strict C, and far2l sets it only on Cygwin and Haiku. So `shoco.c`, built
as `-std=c11`, read musl's header, which defined `_DLFCN_H` **without**
defining `Dl_info`; SoLo's guard is `#if !defined(_DLFCN_H)`, so it
skipped its own definition for exactly that reason, and then declared
`stub_dladdr` against a type neither header had provided.

Measured across standards: `-std=c99` and `-std=c11` fail, `-std=gnu11`
and the default pass — which is why this looked like a C-only oddity
rather than the same header asymmetry the C++ side had already shown.
`-D_GNU_SOURCE` puts the two languages on the same footing; C++ already
had it.

The test now sweeps both compilers and both strict and extended
standards, and asserts that strict C **without** the macro still fails —
so if a future libc stops withholding `Dl_info`, the test says the guard
has become pointless instead of silently enforcing it. Three negative
controls: drop the macro, drop the libc include, reverse the order.

Worth naming the pattern, since this is the third failure from the same
pair of headers: a shim that defers to the libc header inherits the libc
header's *conditions*. Deferring is only safe where the thing deferred to
actually exists, and feature-test macros decide that per translation
unit, not per project.

### A file named `-` was committed to the repository root, and it was mine

Spotted by eye in the file list, which is the worst way to find
something. It held preprocessor output referencing `/home/claude/zig013`,
so it came from this sandbox and rode in on one of my commits.

The cause is in the toolchain wrappers, and it is a class. zig 0.13
produces output atomically: it writes a temporary file and renames it
onto the `-o` path. Given `-o -` it therefore creates a literal file
named `-` in the current directory. Given `-o /dev/stdout` it renames
over the device and the caller reads **nothing** — measured, 0 bytes.
gcc writes to standard output in both cases.

This is not obscure. CMake's `CXX-DetectStdlib` step preprocesses with
`-o -`, so every configure through these wrappers dropped a `-` wherever
it ran, and every caller expecting a preprocessed source got an empty
string. The quiet half of the bug is worse than the visible one: a
detection step that silently returns nothing does not fail, it concludes.

Both wrappers now intercept `-o -`, give zig a real temporary file and
copy that to stdout. Dropping the flag instead would only be equivalent
for `-E`; with `-S` or `-c`, zig would write `foo.s` or `foo.o` to disk,
so the interception covers every mode. Verified for `-E` and `-S` on both
wrappers: output arrives on stdout, byte counts match, no file appears,
and ordinary compilation is unaffected.

`tools/test-compiler-stdout-output.sh` checks both halves — the output
reaches stdout **and** the directory stays clean — because either alone
would have missed this, and it also asserts the repository root has no
`-`, since that is how this one was eventually noticed. Wired into the
preflight.

Filed upstream-shaped in the wrapper comments rather than as a zig bug
report; worth reporting if it survives a zig upgrade.

### One fix, three builds, and a regression of my own

**far2l: my previous fix broke it in a new way.** The ordering change was
right, the spelling was not. CMake de-duplicates compile options, so

```cmake
target_compile_options(t PRIVATE "-include" "dlfcn.h" "-include" "${solo}")
```

drops the second `-include` as a repeat and leaves the filename as a bare
argument, which the driver treats as an input file. Confirmed against
cmake 3.31, which generates `CXX_FLAGS = -include a.h b.h`. A `.h` input
is a C header, so the C++ compile died with

```
error: invalid argument '-std=c++17' not allowed with 'C'
```

— a message naming neither the dropped option nor the file that became an
input. `SHELL:` exists for this and keeps each pair intact.

That is the class worth having a test for, and
`tools/test-compile-option-pairing.sh` covers it two ways: a sweep over
every `*.cmake` and `CMakeLists.txt` here for repeated bare paired
options (`-include`, `-isystem`, `-Xclang`, `-imacros`, `-idirafter`,
`-U`), and a live cmake probe proving the de-duplication still happens —
so if CMake ever stops doing it, the test says so instead of quietly
enforcing folklore. Reintroducing the exact far2l regression fails it.

**konsole: the header is in a module the compile line never receives.**
`qqmlintegration.h` is not in `include/QtQml`; it belongs to
QtQmlIntegration, which the package ships but whose include directory
Conan's `Qt6::Qml` target does not propagate — upstream Qt's does.
Injected via `CMAKE_CXX_STANDARD_INCLUDE_DIRECTORIES`, which reaches
every compile without touching `CMAKE_CXX_FLAGS` and the toolchain flags
in it; verified with a real configure both ways. The Qt package root is
read from Conan's own `qt_PACKAGE_FOLDER_RELEASE`, the same variable
`import-qt-static-plugins.cmake` already uses, rather than reconstructed
from a cache layout that is not ours to predict — and the lookup fails
loudly rather than substituting an empty string.

Also recorded, because it cost a wrong conclusion: `-DBUILD_WITH_QML=OFF`
was already set and does nothing, since ki18n gates the subdirectory on
`if (TARGET Qt6::Qml)` and Conan's config defines every component target.
Both that and the missing propagation are filed in
`contrib/konsole/UPSTREAM.md`.

The preflight now also checks that **every** `@PLACEHOLDER@` in the
template has a substitution in the script — an unsubstituted one renders
a literal `@NAME@` into a path, which is the same class as the bug it was
added alongside.

**gnome-terminal: the collector had two collection blocks.** A merge left
both the whole-log copies and the older 3000-line tails of the same two
logs, doubling the artifact and inviting a reader to open the truncated
copy of a log that was present in full. Tails removed.

The vte failure itself is still unnamed: this artifact came from a run
that predates the error extraction, so the error is once again outside
the tail window while 2824 lines of `reflect.c` warnings are inside it.
The next run will name it.

### far2l Profile U: the SoLo shim was included before the header it overrides

The musl host-isolation fix moved the build forward; it then failed on

```
generic-musl/dlfcn.h:33:3: error: typedef redefinition with different types
                           ('struct Dl_info' vs 'struct Dl_info')
```

Reading SoLo's `lib/dlfcn.h` at the pinned commit settles it in one look.
The header opens with `#undef RTLD_LAZY` and friends before redefining
them, and wraps its own `Dl_info` in `#if !defined(_DLFCN_H)`. Both are
only meaningful once the libc header has already been read: its author
wrote it to layer *on top of* `<dlfcn.h>`, not to replace it.

The hook force-included it alone, so it came first. `_DLFCN_H` was still
undefined, SoLo defined `Dl_info`, and far2l's `utils/include/debug.h`
then pulled in `<dlfcn.h>`, which defined the same typedef again. The fix
is `-include dlfcn.h -include <solo>/lib/dlfcn.h` — ordering, not a new
guard.

Verified against the real compiler and the real SoLo header: the old
order reproduces the CI error exactly, the new one compiles, and `nm`
confirms the object still calls `stub_dlopen` rather than libc's — the
collision is gone without defeating the point of the shim.

### The class, not the instance

Any force-included shim that redefines libc macros or types has this
requirement, and the failure never appears where the shim is configured —
it appears in whichever unrelated source file happens to include the real
header. `tools/test-shim-include-order.sh` checks the hook structurally
(libc header first) and behaviourally (compiles, redirection intact),
with a negative control asserting the shim-first order still fails, so
the test cannot stop telling the two apart. Wired into the preflight.

### The gnome-terminal collector lost the failure; upstream and I fixed
different halves of it

The vte build died while `reflect.c` was emitting 2806 warnings, so all
3000 tailed lines were warnings and the error — from a parallel ninja job
that finished earlier — fell outside the window. `grep -c error` on the
whole artifact returned 0.

`8b5c47c` had already replaced the tails with whole-log copies, which
removes the truncation. Layered on top: the failure still has to be found
inside a six-figure line count, so the logs are now also grepped into
`06-errors-*.txt` with `-B 5 -A 15` of context, the way the konsole
workflow has done for a while — which is why konsole's failure read in
one step. An empty result is written out as "widen the patterns" rather
than left to read as a clean log.

### Two collector filters have now misled me, and that is the real lesson

Diagnosing konsole I concluded from `01-conan-listing.txt` that the Qt
package lacked `qqmlintegration.h`. It does not follow: that listing is
`find -newer /tmp/job-start-marker`, so it shows only files touched
during the job. `qstring.h` and `qwidget.h` are missing from it too. The
earlier `*/lib/cmake/*` exclusion cost a whole round of wrong conclusions
in the same way.

What settled konsole was the compiler, which is direct evidence: the
include path *does* contain `.../include/QtQml`, and the header is not
there. It lives in a separate module, `include/QtQmlIntegration/`, which
the ki18n compile line never receives — the build sees `Qt6Qml` and
`Qt6Quick` among its components but not `Qt6QmlIntegration`. Also worth
recording: `-DBUILD_WITH_QML=OFF` was already in the yaml and does not
help, because ki18n gates the subdirectory on `if (TARGET Qt6::Qml)`,
which Conan's Qt config defines regardless.

Rule for the next diagnosis: a collector listing is a filtered view, not
an inventory. Absence in it is not evidence of absence on disk.

### far2l Profile U died on the host's glibc header, offered by our own toolchain

The SDL Profile U build failed at 30% with five errors in
`/usr/include/execinfo.h` (`unknown type name '__BEGIN_DECLS'`), then
`cxxabi.h: expected unqualified-id` with the parser already derailed,
then `use of undeclared identifier 'backtrace'`. Three symptoms, one
cause, and the cause is ours.

`zig c++ -target x86_64-linux-musl` does not find `<execinfo.h>` — the
correct answer, since musl has no `backtrace()`. Through
`onebin/toolchain/zig-c++` it finds glibc's, because the wrapper appends
`-idirafter /usr/include`.

That line is right for Profile H, which links against a declared host
contract: `xcb/*` and `X11/*` live in `/usr/include` and pkg-config emits
no `-I` for them. For Profile S and U the whole promise is zero host
dependencies, so a host search path cannot produce a right answer there —
only a wrong one that compiles. Both wrappers now gate the host include
and host `-L` fallbacks on a non-musl target; the triple was already
being parsed for the library path, so the fix reuses it.

### The other half: a guard on a macro that does not exist

`far2l/utils/include/debug.h` includes `<execinfo.h>` under
`!defined(__MUSL__)`. The intent is unmistakable — musl has no
`backtrace()` — but **nothing defines `__MUSL__`**. musl deliberately
provides no macro identifying itself; `__MUSL__` is a downstream
invention that exists only if a build system passes `-D`. Verified rather
than assumed: on a musl target neither `__MUSL__` nor `__GLIBC__` is
defined.

Project policy is that far2l is never patched
(`contrib/far2l/patches/README.md`), so the fix supplies the input the
source already tests for: `onebin-linux-static.cmake` passes `-D__MUSL__`
for musl targets. Checked against far2l's real guard text — it now takes
the musl branch, while glibc behaviour is unchanged. The finding is
written up as `contrib/far2l/UPSTREAM.md` §6, with `__has_include` as the
form that would not need the flag.

### A test that reproduces the failure, and a control that proved the test weak

`tools/test-toolchain-host-isolation.sh` compiles `<execinfo.h>` for both
targets: musl must fail *by absence* (a parse error means the host header
was offered), glibc must still succeed. Wired into all three preflights,
since the toolchain is shared.

Its first version checked `-D__MUSL__` by grepping the toolchain file —
and the negative control passed when the flag was deleted, because the
string also appears in that file's explanatory comment. Rewritten to
configure with the real toolchain and read `CMAKE_C_FLAGS`. Reverting
either half of the fix now reproduces the exact CI error and fails the
gate.

### The util-linux patch: five attempts at the arithmetic, one look at the source

`util-linux-libuuid-only.patch` stopped applying, and the four commits
before this one each adjusted its hunk headers or context. That is the
tell: the patch was hand-written, so every fix was a guess about what the
source contains, and each guess had to be tested by a two-hour CI run.

Fetching the pinned tree settles it in seconds. `git apply -v` reports
what it searched for, and the answer was thirteen lines while the header
declared twelve — the body and the header disagreed, and no amount of
recounting the visible hunk would show that, because the mismatch is
between two representations of the same thing.

**The fix is not a corrected hunk. It is not writing hunks.** Check out
the pinned commit, make the edit, let `git diff` produce the patch. The
result cannot have inconsistent headers, cannot cite context that is not
there, and carries real blob indices.

Doing that also produced a much smaller change. The old patch wrapped
~2,500 lines of `meson.build` in an `if/else`, closing it with an `endif`
inserted at line 3453 — two hunks, far apart, both fragile. Meson has
`subdir_done()`, which stops interpreting the current file. So:

```meson
if get_option('libuuid-only')
  subdir('libuuid')
  subdir_done()
endif
```

Four lines after `subdir('lib')`, and everything below is skipped: the
other libraries, every program, all the man-page and completion install
rules. Checked before relying on it: `pkgconfig.generate` for `uuid.pc`
lives in `libuuid/meson.build`, not in the root after line 888, so the
archive and its `.pc` both survive the cut.

Verified rather than assumed: applies clean on a freshly fetched pin,
`meson setup -Dlibuuid-only=true` configures, `ninja` links exactly
`libuuid.a`, and `uuid.pc` is generated and marked for install.

One correction to my own reporting. I first said "only libuuid is in the
build graph" after running `meson setup` alone — nothing had been
compiled. The claim was true of the target list and presented as though
it were a build. Prompted to check whether the artefact was the host's, I
built it: ours contains `src_clear.c.o` (meson naming), the host's
`la-clear.o` (libtool), 130,938 bytes against 48,480. The pipeline is
also protected independently — `require_pc uuid` compares
`pkg-config --variable=prefix` against the static prefix and fails if it
resolves to `/usr`.

### 2026-08-31: software-renderer image fallback is in the build recipe

The fresh GitHub artifact from run #71 (`fb394aa`) was tested on the live
X11 desktop with its own embedded host and a temporary host cache. With the
normal environment, `2.jpg` rendered in both panels. With
`QT_QUICK_BACKEND=software QT_XCB_GL_INTEGRATION=none`, the UI and ordinary
file icons rendered but the JPEG areas were empty. This isolates the image
regression to ZoinGallery's custom `ShaderEffect` path: the decoder and the
rest of the Qt Quick scene still work.

The build recipe now applies
`contrib/f4-qt/patches/zoin-gallery-software-images.patch` to the pinned
ZoinGallery checkout. It adds ordinary `Image` overlays for thumbnails,
viewer images, navigation neighbors and the filmstrip, guarded by
`GraphicsInfo.Software`; the existing shader path is unchanged for hardware
renderers. The same coverage includes the actual `GalleryViewer` navigation
component and the panorama mode: on software-only systems a panorama falls
back to a fitted equirectangular image, while hardware keeps the interactive
spherical projection. The overlay is checked before the expensive dependency
build and removed after each build path (with an exit cleanup fallback), so it
cannot silently drift or leave the source checkout dirty.
`tools/preflight-f4-qt.sh` checks the plan, all six QML coverage points and
patch applicability. A new full CI build and fresh artifact test are still
required before calling this fixed.

### 2026-08-29: fresh host dies with SIGILL before the ExtUI handshake

The newest cached host
`~/.cache/f4/qt-host/971aafd12dd8e719960d49242490da5c4c5f1375d0077ef0214d33cdb0183b6b/f4-qt-host`
does not reach f4's protocol at all. Running it through f4 with
`QT_QUICK_BACKEND=software QT_XCB_GL_INTEGRATION=none` still ends in
`failed to read extui hello: EOF`; `strace` and gdb show the child being
killed by `SIGILL` at `vptestnmq`, an AVX-512 instruction. The desktop CPU is
an Intel i5-6300U with AVX2 but no AVX-512. The old host stays alive under the
same software-rendering variables, so this is a CPU baseline failure, not an
OpenGL decision.

The immediate source is f4's `ci/build-qwindowkit.sh`: it sets
`-DCMAKE_CXX_FLAGS` explicitly, which discards the `CXXFLAGS=-target
x86_64-linux-gnu.2.27` passed by this repository. QWindowKit can therefore be
compiled for the CI runner's CPU and its static code is later linked into
`f4-qt-host`. The build plan now applies the tracked
`contrib/f4-qt/patches/f4-qwindowkit-portable-flags.patch`, which carries both
`CFLAGS` and `CXXFLAGS` into those explicit CMake variables, and makes the
final host configure use the same compiler and target flags. The patch has
been checked against the pinned f4 tree; a fresh full rebuild is still needed
to verify the resulting host and image rendering.

### 2026-08-29: last known launch combination on this desktop

The following invocation is the one that made the required Qt window appear
with the current `/home/unxed/4/qt/f4` binary:

```sh
F4_EXT_UI_PATH=/home/unxed/.cache/f4/qt-host/f116612e19b9e19fdec97e138212622f6895600ea7d786b0e60520db9d2f9e1f/f4-qt-host \
QT_QUICK_BACKEND=software QT_XCB_GL_INTEGRATION=none \
/home/unxed/4/qt/f4 --gui qt --attached
```

Observed result: the Qt window appears, but then disappears and f4 exits; the
latest crash log contained only the known QML warning and no graphics error or
`failed to read extui hello: EOF`. This is the last known launch state, not a
confirmed persistent working session. The newer host
`~/.cache/f4/qt-host/971aafd12dd8e719960d49242490da5c4c5f1375d0077ef0214d33cdb0183b6b/f4-qt-host`
still ends with the ExtUI EOF failure.

The GUI currently shows a black empty area instead of image contents; JPEG
files, for example, do not render visibly.

### The window vanished because the host had no way to draw — fixed at the source

f4 runs on a real desktop with `QT_QUICK_BACKEND=software`: full UI, both
panels, menus, function keys, embedded terminal, from a static binary on
a glibc 2.27 baseline. With GL, it died. The crash log f4 keeps at
`~/.config/f4/crashes/stderr_*.log` (f4 redirects stderr there and the
host inherits it -- which is why every earlier capture was empty) said:

```
QXcbIntegration: Cannot create platform OpenGL context, neither GLX nor EGL are enabled
QRhiGles2: Failed to create context
Failed to initialize graphics backend for OpenGL.
```

The host exited, resetting the TCP link to f4 (`connection reset by
peer`), and the window closed half a second after appearing.

**Cause.** In a static build the xcb GL integrations are separate
plugins. `plugins/xcbglintegrations/libqxcb-glx-integration.a` and
`libqxcb-egl-integration.a` were in the Qt package, but nothing emitted
`Q_IMPORT_PLUGIN` for them: the import list covered platforms,
imageformats, iconengines and QML, and this plugin type was simply not in
it. The platform plugin alone gets you a window and no way to draw in it.

**Three fixes, so the next run decides for itself and cannot die of it.**

1. **Import the GL integrations** (`import-qt-static-plugins.cmake`).
   Deliberately non-fatal when absent, unlike the platform plugins: a Qt
   without GLX/EGL is a legitimate configuration, and the runtime probe
   then picks software.

2. **Make the probe answer the right question.** It asked whether
   `libGL.so.1` could be dlopen'd -- and on that desktop libGL *was*
   present, so it said "leave it to Qt" and Qt died. Presence of a
   library says nothing about whether a context can be created. It now
   opens the display and calls `glXQueryVersion`, falling back to
   `eglInitialize`; either succeeding leaves the GPU path alone, both
   failing selects software. All via dlopen/dlsym, so no GL or X headers
   and no new load-time dependency. An explicit `QT_QUICK_BACKEND` is
   never second-guessed.

3. **Close the CI blind spot.** The smoke run forces
   `QSG_RHI_BACKEND=software` under offscreen, so it never asks for a
   context and starts happily either way -- a host incapable of using a
   GPU shipped green twice. `tools/check-gl-integrations.sh` now reads
   the produced binary for the plugin class names, and the plan asserts
   the smoke log is free of "Failed to initialize graphics backend" and
   "neither GLX nor EGL are enabled". Wired into the preflight, which
   also verifies the checker rejects a binary without them.

The lesson is the same one as the diagnostics: a check that forces the
easy path proves the easy path. Software rendering in smoke was
convenient and it hid exactly the failure that mattered.

### 2026-08-29: X11 graphics are proven; the remaining failure is f4's host lifecycle

The packaged Qt host was launched directly on a live X11 desktop and passed
the last graphics boundary: `[se-render] libGL present`, the `xcb` platform
plugin, MIT-SHM, XInput 2.4, EDID for eDP-1 at 3072x1728, and all input
devices initialized without an error. `plugins are disabled in static
builds` also confirms that static Qt plugin registration is working as
designed. The graphical stack in this repository is therefore proven.

Launching through f4 is a different failure. With `--gui qt --attached`,
the window appears and immediately disappears with exit code 1. The empty
terminal output is expected from the current observation method: f4's
`extui_host.go` takes over the host streams for its protocol, so Qt's output
does not reach the terminal. `[f4] FATAL GUI ERROR` is absent, which places
the failure after stream handoff; this is f4/Qt-host lifecycle territory,
not a Qt toolchain or graphics-stack failure. The new `exit 1` versus the
earlier `0` is useful evidence that the GUI branch now reaches a real error.

The existing `f4-diag` wrapper is consequently not sufficient for this
case: capturing stderr still observes the protocol-owned stream. The host
now supports `SE_RENDER_DEBUG_FILE=/path/to/log`; when set, the render
decision is written to that sidecar and not stderr. `f4-diag` assigns a
timestamped `f4-render-*.log` next to its main log and prints both paths.
`tools/test-optional-gl.sh` verifies the fallback decision reaches the file,
and `tools/test-f4-diag.sh` verifies the wrapper exports and announces the
sidecar path.

The f4 source version matters while diagnosing this: the pinned build has
`package main` in the repository root, while a newer upstream checkout has
moved it to `cmd/f4`; on that newer tree `go build .` correctly produces an
`ar archive` because the root is no longer the command package. Do not mix
those trees when interpreting launch results. The next integration step is
to run the pinned f4 with the new host-side sidecar and inspect why the
attached GUI exits 1.

The CI hardening is already present and remains required: the plan builds f4
with `-buildmode=pie -ldflags='-s -w -bindnow'`, and the preflight asserts
those exact flags in the emitted plan. That closes `OB0050`/`OB0051` (and
the non-PIE warning) independently of the live-window investigation.

### The empty log was f4 detaching — a correct launch that looked like a silent failure

Studying the desktop run before spending another two hours of CI paid
off. f4 exited 0 with no output whether or not a file argument was given,
and `QT_DEBUG_PLUGINS=1` / `QSG_INFO=1` produced nothing — which cannot
happen if Qt started at all.

Reading the pinned f4 (`Zoinen/f4` at the plan's PIN, where `package
main` lives in the root — my newer local clone had moved it to
`cmd/f4`, which is why a plain `go build .` there produced an `ar
archive` and briefly confused the diagnosis) explains all of it:

- GUI mode is auto-detected from `DISPLAY`/`WAYLAND_DISPLAY`, so **no
  argument is needed** — both of the user's runs were selecting GUI
  correctly;
- `checkAndDetach` then re-execs f4 with `Setsid: true`, points the
  child's stdin/stdout/stderr at `/dev/null`, and the parent calls
  `os.Exit(0)`.

So the exit 0 was the parent's, immediate and correct; the Qt host and
every diagnostic line we asked for were in a detached process whose
output went to `/dev/null`. Nothing was broken — the wrapper simply had
no handle on the process that mattered.

f4 provides the way out itself: `F4_DETACHED=1` (the env var it sets on
its own re-exec) or `--attached`. f4-diag now exports the former, says so
in the launch-configuration section, and the empty-output note points at
GUI-mode selection instead of detaching, since detaching is now handled.
A stand-in that reproduces the real detach (setsid, stdio to /dev/null,
parent exits 0) is in the test, with a control that removing the export
loses the output again.

Two rounds now where the diagnostic tool, not the build, was what stood
between us and the answer. Worth remembering that a tool which observes
by redirecting is a tool that can change what it observes.

### The audit report worked, and it named a regression I had shipped

`00-audit-f4.audit.txt` arrived in the artifact and answered the question
that had been a dead end for two runs:

```
error OB0050  no PT_GNU_RELRO segment
error OB0051  no BIND_NOW
warn  OB0054  ET_EXEC in Profile H: not position-independent
```

Those are exactly the findings `-buildmode=pie -ldflags=-bindnow` was
supposed to clear. `ET_EXEC` gave it away: the flags were not applied.
The CI command was `go build -trimpath -tags f4_embedded_qt_host
-ldflags='-s -w'` — no PIE, no bindnow.

**Cause, and it is mine.** When the hard reset discarded the goffi work,
I rebuilt it from the handed-off patch. The patch carried the audit
change and the test, but the edit to the `go build` line had been made
separately and was not in it. So `b921c88` moved the audit to Profile H
while leaving the build unhardened — the audit now demanded properties
the build no longer produced.

**Why nothing caught it.** `test-goffi-hardening.sh` built *its own*
binary with the right flags and passed, proving the flags work while
saying nothing about whether the plan passes them. A green gate and an
unhardened artifact, at the same time. The test now also asserts against
the real plan line: no `-buildmode=pie` or no `-bindnow` in the f4 build
step fails the preflight in a minute. Both controls verified.

### f4-diag was capturing by breaking the thing it captured

The printf fix worked — the log is clean — but the output section was
still empty with exit 0. Not a leftover bug: redirecting both streams
into a file leaves the child with **no tty**, and a terminal UI started
that way exits immediately and silently. The wrapper was changing the
behaviour it existed to observe.

Now it runs the binary under `script(1)`, which gives a real pty and
still records the transcript, with a plain-redirection fallback that says
so in the log. And an empty capture is called out explicitly, since a
blank section plus exit 0 otherwise looks identical to a broken wrapper;
the check ignores `script`'s own framing lines so a silent run is not
mistaken for a talkative one. Both directions tested, both controls fail
when disabled.

What the desktop run does tell us: the binary starts, finds nothing to
do, and returns 0. The next step is a launch with an actual argument —
`./f4-diag -- <path-to-an-image>` — which the log now recommends by name.

### f4 runs on a real desktop — and both diagnostics had bugs that hid the evidence

The binary launched on Linux Mint 22.3, X11, `DISPLAY=:0`, 2527 fonts,
libGL found, and exited 0. That is the graphical milestone CI structurally
cannot test. But the run also exposed two defects in the diagnostics I
had just added, and both were of the same kind: the tool meant to explain
a failure was discarding the explanation.

**f4-diag lost the entire "f4 output" section.** The header was written
`printf '----- host -----\n'` — a format string starting with a dash, so
bash's printf parsed it as options and errored. The section that captures
the child's stdout and stderr never got written. So the one log that was
supposed to answer "what did f4 print" answered nothing. Fixed by passing
every header as data (`printf '%s\n' '----- host -----'`), for all six
headers rather than only the one that fired — the class, not the
instance. `tools/test-f4-diag.sh` now asserts no printf errors appear in
the produced log, that both child streams and the exit code are captured,
and that every section exists; two negative controls (reintroduce the
dash, drop the output redirect) both fail it.

**The audit wrapper reported a count without the findings.** CI failed
with `audit reports 2 error(s); not waivable here.` and nothing else: the
wrapper printed only the number, to a stderr the collector does not
capture. Two errors, unnamed, unreproducible locally — a dead end
manufactured by my own code. Now it prints each finding, and, more
importantly, always writes a full report to `<binary>.audit.txt` beside
the audited file, which the collector copies into the diagnostic artifact
first thing.

### OB0061, and why it is waived only narrowly

Building the real f4 locally (`./cmd/f4` — the root package is a library,
which is why a plain `go build .` yields an `ar archive`) surfaced a
warning class the waiver did not cover: `OB0061`, embedded host-toolchain
path. Its subject is unreadable because onebin captures a slice of Go's
glued string pool. Reading the binary directly showed the real match:
`/usr/lib/x86_64-linux-gnu/libX11.so.6` — goffi's runtime dlopen target,
a functional string, not a build leak.

So the wrapper now waives OB0061, but decides by inspecting the binary
rather than trusting the mangled subject: every toolchain-substring
occurrence must be part of a `.so` load path. One occurrence that is not
— an `-L` directory, a compiler prefix — and it fails. The test pins both
directions, and additionally asserts the leak fails *for the right
reason*: with the branch removed the run still exits non-zero, but as
STALE WAIVER, which would send a reader to delete a waiver instead of
fixing a leak. Same exit code, opposite diagnosis.

Also removed a duplicated goffi-hardening block in the preflight (the
same check ran twice).

The two CI errors remain unidentified: they appear only with the embedded
Qt host, which cannot be reproduced locally without the generated
package. The next run will name them in `00-audit-f4.audit.txt`.

### Diagnostics for the graphical launch CI cannot test

CI proves f4 builds, audits clean, and runs headless. It cannot prove f4
draws a window on a real display -- no step opens one. So the first true
graphical test is a user launching the binary, and "it didn't work" is
not diagnosable. Rather than wait for a symptom and then add logging,
the diagnostics ship with the binary.

Two pieces.

**The render-backend fallback now reports its decision.** It switched to
software silently before main(), which is right for normal use but leaves
someone with a black window unable to tell whether the fallback fired,
chose wrong, or never ran. Under `SE_RENDER_DEBUG` it prints one line to
stderr; under `SE_RENDER_DEBUG_FILE` it writes the same line to a sidecar
instead, which is safe when f4 owns stderr. Silent otherwise. Both
directions and both channels are tested -- a logger stuck on or routed into
the wrong stream is as bad as one that never speaks -- with negative
controls.

**`contrib/f4-qt/f4-diag.sh` ships next to the binary in the artifact.**
It runs f4 with Qt's own diagnostics turned on -- `QT_DEBUG_PLUGINS`,
`QSG_INFO`, the `qt.qpa.*` / `qt.scenegraph.*` / `qt.rhi.*` logging
categories (all confirmed against Qt sources), plus our `SE_RENDER_DEBUG`
and `SE_RENDER_DEBUG_FILE` -- and captures them with the host environment
(display vars, libGL presence, font count) into a main log plus a render
decision sidecar. `--software`, `--x11` and
`--wayland` force the paths a headless run never exercises. The log ends
with a short reading guide pointing at the lines that explain a
display/plugin/render failure.

So when the first real graphical launch fails, the answer is one file to
attach, not a round trip of "what does it print". The wrapper is
verified end to end against a stand-in binary: silent-by-default logging,
the forced-mode env, and the captured sections all present.

### Where the work is

Task in flight: **`f4-qt` built with the zig toolchain, no container**,
driven by GitHub Actions. Everything else in the repo (the `onebin`
auditor, the far2l reference build) is done and green — `make test` in
`onebin/` is **273 passed, 0 failed, 3 skipped** and has been unchanged
for this entire stretch of work.

- Workflow: `.github/workflows/f4-qt-zig-build.yml`, name **"f4-qt (zig
  toolchain, no container)"**, `workflow_dispatch` only (Actions tab →
  Run workflow). One run ≈ 15–25 min to reach the current failure point.
- Build recipe: `tools/build-f4-qt.sh` (`--toolchain zig`). `--print-plan`
  prints every command without running any of them; use it to inspect
  changes cheaply.
- Compiler wrappers: `onebin/toolchain/zig-cc`, `zig-c++`.

### The packaged f4 audits clean as Profile H — and it runs headless

Two milestones in one run. The smoke log shows the binary **running with
no graphical shell**: Qt Quick started, the static image plugins are
registered (`bmp cur gif ico png svg svgz …`), the full format list
includes RAW and HEIF (`heic avif dng cr2 nef arw …`), the multithreaded
decoder came up and shut down cleanly. `Connection refused` and the
Fontconfig line are the expected headless notes, not failures — the
optional-GL + software path did exactly what it was built for.

And the final audit reached the packaged `f4` for the first time. It
failed with four errors that turned out to be one diagnosis, and the
diagnosis was not what it looked like.

### f4 is a goffi binary, so Profile H by construction — not a defect

`f4` is built **without cgo** (`CGO_ENABLED=0`): it reaches system
libraries through goffi. goffi's fakecgo path uses
`//go:cgo_import_dynamic … "libc.so.6"`, and that directive makes the Go
linker emit `PT_INTERP` and `DT_NEEDED` (libc/libdl/libpthread) **even
with cgo disabled**. Reproduced exactly on Go 1.27 + goffi 0.6.3: the
ELF signature matches CI byte for byte, and glibc requirement is *none*
because goffi resolves symbols itself.

So `OB0030`/`OB0031` (interp + needed under Profile S) are not defects —
the profile was wrong. `f4` is Profile H: static in everything but the C
runtime, contract exactly `libc`/`libdl`/`libpthread`, the same set
already declared for the Qt host.

### RELRO and BIND_NOW without cgo — the part worth checking, not waiving

`OB0050`/`OB0051` (no RELRO, no BIND_NOW) are real and are ERROR, so
dropping `--strict` would not have helped. External linking supplies both
but needs cgo, which f4 avoids on purpose. The instinct was a waiver;
checking first was the better call. Go's **internal** linker does both
alone: `-buildmode=pie` emits `PT_GNU_RELRO` (and PIE, clearing the
`OB0032` ASLR warning), and `-ldflags=-bindnow` sets `DT_BIND_NOW` and
`DF_1_NOW`. Verified: the hardened binary passes a strict Profile H audit
with **0 findings**, no waiver at all.

### Fix

- Go build gains `-buildmode=pie` and `-bindnow`.
- The `f4` audit moves from Profile S to Profile H with the C-runtime
  contract, through the hygiene wrapper.
- The wrapper learns two more third-party OB0060 origins: `colorer4go`
  (Colorer from far2l, compiled to a **wasm** module shipped as data in
  the Go binary — `__FILE__` strings baked into the prebuilt wasm, not
  ours) and `/tmp/.X11-unix` (an X11 protocol string table inside
  prebuilt Qt).
- `tools/test-goffi-hardening.sh` builds a real goffi binary with the
  plan's flags and asserts RELRO, BIND_NOW and a clean strict Profile H
  audit, with a negative control that the un-hardened build fails
  `OB0051`. Wired into the preflight; skips only if Go is unavailable.
- The host-contract test now accepts either contract on a hybrid audit —
  the GUI set for the Qt host, the C-runtime set for f4 — and fails any
  hybrid audit carrying neither, or not `--strict`. Both re-checked by
  negative control.

Installing Go locally is what made this provable instead of guessed: the
"cgo is unavoidable, so static is impossible" reasoning was wrong in both
halves — cgo is absent, and the binary is hardenable without it.

### CI installs Go — the plan built and audited f4 with whatever Go the runner happened to ship

A gap that had been invisible because the runner image happened to carry
a usable Go: nothing in the workflow installed one. `go test` and `go
build` in the plan, and the new goffi-hardening check, all depended on
that accident. f4's `go.mod` requires `go 1.26.0`; a mismatched
preinstalled Go would either fail outright or trigger a silent
`GOTOOLCHAIN` download mid-build.

`actions/setup-go@v5` pinned to `1.26` (with `check-latest`) is added to
**both** jobs:

- **build**, before the plan runs, so `go build -buildmode=pie
  -ldflags=-bindnow` and `go test` use the pinned toolchain;
- **preflight**, so `tools/test-goffi-hardening.sh` actually runs there
  instead of skipping on "go unavailable". That check proves PIE+bindnow
  give RELRO and BIND_NOW and a clean Profile H audit — the exact
  property whose failure would otherwise only surface two hours in, at
  the final f4 audit. A gate that skips its most expensive-to-learn check
  is not a gate.

Recorded also because of a mistake on my side worth owning: I reset the
tree to origin/main while the goffi work was only in the working tree and
in a handed-off patch, not yet upstream, and the reset discarded it. It
was recoverable from the patch and reapplied cleanly, but the lesson is
to check `git status` before a hard reset, not after.

### Latest diagnostic run — **0 errors**; host audit fails --strict only on third-party build-path hygiene

libGL is gone from the binary's `needed` list: the CXX-only fix landed,
the 3470-symbol forwarder built, and `DT_NEEDED` no longer carries libGL.
The host audit reached the end for the first time:

```
FAIL  Level 1  (0 errors, 6 warnings, 3 infos)
```

**Zero errors.** Every portability check is clean — `DT_NEEDED`, the
glibc baseline, `RUNPATH`. What fails is `--strict` turning six `OB0060`
warnings fatal, and all six are build-machine paths compiled as string
data into prebuilt Qt and libheif archives:

```
…/.conan2/…/src/qtbase/src/widgets/widgets/qabstractspinbox.cpp
…/.conan2/…/src/qtbase/src/widgets/widgets/qdatetimeedit.cpp
…/.conan2/…/lib/libheif    /tmp/libheif-XXXXXX    /tmp/perf-%1.map    /tmp/
```

`OB0060` is a pure string scan (`c_hygiene.c`): the paths sit in
`.rodata`/`.debug_str`, never in `DT_NEEDED` or `RUNPATH`, so they do not
affect whether the binary runs anywhere. They are a hygiene and
reproducibility matter, which is why onebin rates them WARN, not ERROR.
None is from our own compilation units.

### The decision: a self-expiring, origin-scoped waiver, not `--strict` off

The alternative — dropping `--strict` — would weaken the entire warning
class forever and never come back on its own once upstream fixes the
paths. Instead `tools/audit-with-hygiene-waivers.sh`:

- keys off the auditor's **JSON** output, matching on the `subject`
  field, not scraped text;
- tolerates `OB0060` **only** for declared third-party origins (the Conan
  cache, Qt's source tree, libheif's temp paths), matched by origin
  substring so per-build hashes and random temp suffixes do not make it
  rot;
- **fails** on an `OB0060` path that matches no third-party origin — e.g.
  one from our own code, which `-ffile-prefix-map` should have stripped —
  and on any error or any non-`OB0060` warning;
- **expires**: zero `OB0060` findings makes it fail with `STALE WAIVER`,
  so the tolerance cannot outlive the problem;
- is never silent.

### Two errors caught before CI, both by simulating the real paths

- The bare string `/tmp/` was **not** covered by the substring origins
  and would have failed the waiver. Rather than waive "anything under
  /tmp" — which would hide a future `/tmp` path from our own build — an
  exact-match origin convention (`=/tmp/`) was added, so the libheif
  prefix is tolerated while a real path under `/tmp` still fails. A
  control in the test pins exactly that distinction.
- The local end-to-end run failed on `zig013/lib/libc/glibc/…` startup
  paths that are **not** in CI. They turned out to sit in `.debug_str`
  and are removed by our own `--strip-debug` link flag; with the real
  build flags the local run matches CI exactly. So the discrepancy was
  the sandbox lacking a flag the build applies, not a hole in the waiver.

Verified end to end against the real auditor with real build flags: the
three CI-shaped paths are tolerated and announced, exit 0. Five stub-JSON
states and four negative controls on the mechanism, all caught. Wired
into the preflight.

Report for the f4/Qt/libheif side drafted at
`f4-bugreport-embedded-build-paths.md`, noting also that Qt **Widgets**
appears linked into an image viewer — dropping it, if unused, removes two
of the six at the source.

### Latest diagnostic run (2026-08-28) — CMake generated no C compile rule after the optional-GL hook

The attached archive `f4-qt-zig-build-diagnostic-logs.zip` records the
failure after the previous `libGL` change. The decisive evidence is in
`03-build-output-tail.txt`: CMake 3.31.6 finishes configuring, then fails
eight times during generation with:

```
Missing variable is:
CMAKE_C_COMPILE_OBJECT
```

The cache snapshot also shows `CMAKE_C_ABI_COMPILED FALSE`, while f4's host
project is a CXX-only project. The earlier `zig: unsupported option
'-print-multi-os-directory'` line is an Autotools probe warning; it is not
the error that stopped this build.

#### Cause

`contrib/f4-qt/optional-gl.cmake` added the generated GL forwarder and
`render-backend-fallback.c` as `.c` files through `Qt6::Gui`'s
`INTERFACE_SOURCES`. Newer CMake then tried to infer/enable C for a project
that had already configured only CXX. It left the C compiler rule unset and
failed at the generate step, before any f4 source was compiled.

#### Fix and regression coverage

- Both optional-GL sources are explicitly marked `LANGUAGE CXX`, keeping
  them in f4's existing compiler language context.
- The forwarder generator emits C linkage guards when compiled as C++, so
  its assembly trampolines still refer to the intended unmangled globals.
- `tools/test-optional-gl-cxx-only.sh` configures and builds a minimal
  CXX-only consumer and checks the source-language invariant. It is wired
  into `tools/preflight-f4-qt.sh`.

Local checks passed without starting the full f4-qt rebuild: the new CXX-only
regression, the small toolchain CMake build, the five repeated static-plugin
checks, and the complete `tools/preflight-f4-qt.sh` gate pass. The
zig-dependent direct optional-GL and host-library probes were skipped because
`zig` is not installed in this environment. The preflight's strip-debug
probe now reports that condition as a skip rather than a false failure, and
the static-plugin symbol check searches captured `nm` output without a
`pipefail`/`SIGPIPE` race. The full f4-qt build remains delegated to GitHub
Actions.

### Waiving the upstream test race — narrowly, loudly, and with an expiry date

Asked to work around the f4 test race so the build can reach everything
behind it, in a way that comes out cleanly once upstream fixes it.

`tools/ctest-with-waivers.sh` runs ctest and tolerates **one named test
case**. What makes it a waiver rather than a suppression:

- **It names a case, not a suite.** The other twelve cases in the same
  binary still have to pass.
- **It expires by itself.** If a waived case *passes*, the script
  **fails** with `STALE WAIVER` and names the line to delete. A
  workaround nobody is forced to revisit is permanent, so this one is
  wired to complain the moment it stops being needed. Removing it is a
  one-line deletion; nothing else refers to the entry.
- **It is never silent.** Every tolerated run prints the case, the report
  filename and why it is not ours, ending with "this is a waiver, not a
  pass".

Retiring it, when f4 lands the fix: delete the line from the `WAIVERS`
table. That is the whole procedure — and CI will demand it, because the
run after the fix fails as stale until the line is gone.

### Staleness means *passed*, not *did not fail*

The first version treated "absent from the failures" as fixed. A case can
be absent because the binary crashed, because a filter excluded it, or
because an earlier failure stopped the suite — calling any of those a fix
would drop the waiver at exactly the wrong moment. It now requires an
actual `PASS` line. Its own test caught this.

`tools/test-ctest-waivers.sh` drives a stand-in ctest through four
states: unrelated failure still fails; waived case alone is tolerated;
waived plus unwaived still fails; waived case passing produces `STALE
WAIVER`. Three negative controls — expiry removed, unwaived tolerance,
silent application — all caught. Wired into the preflight, because a
workaround's guarantees deserve checking every run rather than once.

### A flaky test of my own, found while wiring this up

`test-qt-static-plugins.sh` failed about one run in three, on a binary
that was perfectly correct. Cause: `nm … | grep -q` under `set -o
pipefail`. `grep -q` exits at the first match, `nm` takes SIGPIPE and
returns non-zero, and the pipeline's status is nm's — so the check
failed or passed depending on whether nm had finished writing.

This is the **same trap** recorded in this file for the linker-argument
survey, which once reported "0 rejected" against a hand-run fourteen. I
wrote the rule down and then reintroduced the bug in a new file. Symbols
are now read once and searched afterwards; 20 consecutive runs pass.

Worth stating because it nearly cost more than the bug: an intermittent
check is worse than none. It had already fired inside the preflight and
sent me looking at `PATH` before the repetition showed it was timing.

### libGL is now optional, and its absence selects software rendering

Raised as a question rather than a failure: GL may or may not exist on a
host, and a binary that cannot fall back is useless on half of them.

It is worse than it looks. `libGL.so.1` in `DT_NEEDED` is resolved by the
loader **before `main()`**, so on a machine without GL the process never
starts and no fallback of ours could possibly run.

And Qt does not rescue it. From `qtdeclarative`'s `qsgcontextplugin.cpp`,
the software adaptation is chosen only when the **build** lacks
OpenGL/Vulkan/Metal, or when the platform integration reports no
`RhiBasedRendering`. This build has OpenGL and xcb is RHI-capable — there
is no runtime "GL missing, use software" path at all.

So two halves, both built and both measured.

### Half one — libGL stops being a load-time dependency

`tools/gen-optional-lib-forwarder.sh` defines every symbol libGL exports
(3470 of them, read from a real library, not listed by hand), each a
tail-call to a pointer resolved by `dlopen` at startup.

| link | `DT_NEEDED` |
| --- | --- |
| `-lGL` | `libGL.so.1`, `libc.so.6` |
| forwarder | `libc.so.6`, `libdl.so.2` |

`libdl` is already on onebin's default allowlist, so an optional GPU
library is traded for a C-runtime one present everywhere.

**Why assembly and not C wrappers.** A wrapper needs the prototype of
what it forwards, and there are thousands of GL and GLX entry points. The
trampoline touches no argument register, so every signature is forwarded
correctly *by construction* rather than by a table someone maintains.
Emitted as a global `asm()` inside a normal `.c`, so nothing needs
`enable_language(ASM)`.

A pleasant discovery while measuring: lld records `DT_NEEDED` only for
libraries that actually supply something, so once the symbols are defined
locally the entry disappears **without touching the link line** — no
filtering of `-lGL` out of Conan's or Qt's flags, which would have been
the fragile part.

### Half two — Qt is told, before `main()`

`contrib/f4-qt/compat/render-backend-fallback.c` is a constructor that
probes `dlopen` and, if GL is absent, sets `QT_QUICK_BACKEND=software`
and `QT_XCB_GL_INTEGRATION=none` — both variables located in Qt's own
sources, with the citations in the file. Both with `overwrite=0`, so
anyone who has already chosen keeps their choice, including f4's tests.

It runs its own `dlopen` rather than reading the forwarder's state, so it
does not depend on which constructor ran first.

### Testability was designed in, not bolted on

The absent-GL path is unfalsifiable on a machine that has GL, so both
pieces honour `SE_FORWARD_SE_GL_SONAME`. Pointing it at a nonexistent
library exercises the fallback deterministically on an ordinary runner.
Without that hook half of this work would be untestable in CI, which is
the same as untested.

`tools/test-optional-gl.sh` pins five things — no libGL in `DT_NEEDED`; a
control build that *does* depend on it, so the first check means
something; correct forwarding of float, pointer-returning and GLX
entry points when GL is present; software selected when it is absent; and
an explicit choice never overridden. Five negative controls, all caught,
including one on the trampoline itself.

`libGL.so.1` is deliberately **absent** from the host contract list, and
the first draft of this entry had that backwards. I wrote that keeping it
allowed would let the audit notice a forwarder that stopped applying — it
is the opposite: an allowlisted soname is reported by nothing, so the
dependency would come back and pass in silence, leaving no evidence
either way. Omitted, the property is enforced: if libGL ever returns as a
load-time dependency, `OB0010` names it. Caught while checking whether
the build job installs libGL at all — the check found a real problem, just
not the one it was looking for.

### The same technique is worth extending

`libX11` and the `libxcb-*` family have the identical problem, and the
payoff is larger: a bare server with no X libraries installed currently
cannot run the binary **even with `QT_QPA_PLATFORM=offscreen`**. Left for
after this has proven itself on a smaller surface.

### Latest diagnostic run (2026-08-28, later still) — rpath gone; the remaining 18 are the host contract, undeclared

`CMAKE_SKIP_RPATH` worked: **47 OB0040 errors to zero**, and the residual
`/usr/lib64:/usr/lib` I had noted as an open question did not appear in
CI at all — so it was a local-probe artefact, and leaving it alone rather
than chasing it was the right call.

What remains is 18 x `OB0010`, and every one is a host GUI library:

```
libGL.so.1  libX11.so.6  libX11-xcb.so.1  libxcb.so.1
libxcb-cursor/icccm/image/keysyms/randr/render/render-util/shape/shm/sync/xfixes/xkb
libICE.so.6  libSM.so.6
```

Profile H exists precisely so a binary can be static in everything except
a small, declared set of host libraries — but onebin's default allowlist
covers the C runtime only, so the contract has to be **stated**. It now
is, in one place, with a reason per group: `libGL` for Qt Quick's
renderer; `libX11`/`libxcb`/`libX11-xcb` for the display connection; the
`libxcb-*` helpers and `libICE`/`libSM` because Qt's xcb platform plugin
links them directly — its published dependencies, not ours.

Deliberately absent: fontconfig, freetype, harfbuzz, ssl, zlib, the image
codecs. Those are static, out of the Conan graph, and **if one ever shows
up in this list it means something stopped being static** — so the list
failing to cover a new soname is a signal worth having, never something
to silence with a wildcard.

Verified against the real auditor: a probe with a genuine `libX11`
dependency is reported, and naming it clears the finding, 1 to 0.

`tools/test-host-contract.sh` keeps the mechanism honest and, more
importantly, keeps the *shape* honest — no wildcard in the list, and
every hybrid audit both `--strict` and carrying the contract. It does not
pin the 18 names: that set shifts legitimately with Qt's plugin
dependencies, and the audit is already the check on membership.

Two of my own errors surfaced writing it, both the same species — a check
that asked "does one exist" where it meant "do all". Asking whether *a*
strict invocation existed passed a build where the one that matters had
lost `--strict`, because there are two; and counting every mention
matched a comment describing the command. Both now count plan steps and
compare totals.

### Latest diagnostic run (2026-08-28, later) — 708 MB → **50 MB**, and the audit finally reported on the binary itself

The strip worked, by more than expected: **708 MB → 50 MB**, well inside
the auditor's input limit, and for the first time `onebin audit` said
something about *this binary* rather than refusing to open it.

48 errors, and 47 are one thing:

```
FAIL  OB0040  search path component is not $ORIGIN-relative:
              /home/runner/.conan2/p/b/qtf24b8750aaa73/p/lib
```

One per Conan package directory. CMake records the directory of every
shared library it links as a build rpath, so a binary meant to run
anywhere was carrying a list of absolute paths from the machine that
built it — a portability hazard and a leak of the build environment in
the same field.

### Fix

`CMAKE_SKIP_RPATH=ON` in the toolchain variables. For a static artefact
none of those directories is needed at runtime.

Established against real CMake and the real wrappers rather than from the
documentation: a probe linking a shared library from a non-standard
directory gets that directory in `DT_RUNPATH`, and with the variable set
it does not. `tools/test-no-embedded-rpath.sh` keeps both halves — it
fails if the probe stops reproducing the defect, which is the failure
mode that would quietly turn it into a test of nothing.

Two preflight checks, both negative-controlled: the variable is in the
plan, and a probe build really comes out without the dependency
directory.

### One thing deliberately left open

A residual `/usr/lib64:/usr/lib` appears in `DT_RUNPATH` in the local
probe even with the variable set, and it is **not** what CI reported —
every path in the 47 errors was a Conan package directory. Rather than
guess at a second mechanism while fixing the first, this is noted and
left for the next artifact to describe. Chasing a symptom the evidence
does not show is how the `.prl` name-list mistakes happened.

### Latest diagnostic run (2026-08-28) — **the auditor was reached**; it refused a 708 MB binary

The waiver did exactly its job: `ctest failed only on waived upstream
cases; continuing`, printed with the case, its report and the reason, and
the run went **past ctest for the first time** into `onebin audit`.

```
FAIL  OB0092  742613672 bytes exceeds the 536870912 byte limit
```

`OB0092` is the auditor's **input** limit, not a rule about artefacts —
it will not open a file over 512 MiB. So nothing about the binary could
be examined, including the glibc baseline this whole toolchain exists to
satisfy.

### Where 708 MB came from: zig cc emits DWARF nobody asked for

Measured rather than assumed. Compiling a trivial file through the
wrapper with `-O2` and **no `-g`** still produces `.debug_info`,
`.debug_abbrev`, `.debug_line`, `.debug_str`. `-g0` barely dents the
result, because zig's own startup objects carry debug info too. Only a
link-time strip removes it, and it halves even a hello-world.

At this scale it stops being cosmetic. From the artifact's own listings:

| | size |
| --- | --- |
| Qt package static archives | **3565 MB** |
| build-tree archives | 194 MB |
| `f4-qt-host` | 708 MB |

### Fix

`-Wl,--strip-debug` in the global `exelinkflags` **and**
`sharedlinkflags`.

`--strip-debug`, not `--strip-all`: it removes DWARF and keeps `.symtab`,
so crashes still symbolise. Checked that a stripped binary retains
`.dynsym` and `.gnu.version_r` — which is exactly what the glibc baseline
check reads, so stripping cannot hide the thing being audited.

Three preflight checks, all negative-controlled: the flag is in each of
the two lists, and a wrapper-built binary actually comes out with zero
`.debug_*` sections and a live `.dynsym`. The third catches the case the
first two cannot — a wrapper that filters the flag back out.

Nothing is disabled and no functionality is traded away: the same code,
the same plugins, minus debugging metadata that was never requested.

### Latest diagnostic run (2026-08-27, night #6) — **8 of 9 suites pass**; the last failure is not ours

Both markers present. Every QML error is gone — no `module … is not
installed`, no `plugin … not found`, none of the 27 engine load failures.
`F4GalleryPointerTests` alone reports **12 passed, 1 failed**, and the
run is **89%**, up from 44%.

```
FAIL!  : F4GalleryPointerTests::pixelWheelAndLoaderRecreationPreserveScroll()
   Actual   (qRound(session->property("panelScrollOffset").toReal())): 0
   Expected (37)                                                     : 37
```

### This one is upstream, and the sources say so plainly

The test waits for the layout to reach the scrolled position, then checks
the persisted offset immediately (`F4GalleryPointerTests.cpp:1514`). But
the offset is not written during the scroll — it is written when the
animation **stops**, in `GalleryPanel.qml`'s `galleryPanelScrollAnimation`
`onRunningChanged` handler, guarded by `if (!running …)`.

So two conditions must coincide and the test waits only for the first:

| condition | when it becomes true |
| --- | --- |
| `qRound(contentY) == 37` | as soon as `contentY` passes 36.5 |
| `running == false` | end of the 150 ms `OutSine` animation |

On a host where the final frame lands on the same event-loop turn the
`QTRY_COMPARE` observes, they coincide and the test passes. Under
offscreen rendering the frame cadence differs, `contentY` rounds up an
animation frame early, and the immediate `QCOMPARE` runs before the write.

The race is present on any host; this configuration only makes it
reliable. No product code is implicated — the persistence behaviour is
what the surrounding cases assert.

Report drafted at `qt-bugreport…`-style alongside the Qt one:
**`f4-bugreport-pointer-test-race.md`**, with both one-line fixes
(`QTRY_COMPARE` on the offset, or `QTRY_VERIFY(!running)` before
comparing — the latter states the contract better).

### Not patching it, and why that is the call

The rule this project has held to is that the toolchain does not disable
or paper over upstream behaviour. Editing someone else's test to make our
gate green is exactly that, and it would also hide a real race from the
people who can fix it properly.

What it does block is everything after `ctest` — `onebin audit --strict`,
the smoke run, packaging, `go test`, and the final static audit — which
are the remaining unproven steps and the whole point of the exercise. The
decision of how CI should treat one known-racing upstream case is the
project owner's, not the toolchain's, so it is being put to them rather
than made here.

### Latest diagnostic run (2026-08-27, night #5) — companions exported, build and tests run; the tests still lack the module

All six companions were added, configure and generate completed, the
build ran to the tests — and `module "ZoinGallery" is not installed` is
back, 41 times, now with a **static** plugin. Reading the sources rather
than the error settles who is missing what:

- the app (`main.cpp:118`) and most tests call `addImportPath(":/")` /
  `":"` themselves, so the qmldir at `:/ZoinGallery/qmldir`
  (`RESOURCE_PREFIX "/"`) is reachable — **once its resources are linked
  in and its plugin registered**;
- Qt's finalizer imports qml plugins for an executable by scanning that
  executable's **own** qml sources. `f4-qt-host` has them; the eight test
  executables have none and load everything from linked resources, so
  the finalizer gives them nothing. The 41 errors are the tests'.

### Fix: the in-tree block returns, legal this time, plus a one-line net

The in-tree registration removed three runs ago comes back with both of
its old failure modes addressed by things that changed since:

- the backing library is forced STATIC, so the plugin is a
  `STATIC_LIBRARY` and linking it into executables is legal — the
  original `MODULE_LIBRARY may not be linked` cannot recur, and a MODULE
  plugin appearing anyway is **fatal with its name**, because it would
  mean the force-static rewrite stopped covering a target, and silently
  skipping was how this bug looked the first time;
- the class comes from Qt's own `QT_PLUGIN_CLASS_NAME`, read not derived.

Every executable gets `Q_IMPORT_PLUGIN(<class>)` in the shared generated
unit and links the plugin target, which drags the `_resources_N`
companions in through the interface — registering the qmldir resource.

And for the two tests that never call `addImportPath`: the generated unit
gains a `Q_COREAPP_STARTUP_FUNCTION` appending `:/` to `QML_IMPORT_PATH`
— read at engine construction, resource paths accepted, appending never
overrides what a process set for itself.

The mock's in-tree plugin became STATIC (mirroring what the rewrite now
guarantees), the probe asserts the registration symbol in both
executables and the net in the generated unit, and it gained minimal
QtCore header shims so the unit genuinely compiles. Three negative
controls: registration not emitted, plugin not linked, net removed — all
caught.

### Latest diagnostic run (2026-08-27, night #4) — same defect, different companion; naming one was the mistake

All three markers present, so the last fix worked and the generate step
failed on the next name along:

```
export called with target "ZoinGalleryQml" which requires target
"ZoinGalleryQml_resources_5" that is not in any export set.
```

Last run it was `ZoinGalleryQmlplugin_init`; this run
`ZoinGalleryQml_resources_5`, on the backing target rather than the
plugin, and reachable only through the `$<LINK_ONLY:…>` genex Qt wraps it
in. Same defect, and I had fixed it by **naming one companion** — which
was right for exactly one run and would have been right for exactly one
more each time.

### Enumerate, don't name

Making a target static changes the target graph, not just a flag: Qt
attaches generated OBJECT libraries — `<t>plugin_init` for the plugin
registration, `<t>_resources_N` per resource set, and others in other
configurations — and every one must be in the same export set as the
target requiring it.

The hook now **walks the interface link libraries** of each root
(`ZoinGalleryQml` and its plugin), strips the genex wrapper, and takes
every target whose name is a root plus a suffix. That is what "a
companion Qt generated for this target" means, and it needs no list to
keep current. Targets the project exports itself are untouched, because
only root-prefixed names qualify — `ZoinGalleryCore` and the roots
themselves are never added twice.

The probe gained all three shapes at once: a companion on the plugin, a
companion on the backing target behind `$<LINK_ONLY:…>`, and a
project-exported sibling that must **not** be re-added. Negative
controls: genex stripping removed (the resources companion is missed),
and the companion filter removed (the sibling gets exported twice) —
both caught.

I should have written it this way last run. The rule this file already
carries — *read, never derive* — has a twin worth stating: **when a
failure names a thing, fix the category the thing belongs to.** Two runs
were spent proving that separately.

### Latest diagnostic run (2026-08-27, night #3) — the static rewrite took effect and exposed the companion target

Both markers are in the log — `building ZoinGalleryQml STATIC` and `26
QML module plugins registered here` — so the previous fix did what it
said. The generate step then failed, twice over the same thing:

```
export called with target "ZoinGalleryQmlplugin" which requires target
"ZoinGalleryQmlplugin_init" that is not in any export set.
```

A static Qt plugin carries a companion: `qt6_add_qml_module` creates
`<plugin>_init`, an OBJECT library holding the registration unit, and puts
it in the plugin's interface. **A shared plugin has none** — which is why
this appeared only once the rewrite worked, and is a fair reminder that
changing linkage changes the target graph, not just a flag.

ZoinGallery installs its plugin into the `ZoinGalleryTargets` set
(`CMakeLists.txt:772`), so the companion has to join it. Both names are
read from that file, recorded next to the target they belong to, and
checked before use — a file that already overrides one upstream decision
should not be guessing a second name.

### Two structural bugs, both caught in the probe

- The DEFER registration sat **inside** the run-once guard, so it never
  registered in ZoinGallery's own scope — the only scope that matters.
  The guard now wraps the function definitions only.
- Registered per directory but **targets are global**, so the outer
  project saw the nested project's target and installed it a second time:
  `includes target ... more than once in the export set`. Now gated on a
  GLOBAL property per target.

Neither would have been visible in a flat probe. Both showed up because
the probe mirrors the real shape — an outer project with a nested
`project()` that declares the target, installs it, and exports it.

`tools/test-static-qml-backing.sh` now pins four properties, each
negative-controlled: target rewritten, others untouched, companion
exported exactly once, configure completes.

### Latest diagnostic run (2026-08-27, night #2) — every Qt module fixed; the last one is ZoinGallery's own, built as a `.so`

The self-emitted registrations worked. `plugin "qtquick2plugin" not
found` is **gone entirely**, the hook reports `26 QML module plugins
registered here`, and tests went 3/9 → **4/9**. One class remains, 43
times: `module "ZoinGallery" is not installed`.

The build artefact says why: `libZoinGalleryQmlplugin.**so**`.

### Read from Qt's source, not guessed

Qt's own `Qt6QmlMacros.cmake` (fetched from qtdeclarative rather than
recalled) picks the plugin's linkage: when the backing target already
exists, `STATIC_LIBRARY` gives a STATIC plugin, `SHARED` or `MODULE`
gives SHARED. And ZoinGallery declares, at `CMakeLists.txt:289`:

```cmake
add_library(ZoinGalleryQml SHARED)
```

`qt6_add_qml_module` is called with neither STATIC nor SHARED, so it
inherits that. A shared QML plugin cannot be registered into a statically
linked binary — hence the message, after every *Qt* module had been
fixed.

There is no supported switch: the type is hard-coded and ZoinGallery
declares no option covering it.

### The override, and saying plainly what it is

`contrib/f4-qt/force-static-qml-backing.cmake` overrides `add_library`
for one explicitly named target and rewrites SHARED to STATIC. Everything
else passes through untouched, including the MODULE libraries Qt creates
on purpose. Named, not pattern-matched, so it cannot quietly widen.

This is the toolchain overriding an upstream decision, and that deserves
stating rather than burying: ZoinGallery's choice is right for an
ordinary desktop build and wrong only for a single-file static artifact,
which is this project's whole purpose. The durable fix belongs upstream —
an option, or honouring `BUILD_SHARED_LIBS`. **Nothing is disabled:** the
gallery, its QML module and every type in it build and link exactly as
before; only the linkage changes.

### The probe earned its keep immediately

First version recursed infinitely. The file is included from every
`project()` scope, and overriding a command twice makes the saved
`_add_library` resolve to the previous override instead of the builtin.
Caught locally, in the probe, because it ran the file in a *nested*
project — which is the only place the bug appears, and also the only
place the fix has to work. Guarded now with a GLOBAL property, since
variables do not carry across sibling directory scopes.

`tools/test-static-qml-backing.sh` pins all three properties — target
rewritten, others untouched, configure completes — and each is
negative-controlled. Added to the preflight.

### Latest diagnostic run (2026-08-27, later) — the archive is linked, the instance is not; stop waiting for Qt to emit the registration

Identical test counts to the run before, which is itself the finding: the
fix worked at the level it addressed and the runtime never moved.

- declarator ran: **378** `Qt6::*` targets declared
- Qt's "will not be linked" warnings: **31 → 5** (the five remaining name
  archives the package genuinely does not ship)
- runtime: **unchanged**, `plugin "qtquick2plugin" not found`, now 47×

So Qt found the targets and linked the archives, and still emitted no
`Q_IMPORT_PLUGIN` for them. Setting `QT_PLUGIN_CLASS_NAME` was not enough,
and which internal property this Qt's finalizer actually consults is a
version detail **I cannot read from here** — the diagnostic artifact
prunes `*/lib/cmake/*`, the same blind spot that misled this file once
already.

### The decision, and why it is not another guess

Stop depending on it. `qmlimportscanner` is Qt's own tool, is in the
package, and reports exactly which modules the app imports; each reported
archive goes through the same reader every other plugin here uses —
mangled symbol for the class, `.prl` for the closure. The registration is
emitted into our own generated unit.

If Qt also emits one for the same plugin, the two registrations are
identical and idempotent. **A duplicate registration is harmless; an
absent one costs a run** — and this asymmetry is the whole argument for
doing it ourselves rather than diagnosing Qt's finalizer through a
listing that cannot show me its source.

The `QT_PLUGIN_CLASS_NAME` property stays: it costs nothing and is what
Qt's path needs if it is consulted at all.

This is the second time "Qt will do it" was believed and wrong. The test's
scope note now records both reversals rather than just the current state,
and QML plugins are asserted in the produced binaries again. Both halves
negative-controlled: registration not emitted, property not set.

### Latest diagnostic run (2026-08-27) — linked but never registered: `plugin "qtquick2plugin" not found`

The target declaration worked, and the failure moved one step further in
— the most granular results yet. Test binaries run and report per-case:
`F4GalleryPointerTests: 5 passed, 8 failed`, 3 of 9 suites green, and
`module "…" is not installed` is gone entirely. What remains, 27 times:

```
qrc:/F4QtHost/qml/main.qml:1:1: module "QtQuick" plugin "qtquick2plugin" not found
```

The qmldir is found; the module is known; the plugin's **static instance
does not exist in the binary**. Which pins the mechanism precisely:
linking is only half of what `qt6_import_qml_plugins` does. The other
half is emitting `Q_IMPORT_PLUGIN(<class>)` into a generated unit, and
the class comes from the plugin target's **`QT_PLUGIN_CLASS_NAME`**
property. My declared targets had archives and `.prl` closures — and no
class-name property. Qt linked them and silently emitted no registration:
the archive is in the binary, the instance is not.

### Fix, one property, read not derived

The declarator now sets `QT_PLUGIN_CLASS_NAME` on every declared target
whose archive carries a plugin symbol — the class read from the archive's
own mangled `_Z<len>qt_static_plugin_<Class>v`, by the extractor that
already existed for the direct imports, factored into
`_se_plugin_class()` with the same `required` split as the `.prl` parser:
fatal when importing a plugin, tolerant when sweeping `lib/`, where
module libraries legitimately carry no plugin symbol.

The probe now asserts the declared `Qt6::qtquick2plugin` carries exactly
`QtQuick2Plugin`, read back from the property; removing the
property-setting is caught. This closes the pair with night #6's lesson
as a unit: **declare = location + closure + class name.** Any one of the
three missing produces a distinct silent failure, and all three now come
from the package itself.

### Latest diagnostic run (2026-08-26, night #5) — **my premise was wrong**: Qt's machinery is present and running; it was skipping 31 plugins silently

```
CMake Error: Target "ZoinGalleryQmlplugin" of type MODULE_LIBRARY may not be
  linked into another target.
CMake Warning at …/p/lib/cmake/Qt6Qml/Qt6QmlMacros.cmake:4813:
  The qml plugin 'qtquick2plugin' is a dependency of 'f4-qt-host', but the
  link target it defines (Qt6::qtquick2plugin) does not exist in the
  current scope. The plugin will not be linked.        [31 times]
```

### The correction, and how I got it wrong

Four entries of this file rest on "Conan's CMakeDeps drops Qt's own CMake
machinery". **That is false.** `Qt6QmlMacros.cmake` is right there in the
package — the error stack quotes it by path — and
`qt6_import_qml_plugins` has been running automatically out of
`_qt_internal_finalize_executable` for every executable, in this run and
the previous one.

The mistake has a precise cause worth recording: I grepped the diagnostic
artifact's package listing for those files, found nothing, and concluded
they were absent. **The collector deliberately prunes `*/lib/cmake/*`** —
a rule I wrote myself, to keep the artifact small. I read absence from a
listing as absence from the package. An artifact designed to be small is
not evidence of what a package does not contain.

So the fourth "instance of the same seam" was not that at all, and the
in-tree registration I added last run was reimplementing work Qt already
does — which then failed on its own terms, because Qt makes an in-tree
QML plugin a `MODULE_LIBRARY`, and CMake will not link one into anything.

### What is actually wrong, and the one-mechanism fix

Qt's import path works; it just gives up quietly on any plugin whose
`Qt6::<name>` link target does not exist, because Conan's generator
publishes its own component set rather than the per-plugin targets Qt's
package files reference. Thirty-one warnings, no error, and a binary that
links and then says `module "QtQuick" is not installed`.

So: **supply the targets and let Qt do the importing.** The hook now
declares an imported target for every plugin archive under `qml/` and
every module archive under `lib/`, taking names from what is on disk
rather than from a list, in both spellings Qt uses — it asks for
`Qt6::quicktooling` while the archive is `libQt6QuickTooling.a`. Each
target carries its `.prl` closure through the same parser used elsewhere
here. Existing targets are never overwritten: where Conan declares a
component, Conan's version wins.

The hand-rolled QML import and the in-tree registration are both deleted.
What remains in this file is only what nothing else does: the platform
and image-format plugins.

`.prl` strictness became a parameter in the process, and the distinction
is real rather than cosmetic — for a plugin being imported a missing
`.prl` is fatal (its backing library and resources would not link), while
for the bulk declaration plenty of Qt libraries ship none and demanding
one would abort configure over nothing.

### Test

The mock now carries a `MODULE`-type in-tree plugin (the type that made
CMake refuse), a `libQt6QuickTooling.a` with no `.prl` beside it, and a
deferred check for both spellings of its target. Negative controls:
declaration removed, and module-name spellings removed — both caught.

Two of my own errors surfaced while writing it, both silent-pass
failures, which is the kind worth naming: a negative control aimed at the
wrong line (the lowercase spelling comes from a different branch than I
targeted), and an insertion into the probe that never applied because the
anchor did not match — so the check I thought I was testing did not exist
at all, and the control "passed".

### Latest diagnostic run (2026-08-26, night #4) — the binaries **run**; QML says `module "ZoinGallery" is not installed`

The biggest step yet, and the failure moved out of the toolchain
entirely. Everything links, every test binary **starts and executes**,
and four of nine tests now pass (one before). What fails is QML at
runtime:

```
module "ZoinGallery" is not installed   (43 times)
QQmlApplicationEngine failed to load component   (27 times)
5 tests failed out of 9
```

### What was missing, and why my earlier exclusion was half right

`qt6_add_qml_module` creates a plugin target per module —
`ZoinGalleryQml` → `ZoinGalleryQmlplugin`, and likewise f4's `F4QtHost`.
In a static build the module is only reachable once that plugin is
imported.

The archive-import loop skips in-tree modules, and that part was correct:
it imports archives *out of the Qt package*, and an in-tree module has no
archive at configure time because this very build produces it. Skipping
the archive was right. **Skipping the registration was the gap** — the
plugin target exists, it just was never named in the generated
`Q_IMPORT_PLUGIN` unit nor linked.

Nothing was ever excluded from the *build*: the gallery compiles and
links throughout. Worth stating plainly because "excluded" is easy to
misread, and dropping the gallery would defeat the purpose of the
artifact.

### Fix, read rather than derived

Qt marks every plugin target it creates with **`QT_PLUGIN_CLASS_NAME`** —
the same property `qt_import_plugins` consumes. The hook now walks the
build's directory tree, collects every target carrying it, emits
`Q_IMPORT_PLUGIN` for each, and links them to every executable. That
picks up f4's module, ZoinGallery's, and anything either adds later, with
no name list to fall out of date — the fourth instance of the same seam,
handled by the same rule as the last three.

They are linked **straight to the executables**, not through `Qt6::Gui`:
these plugins link `Qt6::Gui` themselves, so putting them in Gui's
interface would close a cycle — the failure of two runs ago, avoided by
design this time rather than rediscovered.

The mock gained an in-tree plugin target of exactly that shape (a real
target, no archive on disk, marked with `QT_PLUGIN_CLASS_NAME`), and both
halves are negative-controlled: import not emitted, and plugin not linked
to executables. Two of my own slips were caught locally on the way —
`while` loops closed with `endforeach()`, and a stale test anchor.

### Still open, and now genuinely narrow

`QQmlApplicationEngine failed to load component` may or may not survive
this fix: the 27 occurrences are downstream of the 43 missing-module
errors, but only a run can say whether anything else remains. The other
named unknowns are unchanged: fonts under `offscreen`, and both `onebin
audit` profiles on real binaries.

### Latest diagnostic run (2026-08-26, night #3) — 190 `cannot open $[QT_INSTALL_PREFIX]/...`; my token list was the old mistake in a new costume

```
ld.lld: error: cannot open $[QT_INSTALL_PREFIX]/lib/objects-Release/
  QuickEffects_resources_21/.qt/rcc/qrc_multieffect_shaders18_init.cpp.o:
  No such file or directory
```

190 of them, and **two independent defects behind them**:

1. **The token was never resolved.** I substituted `$$[QT_INSTALL_*]`
   tokens *by name* — LIBS, PLUGINS, QML. `QT_INSTALL_PREFIX` was not on
   my list, so it sailed through verbatim into the link line. Having
   written "read, never derive" one run earlier, I had enumerated names
   again; the same mistake wearing a different hat.
2. **The files do not exist.** `objects-Release` appears **zero** times
   in the package listing — Conan's recipe does not ship Qt's resource
   object trees, yet the `.prl` files reference them.

### Fix, per defect and per class

- Every `$$[QT_INSTALL_*]` token of the kind is now mapped, and anything
  still matching `$$[...]` afterwards is **fatal with its own name
  printed**. An unknown token can no longer pass through silently — which
  is the property my name-list lacked, not the extra names.
- **Existence gate on every absolute path.** A path that does not exist
  is a hard `cannot open` from ld.lld: unrecoverable and uninformative.
  Dropping it either works, or fails later on an undefined symbol — the
  diagnosable failure. This covers the whole family of package-relative
  references the recipe prunes, not just `objects-Release`.

The mock's `.prl` now carries both reproductions in one line — the
Conan-junk `::` token from night #2 and an unmapped-token path to a
nonexistent `objects-Release` object from night #3 — and both negative
controls catch: existence gate removed, PREFIX mapping removed.

**Three failures in a row have now come from the `.prl` grammar**, which
is worth naming as the class: it is the one file format here written by a
*different build system* (qmake) about a *different machine*, and every
part of it is suspect — token syntax, path validity, and the identity of
what the tokens name. All three now have guards that fail loudly rather
than pass through.

### Latest diagnostic run (2026-08-26, night #2) — Conan's build-time target names leak into Qt's `.prl` files; filtered as a grammar class

The metadata-driven hook worked up to the generate step, which then died
on bookkeeping rather than on a link:

```
CMake Error: The link interface of target "Qt6::Gui" contains:
    -lCONAN_LIB::double-conversion_double-conversion_RELEASE
  but the target was not found.
```

A Conan-built Qt's `QMAKE_PRL_LIBS` holds three kinds of token: Qt's own
archives as `$$[QT_INSTALL_*]` paths (already resolved), system libraries
as plain `-lGL`/`-lm` (fine as-is), and **Conan's toolchain leaking its
build-time target names into qmake's link line**. CMake treats any `::`
token in a link interface as a target and stops on the first one it
cannot find.

Dropped as a class — any `::` token that is not an existing target —
not as a name. And dropping is *correct*, not merely convenient: every
executable already links the full Qt component set, whose Conan
dependencies carry those very libraries; the `.prl` entries record what
Qt's **own** build linked, and for third-party deps that information is
redundant on our side of the seam. If one ever were genuinely missing,
the link would fail loudly on an undefined symbol — unlike this, which
failed on bookkeeping. A `::` token that *is* a real target is kept.

The mock's `.prl` now carries the junk token byte for byte, reproducing
the failure; filter removed is caught by the negative control. With this,
the `.prl` grammar — the one external format this hook parses — has a
guard per token *kind* rather than per observed name, which is as far as
foresight reaches without the files themselves: the artifact ships
listings, not contents. Everything else pre-computable remains done; the
named unknowns (in-tree QML at runtime, fonts under offscreen, both
audits on real binaries) still require the artifact to exist.

### Latest diagnostic run (2026-08-26, night) — plugin archives are not leaves; consume Qt's metadata, derive nothing

The cycle fix held; the import unit compiles only into executables and the
plugin archives are on the link line. The final link then failed twice
over, one failure per guess I had made:

```
ld.lld: error: undefined symbol: qInitResources_QuickControls2Impl_raw_qml_0()
>>>  in archive …/qml/QtQuick/Controls/impl/libqtquickcontrols2implplugin.a
ld.lld: error: undefined symbol: qt_static_plugin_QIcoPlugin()
>>>  referenced by static_everywhere_qt_plugin_import.cpp:7
```

- **A QML plugin archive is not self-contained.** It references its
  module's backing library — and in this Qt build the module's *resources*
  are compiled into that backing library too (`libQt6QuickControls2Impl.a`
  is 20.9MB; the package contains **zero** separate resource objects —
  `qInitResources|_resources_|objects-Release|.rcc` all grep to nothing).
  I linked the plugin and nothing else.
- **The ico plugin's class is `QICOPlugin`, not `QIcoPlugin`.** I derived
  the `Q_IMPORT_PLUGIN` name from Conan's component name. Wrong the moment
  Qt's own naming disagrees.

### The class fix: both answers were already in the package

Qt ships its own machine-readable metadata next to every archive, and the
hook now consumes it instead of deriving anything:

- **The class name comes out of the archive itself.** The defining symbol
  is a mangled C++ function `_Z<len>qt_static_plugin_<Class>v`, and the
  Itanium length prefix makes extraction *exact*. That matters: a greedy
  `[A-Za-z0-9_]+` swallows the trailing mangling and yields `<Class>v` —
  the mock's first run produced precisely that off-by-suffix, same family
  of mistake as `QIcoPlugin`, caught before CI this time because the mock
  now uses genuinely mangled symbols.
- **The dependency closure comes from the plugin's `.prl`.** Every one of
  the 54 QML plugins and every `plugins/` archive has one;
  `QMAKE_PRL_LIBS` is parsed with `$$[QT_INSTALL_*]` tokens and any stale
  build-machine prefix remapped onto this package. Missing `.prl` or an
  unparseable class is fatal with the payload printed.

One helper now serves platform, image and QML plugins uniformly; the
Conan component targets are no longer a source of names, only an extra
dependency carrier for xcb.

Mock upgraded to match reality's sharp edges: mangled symbols, a backing
library reachable only through the `.prl`, and the ico directory
deliberately named against its class. Negative controls: prl parsing
removed and greedy extractor restored are each caught. `make test` 273,
preflight green.

**The rule this leaves behind, stated once:** for anything Qt installs,
Qt also installs the authoritative description — symbol tables, `.prl`,
`qmldir`, `qmlimportscanner`. Every failure in this file's history came
from substituting a derivation for that description. Read, never derive.

### Latest diagnostic run (2026-08-26, evening) — ninja dependency cycle through the generated plugin-import unit; the missing half of Qt's own mechanism

Everything up to and including qwindowkit built; the pin post-check passed
in the log. f4's build then stopped before compiling anything of its own:

```
ninja: error: dependency cycle:
  ZoinGallery/libZoinGalleryCore.a
  -> ZoinGalleryCore.dir/__/static_everywhere_qt_plugin_import.cpp.o
  -> static_everywhere_qt_plugin_import.cpp
  -> cmake_object_order_depends_target_ZoinGalleryDecodeLifecycleTests
  -> ZoinGalleryDecodeLifecycleTests_autogen timestamps
  -> ZoinGallery/libZoinGalleryCore.a
```

The import unit was compiled into **`ZoinGalleryCore.a`** — a static
library sitting between `Qt6::Gui` and the executables. Its object of the
generated file ties, through CMake's ordering for shared generated
sources under AUTOMOC, to the autogen timestamps of the test targets, and
the tests link the library. Cycle.

The root mistake is precise and worth stating precisely: **I took half of
Qt's mechanism.** `qt_import_plugins` does attach the unit via
`INTERFACE_SOURCES` — but wrapped in
`$<$<STREQUAL:$<TARGET_PROPERTY:TYPE>,EXECUTABLE>:…>`, restricting it to
executables. I copied the attachment and dropped the restriction. Even
without AUTOMOC in the loop the unrestricted form is wrong: an executable
and a pulled archive member each carrying the same registration object is
a duplicate definition at link. Executables are where plugin registration
belongs, and they are the only place Qt itself puts it. The genex is now
in the hook.

### The class, not the incident

Asked, correctly, to stop treating these one at a time. The pattern
across this failure and the two before it: **the mock did not contain the
target shape that broke.** First it lacked a second executable (the tests
failed, the app linked); now it lacked a static library between Gui and
the consumers (the shape `ZoinGalleryCore` has).

So the rule the test now encodes: the probe carries the real tree's
*shape catalogue* — a nested `project()`, a static intermediate library
linked by everything, two executables — and asserts per shape: the import
unit present in each executable, and **absent from the static library's
archive**, checked with `nm` on the produced artifacts. Removing the
executable-only genex is negative-controlled and caught. When upstream
adds a new shape (a shared plugin consumer, a module library), the first
step is to add it to this probe, not to wait for its failure.

What this cannot pre-compute, stated so the next run's risks are named
rather than implied: runtime registration of the in-tree QML modules
(`qt_add_qml_module` machinery — the smoke step's grep exists for
exactly this), fontconfig finding fonts under `offscreen`, and both
`onebin audit` profiles against the real binaries. Those need the
artifact to exist.

### Latest diagnostic run (2026-08-26) — everything builds and links; eight of nine tests abort before `main()`

The Qt6::OpenGL edge fix worked. **Nothing failed to compile or link** —
the diagnostic collector's own output says so: `no object files named in
any error line of the build log`. The run got all the way to `ctest`:

```
qt.qpa.plugin: Could not find the Qt platform plugin "offscreen" in ""
This application failed to start because no Qt platform plugin could be initialized.
11% tests passed, 8 tests failed out of 9
```

Only `QtShellControllerTest` — the one with no GUI — survived.

### The same seam as Qt6::OpenGL, one layer further out

A static Qt has no plugin `.so` to discover at runtime. Qt's answer is
`Q_IMPORT_PLUGIN`: a translation unit compiled into the executable that
references the plugin's static registration. Qt's own CMake does this
automatically — `qt_import_plugins`, driven by `Qt6GuiPlugins.cmake`,
which every consumer of a static `Qt6::Gui` gets for free.

Conan's CMakeDeps replaces Qt's package files with its own, and that
machinery does not survive the substitution — exactly like the missing
`Qt6::Quick -> Qt6::OpenGL` edge. **This is now twice from the same seam**,
and it is worth naming as a class rather than two incidents: anything
Qt's own CMake would have done for a static build silently stops
happening under Conan, and only a static build notices.

f4 is not at fault: under `F4_PORTABLE_STATIC` it deploys no plugins,
correctly, because with Qt's own CMake it would not have to.

### Fix

`contrib/f4-qt/import-qt-static-plugins.cmake` generates the
`Q_IMPORT_PLUGIN` translation unit and attaches it to **`Qt6::Gui`'s
`INTERFACE_SOURCES`**, which is the same mechanism Qt's own
`qt_import_plugins` uses. Every consumer compiles it — app, tests, and
anything added later. The lesson from the OpenGL hook is applied up
front this time: fix the interface, not a named target.

Two plugins, each with a reason:

- **offscreen** — what f4's tests and the smoke step both set
  (`QT_QPA_PLATFORM=offscreen`), and the one whose absence produced this
  failure. Conan ships `libqoffscreen.a` but declares **no component for
  it**, so it is picked up from the package folder by `find_library`.
- **xcb** — what the application actually uses on a desktop. Conan does
  declare `Qt6::QXcbIntegrationPlugin`. Without it the binary would pass
  CI and then fail to open a window on a user's machine, which is the
  worse failure because nothing here would catch it.

### Not waiting for the next two-hour run to name the rest

The first draft of this deferred image-format plugins on the grounds that
nothing had failed for want of them. Challenged in conversation, and the
challenge was right: the candidate set is finite, sits in the artifact
already collected, and what f4 uses is readable in its sources. Waiting
for a failure only works when there is going to be one.

The package ships **23 plugin archives** under `plugins/` and **54** more
under `qml/`. Going through them against f4's sources:

- **gif, ico, svg, svgicon — imported.** ZoinGallery's `QtDecoder`
  enumerates `QImageReader::supportedImageFormats()` and decodes whatever
  Qt reports (`Decoders/QtDecoder.cpp:13`). Without these archives Qt
  reports fewer formats and f4 quietly stops opening those files. Nothing
  crashes; no test fails. **CI would never have told us** — for an image
  viewer that is worse than the abort that started this entry, and it is
  the case that waiting could not have found.
- **jpeg, png, webp, tiff, heif — nothing to do.** Qt builds jpeg and png
  into Qt6Gui with system libraries (there is no `qjpeg`/`qpng` archive in
  the package at all), and the rest come from ZoinGallery's own decoders.
- **sqlite, TLS backends — left out, checked not assumed.** No
  `QSqlDatabase` anywhere; the only `https` strings are comments and a map
  URL handed to the desktop browser. No `QNetworkAccessManager`, no
  `QSslSocket`.
- **QML module plugins — imported, and this was the next failure.** f4's
  QML imports 16 modules across 38 files and pulls more transitively, so
  hand-listing was never an option. The smoke step's existing grep for
  `QQmlApplicationEngine failed to load component` is exactly this
  failure, waiting to happen.

### Third time from the same seam

Qt's answer for QML is `qt_import_qml_plugins()`, which runs
`qmlimportscanner` and imports what it reports. That macro lives in
`Qt6QmlMacros.cmake`, which Conan's package does not ship — **but
`qmlimportscanner` itself is in the package**, at `libexec/`. So the hook
uses Qt's own tool and supplies only the small part around it.

Checked directly in the artifact's file listing, which makes the pattern
hard to argue with:

| file | in the package |
| --- | --- |
| `Qt6GuiPlugins.cmake` | **no** — cost the platform plugins |
| `Qt6QmlMacros.cmake` | **no** — costs the QML plugins |
| `qmlimportscanner` | yes |

Together with the missing `Qt6::Quick -> Qt6::OpenGL` edge, that is three
instances of one thing: **anything Qt's own CMake would have done for a
static build silently stops happening under Conan's generated package,
and only a static build notices.**

The scanner's JSON is parsed strictly and every unexpected shape is fatal
with the payload printed, because this is the one assumption here that
could not be verified against a real Qt package — a mismatch must stop at
f4's configure with the output in hand, not resurface as a runtime QML
error at the end of a long run.

### Thought ahead once more before the next run, and found two certain breaks in my own hook

Asked directly before starting CI: is there anything left that can be
computed rather than discovered. Walking the hook through f4's real
configure step by step turned up two bugs that would have failed the very
next run, plus one risk that f4's own policy floor already retires:

- **Duplicate `Q_IMPORT_PLUGIN`.** The scanner can report one module
  several times — two root paths, repeated imports — and
  `Q_IMPORT_PLUGIN` expands to a *definition*, so a duplicate is a
  redefinition error in the generated file, ten minutes into the run.
  Deduplicated by classname.
- **In-tree modules with a reported path.** The scanner also reports the
  tree's own modules (`F4QtHost`, `ZoinGallery`, `ZGStyle`, `QWindowKit`),
  whose paths point at source or build directories where no archive exists
  yet; the hook's own loud-failure policy would have aborted configure on
  a file that is not supposed to be there. Now only paths under the Qt
  package's `qml/` are imported — those modules are built and linked by
  this very build.
- **`file(GENERATE)` visibility across directories** — checked and
  retired rather than fixed: `CMP0118` governs whether the GENERATED mark
  is global, f4 requires CMake 3.23 and ZoinGallery 3.21, both past the
  3.20 boundary, so subdirectory consumers see the generated file.

Also confirmed while checking: neither f4 nor qwindowkit contains a single
`Q_IMPORT_PLUGIN` of its own, so this hook is the only importer of Qt's
modules, and the in-tree QML modules go through `qt_add_qml_module`, which
past runs show working. Whether their *runtime* registration holds is the
genuinely open question the smoke step exists to answer — it could not be
settled from here.

The mock scanner now emits a duplicate entry and an in-tree-shaped entry,
and both new behaviours are negative-controlled: dedup removed and path
filter removed are each caught.

### A mock that proved nothing

Worth recording, because the test looked fine. The first mock defined
`Q_IMPORT_PLUGIN(NAME)` as a locally-defined symbol, so nothing referenced
the plugin archives — and the negative control for "archive dropped from
the link line" **passed a deliberately broken hook**. The real macro
references the plugin's registration symbol, which is what makes a missing
archive an undefined symbol. The mock now reproduces that dependency, and
all three controls catch: QML import dropped, svg import dropped, QML
archive not linked.

`CMAKE_PROJECT_INCLUDE` now points at `contrib/f4-qt/project-include.cmake`,
a one-line aggregator. A list would work on CMake 3.29+ and this build
pins 3.31.6, but an older CMake silently ignores the extra entries, and a
hook that quietly does not run is the failure mode this whole file is
about.

### Test

`tools/test-qt-static-plugins.sh` mocks Qt rather than building it — the
subject is the CMake plumbing, and a real static Qt costs two hours. The
mock supplies a `QtPlugin` header so the generated file genuinely
compiles, and a stand-in `libqoffscreen.a` in Conan's package layout so
`find_library` runs the real path.

It asserts the imports by looking for the symbols **in the produced
binaries**, not by reading a CMake property: the property being set is a
different claim from the translation unit being compiled into each
executable. Both consumers are checked, because in the real failure it
was the tests, not the app, that could not start.

Negative-controlled three ways — attaching to one target instead of the
interface, dropping the offscreen import, and removing the top-level
guard — all caught. It also exercises the aggregator, so a hook silently
dropped from `CMAKE_PROJECT_INCLUDE` fails here.

### Previous run — Qt6::OpenGL was linked into one target instead of into the graph

The shim fix worked; `statx` is gone and `f4-qt-host` links. The run now
fails on **f4's own test executables**:

```
FAILED: [code=1] F4PanelSplitterTests
FAILED: [code=1] F4OperationsQueueTests
FAILED: [code=1] F4DocumentSurfaceTests
ld.lld: error: undefined symbol: QOpenGLPaintDevice::QOpenGLPaintDevice(QSize const&)
>>> referenced by qsgdefaultpainternode.cpp:97 … in archive … libQt6Quick.a
```

Fourteen distinct undefined symbols, every one from `Qt6::OpenGL`
(`QOpenGLPaintDevice`, `QOpenGLFramebufferObject`,
`QOpenGLFramebufferObjectFormat`), all referenced from `libQt6Quick.a`.

The diagnosis in `contrib/f4-qt/link-qt6-opengl.cmake` was right the first
time and the fix was aimed one level too low. Conan's Qt recipe declares
`set(qt_Qt6_Quick_DEPENDENCIES_RELEASE Qt6::Gui Qt6::Qml Qt6::QmlModels
Qt6::Core)` — no `Qt6::OpenGL` — so the defect is a **missing edge in the
dependency graph**. The hook did `target_link_libraries(f4-qt-host PRIVATE
Qt6::OpenGL)`, which repairs the app and nothing else. Every other consumer
of Qt6::Quick — three test executables here, and any future plugin or QML
module — needs the identical archive.

Fix: append `Qt6::OpenGL` to `Qt6::Quick`'s own
`INTERFACE_LINK_LIBRARIES`, so every consumer inherits it. Link interfaces
resolve at generate time, so this also reaches targets already created in
nested subdirectories. The precondition check changes with it, from "does
`f4-qt-host` exist" to "does `Qt6::Quick` exist" — the app's name was never
the thing this depends on.

Demonstrated rather than asserted, in a miniature project shaped like the
real thing (a static library whose symbol lives in another, an imported
target that fails to declare the edge, and **two** consumers):

| hook | link errors |
| --- | --- |
| none | 2 |
| naming `f4-qt-host` | 1 |
| repairing `Qt6::Quick`'s interface | 0 |

`tools/test-qt6-opengl-hook.sh` is rewritten around that project and now
**builds** it rather than grepping configure output for a message — the
previous version passed a hook that linked the wrong target, because the
message is printed either way. It also has a negative control: without the
hook the probe must fail to link, so the test cannot silently degrade into
one that proves nothing.

Two mistakes of mine surfaced while writing it, both worth recording:

- The first negative control for the nested-project guard **passed with
  the guard deleted**. Cause: the probe declared `Qt6::Quick` before the
  nested `project()`, so the unguarded hook found the target already there
  and had nothing to trip over. The nested project now comes first, which
  is the real ordering, and deleting the guard is caught.
- The preflight's shim-compile check failed on my own typo — the source is
  `glibc-shims.c` and only the object is `compat-glibc-shims.o`. It failed
  honestly, which is the point of writing checks that can.

### Previous run — `f4-qt-host` failed on `statx`, because the shim was scoped to `qt/*`

The Qt6::OpenGL hook fix worked: top-level configure completed, ZoinGallery
and its tests built, and the run reached the intended final link. It failed
there:

```
FAILED: [code=1] bin/Release/f4-qt-host
ld.lld: error: undefined symbol: statx
>>> referenced by qfilesystemengine_unix.cpp:359
>>>   in archive .../qt7215e46bbfcca/p/lib/libQt6Core.a
```

The shim exists and works; it was simply not on that link line. It had been
scoped to `qt/*:tools.build:exelinkflags`, and that scoping was a mistake of
mine with a plausible-sounding justification: Qt is where the call is
*compiled*, but `libQt6Core.a` then carries the unresolved reference into
**every downstream link**, so the final consumer got none of it.

Scoping had been introduced to stop an object file duplicating in openssl's
replayed LDFLAGS. The real fix for that was the other half of the same
commit — every symbol in the shim is `__attribute__((weak))`, so repeated
copies collapse rather than collide. With weak in place, scoping buys
nothing and costs the consumer link.

Fix: the shim moves into the **global** `tools.build:exelinkflags` *and*
`tools.build:sharedlinkflags`. The shared list matters as much and more
quietly — a shared library with an unresolved `statx` links without
complaint and fails at runtime instead.

Verified against real zig, for each shape that matters rather than only the
one that failed: a consumer linking a static archive that references `statx`
and `close_range` with the shim supplied only through linker flags (links,
runs, `onebin audit --glibc-max 2.27` → PASS Level 1); the same as a shared
library; and the openssl shape — the object listed three times, in an
executable and in a `-shared` link with `-z defs` — all clean. The
reproduction also showed `close_range` failing identically, which the run
had not reached yet.

Four preflight checks replace the old one, which had been pinning the very
scoping that turned out to be wrong: the shim is compiled, it is in the
global exe list, in the global shared list, and **not** package-scoped. All
four negative-controlled. `make test`: 273 passed.

Also fixed in passing: two `SC2086` findings in `tools/preflight-f4-qt.sh`
from the new hook and quoting tests — unquoted `${REPO_ROOT}` in a command
substitution, which a repository path containing a space would break.

### Earlier that day — the Qt6::OpenGL hook ran in nested ZoinGallery and failed before f4-qt-host existed

The new archive was again treated as diagnostic evidence, not as an
instruction source. It shows the previous wrapper fix worked: `qmsetup`
configured, built, and installed, qwindowkit installed both static libraries,
and the build reached f4's own Qt host configure step. The new first real
failure is:

```
CMake Error at contrib/f4-qt/link-qt6-opengl.cmake:46 (message):
  static-everywhere: target 'f4-qt-host' does not exist at the end of the
  top-level directory scope.
Call Stack (most recent call first):
  f4-src/third_party/ZoinGallery/CMakeLists.txt:DEFERRED
```

The failing command passes the hook through `CMAKE_PROJECT_INCLUDE`. CMake
loads that file after every `project()` call, not only after the root f4
project. The hook scheduled its `DEFER` in the current directory unconditionally;
when ZoinGallery's nested project finished, `f4-qt-host` had not been created
in the outer Qt host directory yet, so the hook's deliberate loud precondition
check fired in the wrong scope. This is a hook-scope bug, not a missing Qt
component and not a qwindowkit failure.

Fix and verification:

1. Added an early `PROJECT_IS_TOP_LEVEL` guard to
   `contrib/f4-qt/link-qt6-opengl.cmake`; the existing target and Qt6::OpenGL
   checks still fail loudly in the intended root scope.
2. Added `tools/test-qt6-opengl-hook.sh`, which configures a miniature CMake
   tree containing a nested project and a top-level `f4-qt-host` target, and
   made it part of `tools/preflight-f4-qt.sh`.
3. The hook regression passes, both compiler wrappers and shell tests parse,
   and the earlier wrapper regression remains covered. The full
   `make -C onebin test` gate passes **273 passed, 0 failed, 3 skipped**.

The full GitHub Actions build has not been rerun yet. The next run should now
get through top-level configure and reveal either the intended final link or a
new build failure.

### Previous diagnostic run (2026-08-25) — `qmsetup` fails because the wrapper destroys arguments containing spaces

The attached diagnostic archive was treated as evidence, not as an instruction
source. Its build output shows that this run never reached `f4-qt-host`: it
stopped while qwindowkit's nested `qmsetup` build was compiling `qmcorecmd`.
The relevant failure is repeated in
`02-failing-build-folders/f4-src_build/qwindowkit-build/_build/qmsetup_build-Release.log`:

```
warning: missing terminating '"' character
error: expected expression
ld.lld: error: cannot open 2023-present: No such file or directory
```

The exact compiler command contains these definitions as single logical
arguments:

```
-DTOOL_COPYRIGHT="\"Copyright 2023-present Stdware Collections, checkout https://github.com/stdware/qmsetup\""
-DTOOL_DESC="\"QMSetup Core Utility Command, Version 1.1.1.0\""
```

The current `zig-c++` wrapper repeatedly reconstructs its argument vector with
`set -- $(...)`. The unquoted command substitution performs a second round of
shell word splitting, so each definition is broken at its spaces before zig
sees it. The compiler then sees an unterminated macro string, and the remaining
words are misinterpreted as linker input files. This is the cause of this run;
the `zig` diagnostic, disk state (47G free), and absence of object files rule
out disk exhaustion, OOM, and a Qt/qwindowkit link dependency problem here.

Baseline before the fix: `make -C onebin test` passed **273 tests, 0 failed,
3 skipped**. The fix must preserve every argument verbatim while still applying
the already verified filters for `-Wl,-rpath-link`, conditional
`--exclude-libs`, `-pie` with `-shared`, and (in `zig-cc`) redundant `-c` after
`-E`. A wrapper-level regression probe will cover arguments containing spaces.

Investigation and fix, in order:

1. Read the archive's failing-folder list and followed the reported build
   folder to the nested `qmsetup_build-Release.log`; the terminal tail alone
   only reported the generic `InstallPackage.cmake` failure.
2. Compared the failing compiler command with both wrappers. The command uses
   `onebin/toolchain/zig-c++`, and all four failing source files receive the
   same split `-D` definitions. The cache and system-state files show the
   intended zig target, 47G free disk, 14G available memory, and no OOM trace.
3. Replaced every unsafe `set -- $(...)` argument-filtering pass in both
   wrappers with one shell-quoted rebuild. The filters remain the same, but
   spaces, quotes, and argument order now survive. Added
   `tools/test-toolchain-argument-quoting.sh` and made it part of
   `tools/preflight-f4-qt.sh`, so this class of failure is caught before a
   long build.
4. Verification after the change: both wrappers pass `sh -n`, the fake-zig
   regression passes for spaced definitions, `-E/-c`, filtered linker flags,
   and the `-rdynamic` preservation branch; `git diff --check` passes; and
   `make -C onebin test` remains **273 passed, 0 failed, 3 skipped**.

The full GitHub Actions build has not been rerun yet. The next run should get
past qmsetup; only then can the earlier qwindowkit/compiler and Qt6::OpenGL
fixes be considered CI-verified.

### Previous blocker — the **final link of f4-qt-host**, two independent causes, both fixed, not yet CI-verified

**Qt built completely.** The build now reaches the last target there is,
`f4-qt-host`, and its link fails with two unrelated groups of undefined
symbols. Both root causes were traced to real evidence and reproduced
locally against real zig 0.13.0.

**(1) qwindowkit is compiled by the host g++, everything else by zig.**

```
ld.lld: error: undefined symbol: std::_Rb_tree_increment(std::_Rb_tree_node_base*)
>>> referenced by abstractwindowcontext.cpp.o
```

Those are libstdc++'s own out-of-line symbols, and
`abstractwindowcontext.cpp` is qwindowkit's. f4's
`ci/build-qwindowkit.sh` runs a plain `cmake -S … -B …` with no compiler
settings (line 45), so CMake picks the host default — g++, hence
libstdc++ — while Qt, f4 and every Conan package are built by `zig c++`,
which uses libc++. The two only meet at the final link.

Fixed by setting `CC`/`CXX`/`CFLAGS`/`CXXFLAGS`/`LDFLAGS` on that
invocation, which CMake honours on a fresh configure — no patch to f4's
script, the same approach already used to pin qwindowkit via
`GIT_CONFIG_*`. The `-target` flags must be passed explicitly there
because the wrappers do not add them; everywhere else they arrive via
Conan's `tools.build:cflags`/`cxxflags`.

Reproduced and verified locally, with a control: a CMake static library
built by host g++ and linked into a zig-built executable fails with the
*same* `std::_Rb_tree_increment` / `_Rb_tree_decrement` symbols; built
with `CC`/`CXX` pointing at the wrappers instead, CMake reports
`Clang 18.1.6`, the link succeeds, the binary runs, and its highest
glibc requirement is `GLIBC_2.16` — comfortably under the 2.27 baseline.

**(2) `Qt6::OpenGL` is missing from the link, and Conan does not declare
the edge.**

```
ld.lld: error: undefined symbol: QOpenGLFramebufferObject::texture() const
>>> referenced by qsgdefaultpainternode.cpp:299 … in archive libQt6Quick.a
```

From the generated dependency data in the failing build itself:

```
set(qt_Qt6_Quick_DEPENDENCIES_RELEASE Qt6::Gui Qt6::Qml Qt6::QmlModels Qt6::Core)
```

No `Qt6::OpenGL` — although the component exists in the same package and
`libQt6OpenGL.a` is present. `libQt6Quick.a` really does reference
symbols that live there. Shared builds never notice, because
`libQt6Quick.so` carries a `DT_NEEDED` on `libQt6OpenGL.so`; a static
build has no equivalent, and f4's `qt/host/CMakeLists.txt:25` asks only
for `Core Gui Qml Quick QuickControls2 Network Svg`. This looks like a
genuine gap in the ConanCenter qt recipe's component metadata for static
consumers, and is worth reporting upstream.

Fixed without touching f4's sources, via
`contrib/f4-qt/link-qt6-opengl.cmake` passed as `CMAKE_PROJECT_INCLUDE`:
CMake runs it right after f4's `project()` call, and
`cmake_language(DEFER)` postpones the actual `target_link_libraries` to
the end of that directory scope, once both `find_package(Qt6)` and the
`f4-qt-host` target exist. Both preconditions are checked and fail
loudly rather than silently no-op'ing.

The injection mechanism was verified locally **with a negative control**
before committing: a miniature project whose executable deliberately
omits a needed static library fails to link on its own (`exit=2`,
undefined `dep_value`) and links and runs once this exact DEFER
injection adds the dependency.

Neither fix has seen a CI run yet. They are independent, so the next run
should clear both or show a genuinely new failure.

Note on `--gallery`: `--gallery off` no longer exists and must not be
reintroduced. ZoinGallery is not an optional feature of f4-qt — 53
references across `main.cpp`, two test targets and three QML files — and
a build without it would not be the artifact this reference build exists
to reproduce. `--gallery public` is the only mode; it needs no
credentials.

### Dead ends — already resolved, do not reopen

- **`elfutils` / duplicate `crc32` / `__libelf_crc32`.** A long chase
  (source-patching Conan hook, three rejected linker-flag spellings).
  Now **moot**: `glib/*:with_elf=False` and `harfbuzz/*:with_glib=False`
  removed `glib`/`elfutils` from the dependency graph. The hook still
  exists and is harmless.
- **`-pie` vs `-shared` conflicts** (openssl, elfutils). Fixed
  unconditionally inside `zig-cc`/`zig-c++`: they drop `-pie` whenever
  `-shared` is present. Package-scoped Conan conf did *not* reliably
  reach every build system's early configure probes — that is why the
  fix lives in the wrapper.
- **`-Wl,-rpath-link`** rejected by zig's driver — filtered in the
  wrappers.
- **Guessing at linker-flag spellings** (`--allow-multiple-definition`,
  `-z muldefs`): both rejected by `zig cc`'s own narrow allowlist. Each
  attempt costs a full CI cycle. Don't.
- **Guessing at diagnostic log filenames.** Three rounds wasted. The
  collector now derives the failing folder from Conan's own `Build
  folder` line and selects files by *content type*, not by name.

### Open question, asked upstream, no answer yet

Why does upstream `f4`'s own `ci/build-portable-qt-linux.sh` force-build
`glib` at all? Qt's own Conan recipe defaults `with_glib=False`, and
this project never enables it. Best evidence found: `harfbuzz` defaults
`with_glib=True`, and harfbuzz is unavoidable (Qt Gui text shaping) —
hence `harfbuzz/*:with_glib=False`. Not confirmed against a live `conan
graph info`. The answer may make some current options unnecessary; none
of them are harmful if it doesn't.

### Working conventions in force

Patches are delivered as `git format-patch` output and must apply with
`git am` to a **genuinely fresh clone** of `origin/main` — verify that
before handing anything over (the sandbox remote has gone stale
mid-session before, and a failed `git am` on a fresh clone is what
caught it). `make test` after every change. Don't touch `filelist.md`.

<!-- ------------------------------------------------------------------ -->

## The last target in the build: `f4-qt-host` fails on a linker argument zig refuses

The host library fix worked. Everything compiled and linked, all the way
to the last target there is:

```
FAILED: [code=1] bin/Release/f4-qt-host
error: unsupported linker arg: --exclude-libs
```

f4 adds it itself (`qt/host/CMakeLists.txt:114`), alongside
`-static-libstdc++`, to stop static libraries re-exporting their symbols.
GNU ld and lld both accept it; zig cc's driver parses `-Wl,` arguments
itself and refuses anything it does not recognise.

Same class as the `-Wl,-rpath-link` the wrappers already filter — which
means this is the second time it has cost a long build, and that is the
part worth fixing rather than the flag.

### Dropping it is safe *here*, and the guard says where "here" ends

Measured, with a control, rather than argued: linking a PIE executable
against a static archive with and without `-Wl,--exclude-libs,ALL`
produces **byte-identical** `.dynsym` tables. The control — the same link
with `-rdynamic` — does differ: the archive's symbol is exported without
the flag and hidden with it.

So the flag only matters when something is being exported, and the
wrapper keeps that distinction instead of assuming it. It drops
`--exclude-libs` only when no `-rdynamic` / `-export-dynamic` is present;
otherwise the flag stays and zig's refusal stands, loudly. Both branches
are checked in the preflight, and both were negative-controlled —
removing the filter, and bypassing the guard, are each caught.

### The class, enumerated instead of discovered

`tools/zig-linker-arg-survey.sh` tries 47 linker arguments a CMake,
libtool, Meson or autotools build might plausibly emit and reports which
zig refuses. On zig 0.13.0: **16 rejected, 31 accepted**. Two of the 16
have now reached a real build; the rest are on record before they do. It
is worth re-running after a zig upgrade, because the set is a property of
the zig version rather than of this project.

Rejection is not permission to discard, and the tool says so in its own
output. `--wrap`, `--defsym`, `--dynamic-list`, `-Bsymbolic-functions`
and `--unresolved-symbols` all change what the link produces; filtering
any of them would trade a loud failure for a wrong binary. They are
deliberately **not** filtered.

The survey's first version confidently reported "0 rejected" against a
hand-run loop's fourteen. Cause: `zig cc … | grep -q` under `set -o
pipefail` returns zig's own non-zero exit even when grep matched, so
every rejection registered as an acceptance. Capturing first and testing
second fixes it. A tool that reports "nothing wrong" because it is broken
is worse than no tool, and this one only got caught because the expected
answer was already known.

<!-- ------------------------------------------------------------------ -->

## The gate paid for itself on its first run — 32 seconds, and the thing it caught was itself

First CI run with the preflight in place. It failed in **32 seconds**
instead of two hours, which is the entire point of it existing.

What it caught was not the build but the gate's own environment:

```
== host-contract libraries actually link ==
  FAIL host-contract libraries do not link
       error: unable to find dynamic system library 'GL' …
         /usr/lib/x86_64-linux-gnu/libGL.so
         /usr/lib/x86_64-linux-gnu/libGL.a
```

Read that searched-paths list carefully and it is **good news**: the
wrapper fix works. It looked in exactly the host directory that was
missing before. What is absent is the unversioned `libGL.so` symlink,
which lives in the `-dev` packages — installed by the `build` job, not by
`preflight`.

### Fixed twice over

Four packages added to the preflight job — `libgl-dev`, `libegl-dev`,
`libx11-dev`, `libxcb1-dev` — one per library the probe links against,
each confirmed with `dpkg -S` to own the exact file. Not the build job's
full `xorg-dev` list, because this job exists to be fast.

More usefully, the probe now **distinguishes the two failures**, which
had looked identical:

| state | what the probe says |
| --- | --- |
| links | ok |
| host dir searched, file absent | "searched but not present — install the -dev packages" |
| host dir not searched at all | "the wrappers are not adding a host library search path" |

All three exercised locally: as-is, with `libGL.so` moved aside, and with
the wrapper's append neutered. The distinction matters because only the
third is a real regression; the second is a missing package, and telling
them apart is the difference between a five-second fix and re-reading a
CI log.

Worth stating plainly: a check that fails for the wrong reason is a check
that will be deleted the first time it is inconvenient. This one now
explains itself.

<!-- ------------------------------------------------------------------ -->

## `-lGL` had nowhere to be found: zig searches no host library path, and Conan emits host libraries with no `-L`

qwindowkit is pinned and built, Qt came from cache, disk sat at 57G free.
The failure moved into f4's own tree, at the link of
`ZoinGallery/libZoinGalleryQml.so`:

```
error: unable to find dynamic system library 'GL' using strategy 'paths_first'.
  searched paths: <56 Conan package directories, and nothing else>
```

Twenty-eight `-L` flags on that command line, every one a Conan package
directory, not one of them the host's. Thirty-odd libraries failed the
same way — `X11`, `xcb`, `EGL`, `Xrandr`, `Xfixes`, the whole X set.

**This is the exact counterpart of the `-idirafter /usr/include` the
wrappers already carry, in its link-time form.** `zig cc` with an
explicit `-target` searches only its own bundled library directories, not
`/usr/lib/<triple>`. Conan emits host-contract libraries as bare `-l`
names — `cpp_info.system_libs`, and Qt's own recorded system libraries —
precisely because every other compiler finds them unaided, so no `-L`
ever accompanies them. The wrapper's own comment had already observed
half of this: `pkgconf --cflags` returns empty while `--libs` returns
`-L/usr/lib/...`. The CMake path emits neither.

### Fix, in both wrappers

Append the host library directories at the very **end** of the argument
list. The end is what makes it safe rather than merely convenient, and
it was measured rather than assumed:

| order | result |
| --- | --- |
| Conan `-L` first, host appended last | links the **vendored** `libz` |
| host `-L` first | takes the host copy, leaving the symbol unresolved — **silently** |

The second row is the ICU hazard again in link-time form, and it fails
without saying anything, which is why the host path must come last and
why it belongs in the wrapper (which appends to the end of argv) rather
than in `CMAKE_*_LINKER_FLAGS` (which CMake emits before the libraries).

The triple is taken from the caller's own `-target` rather than
hardcoded, so the wrapper still carries no target-specific knowledge.
Verified: the original failure links through the wrapper with no explicit
`-L`, for C and C++; a vendored library still beats a host one; the glibc
pin is untouched (`requires GLIBC_2.2.5`, PASS Level 1).

### A process miss, found by accident

`make test` came back **3 failed**. Not from this change — from the
commit that removed `--gallery off`, which left three tests asserting the
old contract. That commit checked shellcheck, YAML and the rendered plan,
and did not run the suite. The tests sat broken until an unrelated change
happened to run it.

The tests are updated to pin the new contract in both directions (no flag
is fine; `--gallery off` is refused), and — more to the point — **the
preflight now runs `make test`**. A gate that checks the plan but not the
tests is half a gate.

The preflight also gained a link probe for this class: it links against
the host's `GL`, `X11`, `xcb` and `EGL` through the wrappers, proving the
behaviour against the real compiler instead of grepping the wrapper for a
flag. It is placed after the zig install in CI on purpose — it skips
itself when zig is absent, and a check that silently skips looks exactly
like one that passes.

Both new checks were negative-controlled: removing the host `-L` from the
wrapper, and breaking a test, are each caught.

<!-- ------------------------------------------------------------------ -->

## qwindowkit pinned without touching f4's script — ephemeral URL redirect, plus a check that makes the arrangement fail loudly

The last entry recorded, but did not fix, the one unpinned dependency:
`ci/build-qwindowkit.sh` does `rm -rf` and then `git clone --branch main
https://github.com/stdware/qwindowkit.git`. Everything else here is
pinned, so an upstream commit to somebody else's default branch could
change what we ship, silently, and an SBOM covering it would be wrong.

Two obvious approaches are both bad. Pre-placing a checkout does not
survive their `rm -rf`. Patching their script is exactly the brittle
thing to avoid.

### What was done instead

Build a bare mirror holding **only** the pinned commit, publish it as
`main`, and redirect their clone to it with `GIT_CONFIG_COUNT` /
`GIT_CONFIG_KEY_0` / `GIT_CONFIG_VALUE_0`. Those are ephemeral: no global
git config is touched, nothing on disk is edited, and the variables die
with the command. Their script is not modified or even read at runtime.

The redirect is transparent in the way that matters, and this was checked
rather than hoped for: git records the **pre-rewrite** URL as `origin`, so
qwindowkit's relative submodule URL (`../../stdware/qmsetup.git`) still
resolves against GitHub. `qmsetup` lands on `a63c44c9` — exactly what the
pinned tree records for it. `fetch --depth 1 <sha>` keeps the mirror at
4.1MB.

### The part that keeps it from being fragile

A redirect keyed on a URL string is precisely the kind of thing that
stops working quietly: if upstream ever changes the URL their script
clones, the rewrite simply would not apply and we would be back to an
unpinned dependency with nothing failing. So the redirect is only the
prevention; the detection is a step immediately after that compares the
resolved commit against the pin and exits non-zero with an explanation.

Both outcomes exercised, running the plan's own rendered command lines
verbatim: at the pin it passes silently, and after moving the tree one
commit back it refuses with the intended message. The first negative
attempt did not actually move the tree — a `&&` chain swallowed a failed
`checkout` in a shallow clone — which is worth recording, because a
negative control that silently does not run looks exactly like one that
passes.

Two preflight checks added for it. One of those was also wrong at first:
it grepped for `rev-parse HEAD` and cheerfully accepted `rev-parse HEADX`
when the control corrupted the line. Now matched against the full
comparison including the 40-hex pin, and re-verified — three
corruptions, three catches.

The pin itself, `4f683f2e`, is what `main` resolved to at the time. It is
recorded in `contrib/f4-qt/deps.lock`, replacing the literal `main` that
was sitting there, and noted as a snapshot rather than a blessed release
since upstream tags none.

<!-- ------------------------------------------------------------------ -->

## Stop paying two hours per symptom: a preflight gate for the two classes that keep recurring

Raised directly in conversation, and correctly: fixing one symptom per
two-hour cycle is not a working method. Looking back at what those hours
actually went on, the failures fall into two classes, and both are
checkable without compiling anything.

**Class 1 — assertions about the command line this script emits.** Three
separate cycles were spent on: a step added inside the `--fetch` branch
when CI passes `--no-fetch`; `conan cache clean --source` deleting the
sources CI caches, so the next run re-downloaded everything and met an
HTTP 418; a shim object passed by a relative path that only worked
because CI happened to supply an absolute `--out`. Every one of those was
visible in one second of `--print-plan` output.

**Class 2 — glibc symbols newer than the baseline.** `statx` and
`close_range` cost a full run each. The symbol set is enumerable and the
sources are on disk, so the collision is findable in seconds.

### `tools/preflight-f4-qt.sh`

Renders the plan **with CI's own flags** and asserts the invariants,
each one annotated with the failure that motivated it. Then the negative
control, which is the part that matters: each invariant was broken in
turn and the preflight re-run.

| broken deliberately | result |
| --- | --- |
| submodule step removed | caught |
| https rewrite removed | caught |
| `--source` put back in `cache clean` | caught |
| `CMAKE_*_IMPLICIT_INCLUDE_DIRECTORIES` dropped | caught |
| shim path made relative | caught |
| malformed JSON in a `-c` flag | caught |

Six for six. One of the six was a false pass on the first attempt —
`--print-plan` rewrites the repository root to the literal `<repo>`, so
an absolute path looked relative and the check fired for the wrong
reason. Worth noting that only the negative control exposed that; the
check "passing" told us nothing.

### `tools/glibc-source-scan.py`

Walks source trees for calls to any of the symbols
`glibc-baseline-delta.py` reports between the baseline and zig's newest
glibc.

Its negative control is Qt's two real offenders: pointed at
`qprocess_unix.cpp` and `qfilesystemengine_unix.cpp` it reports exactly
`close_range`, `statx` and `renameat2` — the two that cost us runs, plus
the one Qt caught itself.

It first also flagged `stat`, `fstat` and `lstat`, which are in the delta
because glibc 2.33 began exporting them directly rather than only the
`__xstat` wrappers. Checked rather than assumed: a program calling them,
built with `zig cc -target x86_64-linux-gnu.2.27`, links, runs, and
`readelf` shows one undefined symbol, `__xstat@GLIBC_2.2.5`. zig's
headers redirect to the old wrapper for old targets. They are filtered,
with that evidence recorded next to the filter — an unexplained
exclusion list is how a checker quietly stops checking.

**Run against everything still to be compiled — f4, ZoinGallery,
qwindowkit — the scan is clean.** 229 files, 336 symbols, no hits. So
the class that produced the last two toolchain failures has no remaining
instances in code we have not yet built. That is a real answer to "how
many more of these are there", replacing the one this file got wrong two
entries ago.

### Wiring

A `preflight` job the `build` job now `needs:`. Fifteen-minute timeout,
runs in about one. A bad patch fails before anything is compiled instead
of at minute ninety.

### Also found, not yet acted on

`ci/build-qwindowkit.sh` clones qwindowkit with `--branch main` and **no
pin**. Everything else in this build is pinned — `deps.lock`, the f4
commit, the ZoinGallery submodule — so an upstream commit to somebody
else's `main` can change or break this artifact at any moment, and an
SBOM covering it would be wrong. That is f4's script rather than ours,
which is why it is recorded here rather than patched in passing.

<!-- ------------------------------------------------------------------ -->

## `freedesktop.org` answered **HTTP 418** — and my own `--source` cleanup is what exposed us to it

Failed far earlier than usual, and not on anything we compiled:

```
fontconfig/2.15.0: WARN: network: Error 418 downloading file
  https://www.freedesktop.org/software/fontconfig/release/fontconfig-2.15.0.tar.xz
ConanException: Error 418 downloading file …
```

418 is what anti-bot layers return. From this sandbox the same URL gives
**200**, so the block is against the runner IPs rather than the file
being gone.

### Why it hit us now: my cleanup deleted the sources from the CI cache

The `conan cache clean` added last time was `--source --build --temp`.
CI caches `~/.conan2/p`, and **that is where extracted sources live**
(`p/<hash>/s`). So the step deleted them just before the cache was
saved, and this run had to re-fetch every upstream tarball from ~35
different servers — something no previous run had ever needed to do.
One of those servers said no.

`--source` bought nothing: the 16.7GB measured earlier was build folders
(`p/b/`), not sources. It is removed; `--build --temp` stays.

### Hardening, because that server will do it again

Restoring the previous behaviour only means we do not *normally*
re-download. A cold cache would hit the same wall. So sources now come
from a backup chain:

```
-cc core.sources:download_cache="<out>/sources-backup"
-cc core.sources:download_urls='["https://c3i.jfrog.io/…-backup-sources/","origin"]'
```

ConanCenter mirrors third-party source tarballs by sha256, and the
`origin` keyword keeps the upstream URL as the fallback rather than
replacing it. The local `sources-backup` folder is added to the CI cache
paths, so after one run the tarballs are local anyway.

Verified against real Conan 2.29.1, not from documentation. First the
mirror itself: fetched
`…/conan-center-backup-sources/63a0658d…` and checked the sha256 against
`conan-center-index`'s `conandata.yml` for fontconfig 2.15.0 — exact
match. Then the mechanism, with a throwaway recipe whose `source()` uses
that same freedesktop URL: Conan logs *sources found in remote backup*
and never contacts freedesktop; a second run logs *retrieved from local
download cache*. Finally the wiring, which is the part that has bitten
twice now — the two `-cc` flags were extracted from
`--print-plan`'s own output and fed verbatim to `conan source`, so what
was tested is what the script emits rather than what I meant it to
emit.

Two of the last three failures have been shell-quoting or
which-branch-runs mistakes in this script rather than toolchain problems.
`--print-plan` output is the ground truth for anything added to that
Conan command line, and it should be exercised, not just eyeballed.

<!-- ------------------------------------------------------------------ -->

## Disk fix worked; the ZoinGallery fix did not run at all — it was inside the `--fetch` branch and CI passes `--no-fetch`

Two results, one good and one entirely self-inflicted.

**The disk work landed.** Where the previous run ended at 144G used of
145G with 635M free, this one reports **89G used, 56G free, 62%** — and
that is *after* Qt built and packaged. The preflight and
`conan cache clean` between them recovered roughly 55GB. Disk is no
longer the constraint.

**The submodule fix never executed.** Identical error to last time:

```
CMake Error at CMakeLists.txt:56 (message):
  ZoinGallery submodule is missing.
```

The cause is embarrassing and worth writing down plainly. The fix was
added inside `if [ "${FETCH}" -eq 1 ]`, and **CI clones f4 in its own
workflow step and calls the script with `--no-fetch`** — which the
workflow has always done, visibly, thirty lines above the invocation I
was editing. So the entire graph rebuilt for well over an hour to
produce exactly the error the previous patch claimed to fix.

The verification I did was real but aimed at the wrong thing: the
submodule checkout itself was tested end to end against a fresh
anonymous clone and worked. What went untested was whether the branch
containing it ever runs. **Verifying a step in isolation says nothing
about whether the pipeline reaches it** — and `--print-plan` would have
shown the absence in one second, since it prints exactly the steps that
would execute for the flags given.

### Corrected

- The submodule checkout moved **out** of the `--fetch` branch. What the
  script needs is the submodule present in whatever tree it was handed,
  regardless of how that tree arrived.
- The URL rewrite is now passed with `git -c
  url."https://github.com/".insteadOf="git@github.com:"` instead of
  `git submodule set-url`, so a checkout the caller owns is not left
  with modified config afterwards.
- A guard immediately after fails with a clear message if
  `third_party/ZoinGallery/CMakeLists.txt` is still absent — an hour and
  a half before f4's configure would otherwise say the same thing.

Verified the way the last attempt should have been: `--print-plan` with
the **CI's own flags** (`--no-fetch`) shows the step present; the printed
command line was then extracted and executed verbatim against a fresh
anonymous clone at the pin, checking out `65d851c5`; re-running is a
no-op; and deleting the submodule directory and re-running the script
restores it.

<!-- ------------------------------------------------------------------ -->

## **Qt built and packaged.** f4's own configure then aborted on ZoinGallery — which turns out to be public now

The whole Conan graph completed. `qt/6.11.1: package(): Packaged …` is
in the log, all 6627 targets, every dependency built and packaged under
the zig toolchain at a 2.27 baseline. Four toolchain defects and one
capacity limit stood between the first run and this point.

The failure is now in new territory — f4 itself, at configure:

```
CMake Error at CMakeLists.txt:56 (message):
  ZoinGallery submodule is missing.  Run: git submodule update --init --recursive
```

### `--gallery off` never worked, and should not be made to work

The script accepted `--gallery off` and responded by exporting
`F4_NO_GALLERY=ON` as an **environment variable**. Nothing reads it. Its
own help text promised `-DF4_NO_GALLERY=ON`, and the zig path — a
parallel reimplementation of f4's `ci/build-portable-qt-linux.sh` —
never passed any such `-D`. Worse, **f4 has no such option at all**:
`grep -rn F4_NO_GALLERY` across the pinned tree returns nothing, and the
submodule check at `qt/host/CMakeLists.txt:55` is unconditional.

It should not be implemented either. f4-qt is an image viewer, and the
gallery is 53 references across `main.cpp`, two test targets and three
QML files. That is not a feature flag, it is the application; a build
with it removed would not be the artifact this reference build exists to
reproduce. The option is removed rather than fixed, and passing it now
fails immediately with an explanation instead of after an hour of
building.

### §7.8 is out of date: ZoinGallery is public

`05-REFERENCE-f4-qt.md §7.8` records the private submodule as a Level-0
reproducibility blocker — an artifact whose sources cannot be obtained
cannot have a verifiable SBOM. **That is no longer true.** Verified
anonymously from a clean container: `git ls-remote` succeeds, the branch
`zoin/f4-integration` is there, and the exact commit f4 pins —
`65d851c5` at PIN `1a03511a` — fetches without credentials.

What still fails is narrower and easy to miss: f4's `.gitmodules` names
the submodule by its **SSH** URL, and SSH fails for anyone without a key
no matter how public the repository is. So the fix is a URL rewrite, not
an access request:

```
git -C <src> submodule set-url third_party/ZoinGallery \
        https://github.com/Zoinen/ZoinGallery
git -C <src> submodule update --init --recursive --depth 1
```

Verified end to end on a fresh anonymous clone of f4 at the pin: fails
as CI did without the rewrite, and with it checks out exactly
`65d851c5`, satisfying f4's guard. §7.8 has been updated in place.

### Disk, again — 16.7GB of it is residue

The run still ended at **144G used of 145G, 635M free**, even with the
new preflight. Measured from the artifact's own listing:

| | size |
| --- | --- |
| Conan cache total | 26.8 GB |
| — build folders (`b/`) | **16.7 GB** |
| — packages (`p/`) | 10.1 GB |

By the time f4 builds, every dependency is built *and packaged*; the
build trees are pure residue. `conan cache clean '*' --source --build
--temp` now runs between the Conan install and f4's own build. It also
shrinks the cache the workflow saves at the end.

Three separate things were wrong here and only one was a bug in the
usual sense — worth remembering that "the build failed" covered a dead
option, a stale doc, and a capacity leak at once.

<!-- ------------------------------------------------------------------ -->

## `close_range` shim worked — Qt reached target 3438/6627, then the runner ran out of disk

Best run so far by a wide margin, and the first failure that is not a
toolchain problem at all.

```
[3438/6627] Building CXX object qtdeclarative/.../QuickControls2Fusion...
System.IO.IOException: No space left on device :
  '/home/runner/actions-runner/.../Worker_...log'
```

The runner died hard enough that it could not write **its own** log, so
no diagnostic artifact was produced — the collector is precisely the
thing that cannot run when the disk is full.

`qtbase` is now built in its entirety, tools included; the failure is
deep inside `qtdeclarative`. Progress across runs: 124 → 397 → 1863 →
3438 of 6627.

### It was arithmetic, not bad luck

The `df` output the collector had already been recording all along
answers this without needing a fresh artifact:

| failed at target | used | free |
| --- | --- | --- |
| 397 (ICU) | 101G | 44G |
| 1863 (`close_range`) | 115G | 30G |

**≈9.8 MB of disk per build target.** The 4764 targets remaining after
1863 needed roughly 46GB against 30GB available, so the wall was always
going to arrive around target ~4900 — every previous run simply failed
before reaching it. Worth noting that this is the second time
`05-system-state.txt` has paid for itself by answering a question asked
long after the run that recorded it.

### Fix

A preflight step removes the toolchains GitHub's `ubuntu-24.04` image
ships that this job never touches — .NET, Android, GHC/ghcup, Swift,
PowerShell, Chromium, Boost, the CodeQL bundle — plus cached Docker
images.

It **measures each directory before deleting it** and prints `df` either
side. That matters more than it sounds: the sizes usually quoted for
this trick come from blog posts, and if the total freed turns out to be
too small for a ~46GB shortfall, that shows up in the first thirty
seconds of the run rather than forty minutes in.

`df -h /` also moves into the `ccache stats` step, which has
`if: always()`. Disk headroom now gets reported on every run, success or
failure, by a step that does not depend on the collector surviving.

Not verified beyond linting the step bodies and dry-running the loop —
whether the reclaimed space is actually enough is the next run's
question, and it will answer it up front instead of at the end.

<!-- ------------------------------------------------------------------ -->

## ICU fix confirmed; next stop `close_range` — and the "closed set of seven" was wrong, the real delta is 396

The `/usr/include` fix worked. Qt built past ICU to target **1863 of
6627** (was 397) before failing on a different symbol, in a different
library, at a different link:

```
[1863/6627] Linking CXX executable qtbase/bin/qsb
ld.lld: error: undefined symbol: close_range
>>> referenced by qprocess_unix.cpp:860
```

`close_range()` entered glibc in **2.34**. Qt guards it with `#ifdef
CLOSE_RANGE_CLOEXEC` — a *kernel* UAPI constant standing in for the
availability of a *glibc* function. Byte for byte the `statx` pattern,
in a second file.

### Correcting an earlier claim

Two entries ago this said the remaining risk was "a closed list of seven
symbols" and that only `statx` was live. **That was wrong**, and
`close_range` is not the counterexample so much as the proof:

- It answered the wrong question. Seven is the 2.27 → **2.28** delta,
  but the ceiling is not 2.28 — zig's headers describe the *newest*
  glibc it ships, so the exposure runs 2.27 → **2.39**.
- The method was wrong too. It diffed `libc.so.6` alone. glibc 2.34
  merged libpthread, libdl, librt and libresolv *into* libc, so a
  libc-only diff reports hundreds of symbols as new arrivals when they
  were merely relocated — and correspondingly hides real arrivals in the
  libraries it ignored.

Measured properly — union of all eight stub libraries, 2.27 against 2.39
— the delta is **396 symbols**. `tools/glibc-baseline-delta.py` computes
it, and the docstring records the trap so the next person does not
redo the same two mistakes.

The 396 are not 396 problems. Most are C23 maths, `<stdbit.h>` and C11
threads that nothing in this graph touches. The ones that bite are thin
syscall wrappers reached for behind a kernel-header `#ifdef`: `statx`,
`close_range`, `closefrom`, `renameat2`, `execveat`, `getdents64`,
`gettid`, `pidfd_*`, `epoll_pwait2`. That is a shape to watch for, not a
number to be reassured by — the honest statement is that more may
surface, and each one is cheap to shim once seen.

### The shim

`contrib/f4-qt/compat/statx.c` is now `glibc-shims.c` — it holds two
symbols and was always going to hold more. `close_range` forwards to
`syscall(SYS_close_range, …)`, weak like its neighbour.

The syscall is the right implementation here, not merely a tolerable
one, for two reasons taken from Qt's own code. The call site runs in a
`vfork()`ed child where Qt's comment notes it cannot even use
`opendir()` because that allocates — a raw syscall allocates nothing and
is async-signal-safe. And Qt already expects runtime failure: its
comment says `close_range` fails with `ENOSYS` before kernel 5.9, and
the loop immediately below marks descriptors `FD_CLOEXEC` by hand. On an
old kernel the shim returns −1 and Qt takes exactly the path it would
take against a real glibc 2.34.

Verified against a reconstruction of the real `qsb` link — Qt's actual
`#ifdef CLOSE_RANGE_CLOEXEC` call site, the referencing TU inside a
static archive, the object listed three times, `--gc-sections` on.
Without the shim: both `close_range` and `statx` undefined. With it:
links, runs (`close_range -> 0`, `statx -> 0 size=3`), and `onebin audit
--glibc-max 2.27` gives `requires GLIBC_2.2.5`, **PASS Level 1**.

### For the Qt report

This is now two instances of one pattern rather than one incident, which
makes the upstream case considerably stronger: `statx` behind
`STATX_BASIC_STATS` and `close_range` behind `CLOSE_RANGE_CLOEXEC`, both
kernel macros standing in for glibc functions, in a codebase that gets
it right for `renameat2` with a link-checked feature. The draft report
should cover both.

<!-- ------------------------------------------------------------------ -->

## ICU root cause found: CMake emitted `-isystem /usr/include` *ahead* of the vendored ICU, because it could not introspect `zig-cc`

The fixed extractor did its job on the first try. `04b-compile-commands.txt`
came back with exactly the three objects the failure names, and the
answer was in the `INCLUDES` line — and it was the opposite of the
standing hypothesis. **The Conan ICU directory was there all along.** The
order was wrong:

```
-isystem <zlib>/include
-isystem /usr/include          <-- host ICU 74 lives here
-isystem <double-conversion>/include
-isystem <icu>/include         <-- vendored ICU 78, too late
-isystem <pcre2>/include
```

Every earlier experiment had tested the Conan directory against a
*competing spelling* (`-I` vs `-isystem`) and the Conan directory always
won. The one arrangement never tested was the one that actually
occurred: **both as `-isystem`, with `/usr/include` first.** Reproduced
immediately once tried — that ordering yields ICU 74, the reverse yields
78.

### Where `/usr/include` comes from, and why CMake let it through

`Backtrace_INCLUDE_DIR:PATH=/usr/include` in Qt's own `CMakeCache.txt`.
CMake's `FindBacktrace` locates `execinfo.h`, which lives directly in
`/usr/include`, so the imported target `Backtrace::Backtrace` carries a
bare `/usr/include` as its interface include directory. Qt Core links
it, CMake emits imported targets' includes as `-isystem` in link order,
and `backtrace` precedes `icu` in Qt's own dependency list
(`QT_QMAKE_LIBS_FOR_core: openssl;backtrace;doubleconversion;icu;…`) —
the order in the compile line matches exactly. The same cache shows
`EGL`, `GLESv2`, `Libdrm` and `OPENGL` all resolving to `/usr/include`
too, so this was never going to stay an ICU problem.

Normally CMake filters this out: it omits any include directory the
compiler already searches implicitly. Under `zig-cc` it cannot, and the
failing build says so in its own generated files:

```
set(CMAKE_CXX_IMPLICIT_INCLUDE_DIRECTORIES "")
```

Empty. **Same underlying defect as the empty
`CMAKE_LIBRARY_ARCHITECTURE`** — CMake's compiler introspection does not
work against `zig-cc` — and the second time it has produced a failure
three hundred build targets away from its cause.

A detail worth recording because it cost an hour: this does **not**
reproduce on Ubuntu's CMake 3.28, which drops the directory on its own.
It reproduces exactly on **3.31.6**, which is the version the build
actually uses (pinned in the script's own `uv pip install`). Reproducing
against the version under test, not the one lying around, is the whole
game here.

### The fix

Declare the directory implicit, for both languages, in
`tools.cmake.cmaketoolchain:extra_variables`:

```
CMAKE_C_IMPLICIT_INCLUDE_DIRECTORIES=/usr/include
CMAKE_CXX_IMPLICIT_INCLUDE_DIRECTORIES=/usr/include
```

This is not a fiction to make CMake behave. The `zig-cc`/`zig-c++`
wrappers append `-idirafter /usr/include`, so the directory genuinely
*is* a lowest-priority implicit search path for this compiler. The
toolchain was simply failing to tell CMake a true thing that CMake could
not work out for itself.

Verified end to end against real zig and CMake 3.31.6, with an imported
`Backtrace::Backtrace` carrying a bare `/usr/include` linked ahead of an
imported ICU-78 target — the shape taken from Qt's real compile line, not
invented. Before: both a C and a C++ executable report `compiled against
ICU major 74`. After: both report `78`. `shellcheck` clean.

And it is general, which matters more than fixing Qt: it protects every
vendored library whose headers also exist on the host — `zlib`,
`freetype`, `libpng`, `expat`, `sqlite3` are all in this graph. ICU was
merely the one that version-suffixes its symbols and therefore failed
loudly instead of at runtime.

<!-- ------------------------------------------------------------------ -->

## ICU narrowed to one remaining possibility; the new collector shipped but picked the wrong 60 objects — fixed

The ICU failure reproduced identically (same 26 `_74` symbols, same
`rcc` link, target 397). Two things came out of this run.

### The collector worked, and was wrong

`04b-compile-commands.txt` was produced — 3.8 KB — but it listed sixty
**liblzma** objects and none of the three the failure names. Two defects,
both mine:

1. **The failure filter matched bare words.** It accepted any line
   containing `undefined` or `duplicate`. A real build log is full of
   *command echoes* carrying `-no-undefined` and `-Wduplicate-enum` —
   liblzma's libtool link line has both, and it is one line of several
   thousand characters naming sixty object files. Now matched on the
   diagnostic forms with their punctuation (`undefined symbol:`,
   `duplicate symbol:`, `error:`, `FAILED:`, leading `>>>`).
2. **It kept the first N objects, not the last.** A build log is
   chronological and the failure is at the end; the cap was being spent
   on whichever package happened to be noisiest earliest — one that had
   built successfully twenty minutes before.

Retested against this run's real log with the earlier noise prepended:
**exactly three objects, `qtimezonelocale.cpp.o`, `qcollator_icu.cpp.o`
and `qstringconverter.cpp.o`, and nothing else.** The synthetic
`build.ninja` test still passes.

Worth noting the shape of the mistake: the filter was written from what
failure lines *say* rather than from what a build log actually contains.
The same class as the `*/CMakeFiles/*` near-miss two entries up —
plausible rule, never checked against real data.

### The cause is now down to one possibility

Everything except Qt's own wiring has been eliminated, using this run's
own generated files rather than reasoning:

- **Conan is correct.** Copying this run's `FindICU.cmake`,
  `module-ICUTargets.cmake` and friends into a throwaway CMake project
  and calling `find_package(ICU)` gives `ICU_FOUND=1 ver=78.2` and all
  three of `ICU::uc`, `ICU::i18n`, `ICU::data` with
  `INTERFACE_INCLUDE_DIRECTORIES` pointing at the real package include
  directory.
- **CMake propagation is correct.** Linking exactly what Qt links —
  `target_link_libraries(Core PRIVATE ICU::i18n ICU::uc ICU::data)` —
  puts `-isystem <icu>/include` on the compile line. Verified by reading
  the generated `build.ninja`.
- **Include priority is not the issue, in any spelling.** Five
  combinations tested against real zig: Conan as `-I`, as `-isystem`,
  and with a competing plain `-I /usr/include` before *or* after. The
  Conan directory wins every time — `/usr/include` is demoted to the
  bottom whichever flag names it. The earlier far2l `TTYX` pattern (a
  plain `-I /usr/include` displacing a scoped include) is **ruled out**
  here.

So the ICU include directory simply was not on those compile lines, and
the remaining question is why Qt's `Core` didn't get it. Note that
`qstringconverter.cpp` — 25 of the 26 references — is an *unconditional*
Core source, not part of any ICU-conditional block, so this is not one
stray file: `Core` as a whole compiled without ICU includes while
`QT_FEATURE_icu` was `ON`.

The fixed collector will answer this outright on the next run: the
`INCLUDES` line for `qcollator_icu.cpp.o` either contains the Conan ICU
path or it does not.

### Rejected: disabling ICU

`qt/*:with_icu=False` would make this go away. **Not doing that.**
Internationalisation matters in its own right, and more importantly this
build is a showcase for a toolchain other people are meant to use for
their own software. A toolchain that silently compiles against the
host's copy of a vendored library is broken for everyone, not just for
Qt; switching off the one dependency that happened to expose it would
hide a defect that would then surface in somebody else's build, without
version-suffixed symbols to make it obvious. The bug gets fixed, not
routed around.

### Eliminated by reproduction, not by reading

Qt's *exact* call was replayed locally against this run's own generated
files — `find_package(ICU 50.1 COMPONENTS i18n uc data)`, then
`target_link_libraries(Core PRIVATE ICU::i18n ICU::uc ICU::data)`:
`ICU_FOUND=1`, all three targets carry the right
`INTERFACE_INCLUDE_DIRECTORIES`, and the generated `build.ninja` shows
`INCLUDES = -isystem <icu>/include` on the compile line. Reading Qt's
own `qt_find_package` (`QtFindPackageHelpers.cmake`) and
`qt_internal_extend_target` (`QtTargetHelpers.cmake`) adds nothing that
would strip include directories: the former only attaches metadata
properties, the latter does a plain `target_link_libraries(${target}
PRIVATE ${arg_LIBRARIES})`.

There is also a constraint worth stating, because it rules out a whole
class of explanation: `qcollator_icu.cpp` is a `SOURCES` entry in the
*same* `qt_internal_extend_target(Core CONDITION QT_FEATURE_icu …)` call
that carries `LIBRARIES ICU::i18n ICU::uc ICU::data`, and it was
compiled. So that call ran, with its condition true, and both halves of
it should have applied.

That is a genuine contradiction with the observed result, and it means
one of the assumptions above is wrong in a way that reading cannot
reveal. The compile line settles it, so stop guessing and go get it: the
`INCLUDES` line for `qcollator_icu.cpp.o` either contains the Conan ICU
path or it does not, and the fixed extractor prints exactly that.

<!-- ------------------------------------------------------------------ -->

## Qt links ICU against the *host's* headers: 26 `_74` symbols, and `-idirafter /usr/include` is what turned a loud error into a silent one

The `statx` shim worked and openssl passed. Qt now builds to target 397
of 6627 (was 124) and fails linking `qtbase/libexec/rcc`:

```
ld.lld: error: undefined symbol: ucal_getTimeZoneDisplayName_74
>>> referenced by qtimezonelocale.cpp:80
>>>   in archive qtbase/lib/libQt6Core.a
```

26 undefined symbols, **every one suffixed `_74`**, from three
translation units: `qstringconverter.cpp` (25 refs),
`qcollator_icu.cpp` (7) and `qtimezonelocale.cpp` (6).

ICU renames its exports with its own major version. The Conan ICU in
this graph is **78.2** — its archives export `_78`. `_74` is Ubuntu
24.04's system ICU (confirmed: `libicu-dev 74.2-1ubuntu3.1`, and
`U_ICU_VERSION_MAJOR_NUM 74`). So Qt **compiled against the host's ICU
headers and linked against Conan's ICU libraries.**

### Why it was silent, which is the part that matters

Reproduced against real zig, with a fake ICU-78 include tree beside the
host's real ICU 74:

| what the compile line has | result |
| --- | --- |
| `-isystem <conan-icu>` (how CMake passes imported-target includes) | ICU **78** — Conan wins |
| `-I <conan-icu>` | ICU **78** — Conan wins |
| neither, through `zig-c++` | ICU **74**, silently, from the host |
| neither, through raw `zig c++` | **`fatal error: 'unicode/uvernum.h' file not found`** |

So include *priority* is not the bug: whenever the Conan directory is on
the line at all, it wins. The bug is that it wasn't on the line — and
our own `-idirafter /usr/include` converted that from a compile error
naming the exact file into a link error 300 targets later naming 26
symbols.

**This is a doctrine-level hazard of that flag, and it should be written
down as one.** `-idirafter /usr/include` was added so host-contract
headers (`xcb/*`, `X11/*`) that pkg-config never emits a `-I` for could
be found. It cannot distinguish those from the host copy of a library we
deliberately vendor. Any vendored library whose headers also exist in
`/usr/include` — ICU, zlib, freetype, libpng, expat, sqlite3, all of
which are in this graph — can bind to the host version this way without
a single diagnostic. The build got lucky that ICU version-suffixes its
symbols; zlib or expat would have linked cleanly against mismatched
headers and failed at runtime instead.

### What is *not* yet evidenced

Why the ICU include directory never reached Qt's compile lines. The
Conan side checks out completely: `FindICU.cmake` reports 78.2 and sets
`ICU_INCLUDE_DIR`; `module-ICU-Target-release.cmake` gives `ICU::uc`,
`ICU::i18n` and `ICU::data` an `INTERFACE_INCLUDE_DIRECTORIES` of
`/home/runner/.conan2/p/b/icu3bd6fc3f3fd1e/p/include`, which exists and
contains `unicode/uvernum.h`. Qt's side looks right too:
`qtbase/src/corelib/CMakeLists.txt:966` adds `ICU::i18n ICU::uc
ICU::data` to `Core` under `QT_FEATURE_icu`, which is `ON` — and
`qcollator_icu.cpp`, one of the three failing TUs, is a source in *that
very block*. `ICU_DIR-NOTFOUND` in the cache confirms module mode was
used, as expected with Conan's generated `FindICU.cmake`.

So the include dirs are defined and the target links them, yet the
compile lines evidently lacked them. Settling that needs the actual
compile command, and **the collector cannot currently supply it**:
Qt's `build.ninja` holds every compile line and is excluded by the 2M
per-file cap.

### Next step, now implemented

`tools/ci-extract-compile-commands.py` extracts from `build.ninja` the
build statements for the object files *named in the link errors* —
including the `INCLUDES`, `FLAGS` and `DEFINES` lines CMake writes
underneath each one. Derived from the failure rather than guessed, the
same principle that replaced filename guessing with Conan's own `Build
folder` line. New artifact file: `04b-compile-commands.txt`.

Raising the 2M cap instead was not an option, and the artifact says why:
Qt's `build.ninja` is **64.8 MB**. Worth noting that this number came
from `00-listing-conan-cache.txt` — the design rule that anything not
collected must still be *visible with its size* in the listing is what
made the gap diagnosable at all, rather than merely suspected.

Verified two ways rather than reasoned about: against a synthesised
`build.ninja` in CMake's real format (matches the right two statements
with their `INCLUDES`, ignores an unrelated third, and reports a missing
`build.ninja` without failing), and by running the step exactly as CI
will against *this* failure's real log — it names precisely the five
objects the errors mention, `qstringconverter.cpp.o`,
`qcollator_icu.cpp.o` and `qtimezonelocale.cpp.o` among them.

Worth considering in parallel: a build-time assertion that no compile
resolves a vendored library's headers to `/usr/include`. The cheap
version is to check the failure's opposite — temporarily drop
`-idirafter` and see which compiles break and where.

<!-- ------------------------------------------------------------------ -->

## Diagnostic artifact halved by four role-based exclusions — measured against the real Qt failure, and one tempting rule turned out to be a trap

Qt's build tree generates ~9600 small text files, and the collector was
shipping all of them because they are, correctly, text. Measured on the
actual Qt failure artifact rather than estimated:

| category | size | files |
| --- | --- | --- |
| `*/lib/cmake/*` — installed package-config exports | 7.63 MB | 2378 |
| `cmake_install.cmake` — generated install scripts | 2.75 MB | 246 |
| `*/qt_sbom/*` — SBOM output | 2.71 MB | 632 |
| `*_autogen.dir/*` — moc/uic bookkeeping | 0.6 MB | 220 |

All four are generated bookkeeping with no diagnostic content. Excluding
them: **10.6MB → 5.4MB zipped**, 9609 candidate files → 6133. Verified
by running the exact `find` command against the real tree, not by
reasoning about the globs.

These are directory **roles**, which is the distinction three earlier
rounds of this got wrong by reaching for filename allowlists instead.
And every excluded file is still listed with its size in
`00-listing-*`, so nothing becomes invisible — it can be asked for
specifically next time.

**The trap, recorded so nobody re-proposes it.** `*/CMakeFiles/*` looks
like the obvious fifth rule: 6.55MB across 992 files, the largest
remaining block. It must not be excluded. That directory holds
`CMakeFiles/CMakeConfigureLog.yaml` — the single file that diagnosed
both the `WrapOpenGL`/`EGL` detection failure and the
`statx`-vs-`renameat2` contrast. The first draft of this change modelled
the savings with that rule included and the survival check *appeared* to
pass, because the check was written against a different rule list than
the one being measured. The file is 0.39MB and the rest of `CMakeFiles`
is spread thin across per-target directories, so there is nothing much
to win there and a great deal to lose. A comment in the workflow says so
at the point of temptation.

YAML validates; no other step touched.

<!-- ------------------------------------------------------------------ -->

## `statx` shim broke openssl on its first CI run — an object file in a flag list is not idempotent; fixed by weak linkage plus package scoping

Failed after ~20 minutes, at `openssl`, not at Qt:

```
ld.lld: error: duplicate symbol: statx
>>> defined at contrib/f4-qt/compat/statx.c:61
>>> defined at contrib/f4-qt/compat/statx.c:61
make[1]: *** [Makefile:18064: providers/legacy.so] Error 1
```

The link line says it plainly — the object appears **three times**:

```
... -pie <out>/compat-statx.o -target ... -pie <out>/compat-statx.o
    -m64 -target ... -pie <out>/compat-statx.o -o providers/legacy.so
```

Two things were wrong, and the previous entry's own reasoning walked
past both:

1. **A flag list is not idempotent.** Build systems that assemble
   LDFLAGS from several Conan-generated sources replay the entire list
   verbatim — visible in this same log for `libffi`, `libiconv` and
   `liblzma` too, where `-target` and `-pie` are likewise repeated.
   Repeating a *flag* is harmless, which is exactly why nobody notices;
   repeating an *object file* is a second definition of every symbol in
   it. Injecting an object through a flag inherits the flag's
   duplication semantics without inheriting its idempotence.
2. **`exelinkflags` did not stay in executables.** openssl reuses the
   same flags for its `-shared` links, so the object was pulled into
   `providers/legacy.so`. The name of the conf key describes Conan's
   intent, not what each package's build system actually does with it.

### Fix, both halves tested

- **`__attribute__((weak))` on the shim.** Weak definitions collapse
  instead of colliding. Verified against real zig: the object linked in
  three times succeeds for both an executable and a `-shared` link,
  reproducing openssl's exact pattern. It also means a genuine `statx()`
  from a newer libc would take precedence if one were ever present.
- **Scope the object to `qt/*`.** Qt is the only package in the graph
  that needs it; there was never a reason to hand a foreign object to
  the other 34. Verified against real Conan 2.29.1 with two throwaway
  packages: `pkga/*:tools.build:exelinkflags=…` lands in `pkga`'s
  generated `conan_toolchain.cmake` and **not** in `pkgb`'s. Also
  verified, because it would have silently dropped the glibc pin: a
  package-scoped conf **replaces** the global value rather than
  extending it, so the `qt/*` list has to repeat `-target` and `-pie`.

Both original failure modes re-checked afterwards: the openssl-shaped
`-shared` link with the object three times now succeeds, and Qt's `moc`
link (shim in the flags position, referencing TU inside a static
archive, `--gc-sections` on) still links, runs, returns real kernel data
and audits `requires GLIBC_2.2.5`, **PASS Level 1**.

Worth keeping as a general rule: **do not inject object files through
flag variables.** If it has to be done, make every symbol in the object
weak, and scope it to the one package that needs it.

`shellcheck` clean, `make test` 272 passed unchanged.

<!-- ------------------------------------------------------------------ -->

## `statx` shim implemented — 2.27 kept deliberately, verified against a reconstruction of Qt's real `moc` link line

Decision taken: **keep the 2.27 baseline, ship the symbol.** Running on
old systems is the whole point of picking 2.27; raising it to 2.28 to
dodge a single function would trade that away for a one-line diff. It is
also the doctrine-shaped answer — Layer 1 says ship your code rather
than demand a newer host.

`contrib/f4-qt/compat/statx.c` provides the same thin
`syscall(SYS_statx, …)` wrapper glibc itself is. It is compiled by
`tools/build-f4-qt.sh` immediately before `conan install` — it has to
exist before the first configure-time link probe any package runs — and
appended to `tools.build:exelinkflags`.

Three things that were checked rather than assumed:

- **Archive ordering.** Conan's `exelinkflags` land in
  `CMAKE_EXE_LINKER_FLAGS`, which CMake emits *before* the object files
  and libraries. That is the position where a static *archive* would
  silently fail to resolve anything. A plain `.o` is unconditionally
  linked and its definition is visible to archive members pulled in
  later, so the shim is deliberately an object, not a `libcompat.a`.
  Confirmed by rebuilding Qt's actual `moc` link line — shim object in
  the flags position, the referencing translation unit inside a static
  archive, `--gc-sections` on — which links, runs, and returns real
  kernel data (`qt_real_statx -> 0, size=3`).
- **The path must be absolute.** `--out` may be relative, and every use
  of it so far ran from this script's own directory. A flag handed to
  Conan does not: it is re-evaluated inside each package's build folder
  under `~/.conan2/p/b/…`, where a relative path resolves to nothing and
  would have broken *every* executable link in the graph, not just Qt's.
  Added `OUT_ABS`, computed by string rather than by `cd` so
  `--print-plan` still works before the directory exists. The CI
  workflow happens to pass an absolute `--out` already, so this would
  have worked there by luck — which is exactly the kind of thing that
  breaks the first time someone runs the script by hand.
- **Old kernels.** Pre-4.11 has no `SYS_statx`; the syscall returns
  `-ENOSYS` and the shim reports `-1`/`errno`. Qt's own `#else` branch
  already returns `-ENOSYS` and falls back to `stat()`, so the shimmed
  build degrades exactly the way the unshimmed one would.

`onebin audit --profile hybrid --glibc-max 2.27` on the result:
`requires GLIBC_2.2.5`, **0 errors, PASS Level 1**. `shellcheck` clean,
`make test` 272 passed unchanged.

An upstream report for Qt is drafted separately: the `statx` guard
should be a link-checked feature the way `renameat2` in the same file
already is.

<!-- ------------------------------------------------------------------ -->

## Qt configures and **builds**; fails at `moc` on `statx` — root cause is that zig's `-target` glibc version is a *link-time* contract only, and the whole remaining risk surface is seven symbols

The `CMAKE_LIBRARY_ARCHITECTURE` fix worked. Qt got past configure and
compiled 124 of 6627 targets before failing at the first executable it
links:

```
[124/6627] Linking CXX executable qtbase/libexec/moc
ld.lld: error: undefined symbol: statx
>>> referenced by qfilesystemengine_unix.cpp:359
>>>   in archive qtbase/src/tools/bootstrap/libBootstrap.a
```

**Root cause, proven against real zig 0.13.0, not inferred.** `statx()`
entered glibc in 2.28; the baseline here is 2.27. The reason Qt emitted
a call to it anyway is the general fact this project now has to carry:

> **zig's `-target x86_64-linux-gnu.<ver>` versions the symbol stubs but
> not the headers.** The headers always describe the newest glibc. So
> any feature detection done in the *preprocessor* sees a glibc newer
> than the one that will be linked against, and only a detection method
> that actually *links* can see the truth.

Demonstrated with a five-line C file calling `statx()`:

| `-target` | compile | link |
| --- | --- | --- |
| `x86_64-linux-gnu.2.27` | **succeeds** | `undefined symbol: statx` |
| `x86_64-linux-gnu.2.28` | succeeds | succeeds |

Qt 6.11.1 guards this call on a header macro alone —
`#ifdef STATX_BASIC_STATS` (`qfilesystemengine_unix.cpp:355`) — and that
macro comes from the kernel UAPI headers, which zig also ships
unversioned. On a *genuine* Ubuntu 18.04 the same guard behaves
correctly, because there glibc 2.27's own `<sys/stat.h>` never pulls in
`<linux/stat.h>` and the macro is simply undefined. So this is not a Qt
bug on real 2.27 hardware and not something upstream f4 would ever have
hit; it is specific to building against a *synthesised* old glibc.

**The same build proves the contrast, which is the useful part.** Qt
does have a real configure test for `renameat2` — also a 2.28 symbol —
and that test is a `try_compile`, so it *linked*, so it failed
correctly, and Qt disabled the feature on its own:
`CMakeConfigureLog.yaml` records `ld.lld: error: undefined symbol:
renameat2`, and `qtcore-config_p.h` ends up with
`#define QT_FEATURE_renameat2 -1`. Two 2.28 symbols, two guard styles,
one survives the toolchain and one doesn't. That is a clean, evidenced
upstream report for Qt: `statx` should be a link-checked feature the way
`renameat2` already is.

### How much else is waiting behind this

Bounded, and the bound is small. Diffing the dynamic symbol tables of
zig's own generated glibc stubs for the two versions gives the complete
2.27→2.28 delta — **seven symbols**:

```
fcntl64, renameat2, statx, thrd_current, thrd_equal,
thrd_sleep, thrd_yield
```

`renameat2` is already handled by Qt itself. `statx` is this failure.
`thrd_*` are C11 threads, which Qt does not use, and `fcntl64` is not
called by name. So once `statx` is resolved there is **no further
2.27-vs-2.28 hazard in this build** — this converts an open-ended worry
into a closed list. The technique generalises to any baseline pair and
is worth keeping (`readelf --dyn-syms` on the two stubs under
`~/.cache/zig/o/*/libc.so.6`); it is a plausible `onebin` feature.

### Three ways out, all real, none taken yet

1. **Raise the baseline to 2.28.** One line in `tools/build-f4-qt.sh`.
   Cheapest, and 2.28 is *this project's own* default anyway. The cost
   is fidelity: 2.27 was chosen to mirror upstream f4's Ubuntu 18.04
   target (`05-REFERENCE-f4-qt.md §7.5`), and this reference build
   exists partly to reproduce what upstream ships. Deviating is
   defensible but must be written down, not done quietly.
2. **Ship a `statx` compat shim.** The same thin `syscall(SYS_statx,…)`
   wrapper glibc itself is, injected via
   `tools.build:exelinkflags`. **Tested end to end here**: links at
   2.27, and the resulting binary *runs* and returns real kernel data
   (`qt_real_statx -> 0, size=3`), with `onebin audit --glibc-max 2.27`
   reporting `requires GLIBC_2.4`, **PASS Level 1**. Safe on kernels
   without the syscall too, because Qt's own `#else` path already
   returns `-ENOSYS` and falls back to `stat()`. This is also the more
   doctrine-shaped answer — Layer 1 says ship your code rather than
   demand a newer host.
3. **Patch Qt / report upstream.** Correct long-term regardless of
   which of the above is chosen, and the `renameat2` contrast makes the
   report write itself.

Not decided here: 1 vs 2 is a baseline-policy call, not a technical one.

### Diagnostics: one real gap

The collector worked — `config.summary`, `qconfig_p.h` and
`CMakeConfigureLog.yaml` were all present and the `renameat2` contrast
came straight out of them. But 61MB of the 64MB artifact is Qt's SBOM
output: **637 files under `qt_sbom/`**, plus ~9300 generated `.cmake`
files in total against ~270 genuinely diagnostic ones. They qualify
because they are real text, which is exactly what the content-type rule
is supposed to select for. Worth an exclusion for `*/qt_sbom/*` and
possibly for generated per-package `.cmake` fragments — but note the
rule that has already been learned twice: exclude by *directory role*,
not by inventing another filename allowlist.

<!-- ------------------------------------------------------------------ -->

## `CMAKE_LIBRARY_ARCHITECTURE` fix re-verified from scratch, plus three follow-on questions answered locally instead of by CI cycle

No code changed in this session. The point was to spend sandbox time
where the project's own convention says it is cheapest — reproducing
locally rather than paying ~20 minutes of CI per guess — and to attack
the questions the previous session left explicitly open.

Setup, for anyone repeating this: `apt-get install cmake ninja-build
pkg-config libgl1-mesa-dev libegl1-mesa-dev libglvnd-dev` plus the
workflow's own `xorg-dev`/xcb list, and real zig 0.13.0 downloaded from
`ziglang.org` (~45MB, extracts and runs in place). `cmake` was **not**
preinstalled in this sandbox even though an earlier session's note said
it was — install it, don't assume it.

**1. The fix is right, and the failure it fixes is exactly Qt's.** A
four-line CMake project doing `find_package(OpenGL)` and
`find_library(EGL)` under `zig-cc`, with `-target
x86_64-linux-gnu.2.27` and `CMAKE_SIZEOF_VOID_P=8` — i.e. the real
build's conditions minus Conan — reproduces both of Qt's errors
verbatim:

```
CMAKE_LIBRARY_ARCHITECTURE=''            (unset)
OpenGL_FOUND=FALSE
OPENGL_opengl_LIBRARY=OPENGL_opengl_LIBRARY-NOTFOUND
OPENGL_glx_LIBRARY=OPENGL_glx_LIBRARY-NOTFOUND
EGL_LIBRARY=PROBE_EGL_LIBRARY-NOTFOUND
```

Adding the one variable turns all four into real paths under
`/usr/lib/x86_64-linux-gnu`. Note that `find_path` was **never** the
problem — `EGL/egl.h` and `GL/gl.h` resolve to `/usr/include` in both
cases. It is `find_library` alone that depends on
`CMAKE_LIBRARY_ARCHITECTURE`, which is worth knowing because it means
the symptom class to watch for is always "header found, library not".

**2. Detection succeeding is not the same as linking succeeding — so
that was checked too.** Qt's three relevant feature tests
(`configure.cmake`'s `egl`, `opengl`, `glx` compile tests, transcribed)
all return 1, and a real executable linking `OpenGL::OpenGL`,
`OpenGL::GLX`, `OpenGL::EGL` and `X11::X11` builds. `onebin audit
--profile hybrid --glibc-max 2.27` on it: `needed: libEGL.so.1
libGLX.so.0 libOpenGL.so.0 libX11.so.6 libc.so.6`, `requires
GLIBC_2.2.5`, **0 errors, PASS Level 1** (warnings are the usual
`OB0060` build paths from an ad-hoc cmake call with no
`-ffile-prefix-map`). So the host-contract GL/EGL/X11 layer is sound
end to end under this toolchain, not merely discoverable.

**3. The far2l `TTYX` failure class cannot recur under the wrappers.**
This was the real worry: `TTYX` broke because far2l's CMake calls plain
`include_directories(${X11_INCLUDE_DIR})`, giving `/usr/include` `-I`
(high) priority and displacing zig's bundled libc++ headers; Qt's build
does the same kind of thing in several places. Tested directly rather
than assumed, and the answer is that the `-idirafter /usr/include` the
wrappers already add (for xkbcommon, for an unrelated reason) **also
fixes this class structurally**. `zig c++ -I/usr/include` on a file
including `<cerrno>`/`<string>`/`<filesystem>` fails with the exact
libc++ "didn't find libc++'s `<errno.h>` header" error; the same
compile through `zig-c++` succeeds, and `-E -v` shows why:
`/usr/include` ends up **last** in the search list, below all of zig's
`libcxx`/`libc` directories, because marking a directory as a system
directory moves it out of the `-I` list entirely no matter which flag
put it there first.

Also checked, because it is a plausible latent regression: the
`-isystem /usr/include` that `onebin-linux-hybrid.cmake` carries for
far2l's sake does **not** conflict with the wrapper's `-idirafter`.
Both spellings, together or separately, produce the identical search
order with `/usr/include` at the bottom. Neither needs removing.

**4. Host libraries do not shadow Conan's vendored ones.** The
`CMAKE_LIBRARY_ARCHITECTURE` commit message flagged this as "worth
watching if one ever resolves to a host copy". With the variable set
and a prefix containing a `libz.so`/`zlib.h` on `CMAKE_PREFIX_PATH`,
`find_library(z)` and `find_path(zlib.h)` both resolve to the prefix,
not to `/usr/lib/x86_64-linux-gnu`. CMake searches `CMAKE_PREFIX_PATH`
ahead of system paths and the fix does not change that ordering. The
concern is closed, not merely unobserved.

`make test`: 272 passed, 0 failed, 3 skipped — unchanged, as expected
for a session that changed no code.

<!-- ------------------------------------------------------------------ -->

## f4-qt CI diagnostics: rebuilt around Conan's own "Build folder" line instead of filename guessing — small artifact, nothing missed

Three rounds of filename-allowlist patching (`LastTest.log`, then
`meson-log.txt`, then a broadened `*.log`/`*.yaml`/`*ninja_log*` glob
that **still** didn't match `meson-log.txt` because it ends in `.txt`)
was the wrong shape of solution, and each round cost a real ~20-minute
CI cycle to discover. Adding `*.txt` would have been worse still: build
folders are full of unrelated `README.txt`/`LICENSE.txt` from ~35
packages, and the person running this is on a mobile connection and
explicitly can't download everything.

Redesigned around a fact that was in every failure log all along and
went unused: **Conan names the failing package's build folder
verbatim** — `xkbcommon/1.5.0: WARN: Build folder /home/runner/.conan2/
p/b/xkbco.../b/build-release`. So there is no need to guess *which*
package broke or *what* its build system calls its logs.

The collector now does four things, none of which involve guessing a
filename:

1. **Listings** (`00-listing-*.txt`): every file with its size, object
   files excluded. Paths only, no content — cheap, and structurally
   incapable of missing an unfamiliar build system's log. Anything not
   collected is still *visible* here with its size, so it can be asked
   for specifically next time instead of discovered missing.
2. **Failing-folder detection** (`01-failing-build-folders.txt`): parsed
   from Conan's own `Build folder` line, with a most-recently-touched
   fallback if a failure happens outside Conan entirely.
3. **Content from those folders only** (`02-…`), selected by **actual
   content type** (`file --mime-type` → `text/*`, JSON, XML), not by
   filename or extension, capped at 2M per file, with objects/archives/
   shared libraries excluded. `meson-log.txt`, `config.log`,
   `CMakeError.log`, `CMakeConfigureLog.yaml`, `.ninja_log`,
   `build.ninja`, `meson-info.json` and any future build system's log
   all qualify automatically. Scoping to the one failing package is what
   keeps the artifact small.
4. **Build output, trimmed** (`03-…tail`, `04-…errors`): the build step
   now `tee`s to a file (with `set -o pipefail` so the pipe can't mask a
   failure), and the collector ships the last 3000 lines plus grepped
   error lines — which also removes the need to hand-copy terminal
   output out of the GitHub UI.

Verified end to end against a realistic simulation before committing,
not reasoned about: a fake `xkbcommon` build folder with
`meson-logs/meson-log.txt`, `meson-info.json`, `.ninja_log`,
`build.ninja`, a 300K `.o`, a 200K `.a`, a 3M oversized `.log`, plus an
*unrelated* second package, and a transcript in Conan's real failure
format. Result: the failing folder was detected automatically; all four
genuine text artifacts were collected **including `meson-log.txt` and
`build.ninja`, neither of which any extension glob would have matched**;
the object file, archive, oversized log, unrelated package's log and
unrelated `.c` were all correctly excluded from content while remaining
visible in the listing; total artifact size 48K.

Not yet re-run against real CI — the next concrete step.

## f4-qt CI diagnostics: stopped guessing individual log filenames one at a time — full file listing + broad extension-based capture

Real, fair complaint: after the `LastTest.log` miss and then the
`meson-log.txt` miss (both fixed by adding one more exact name to the
list — each round cost a real ~20-minute CI cycle to even discover
which name was missing), a hardcoded allowlist of exact filenames was
never going to keep up with every build system this project's ~35
packages happen to use (Autotools, CMake in at least two log-format
generations, Meson, Ninja, whatever comes next).

Replaced the whole approach instead of adding a fifth name to the
list. Two changes, both unconditional now (not gated on guessing
right):

1. **A full recursive file listing**, captured first and always
   (`conan-cache-file-listing.txt` / `f4-src-file-listing.txt`) — just
   paths, no content, cheap. This is the direct fix for the actual
   complaint: stop guessing which exact name a given build system uses
   and just show what's genuinely there. The next unfamiliar build
   system's log, whatever it's called, is now visible on the first try
   instead of requiring another CI round to even learn its name.

2. **Content capture broadened from an exact-name allowlist to
   extension/naming-convention matching**: `*.log`, `*.yaml` (CMake's
   newer `CMakeConfigureLog.yaml`, which coexists with or replaces the
   older `CMakeError.log`/`CMakeOutput.log` pair depending on CMake
   version), and `*ninja_log*` (Ninja's own `.ninja_log`, which doesn't
   follow the `.log`-suffix convention at all). This one change
   subsumes `config.log`, `CMakeError.log`, `CMakeOutput.log`,
   `LastTest.log`, and `meson-log.txt` all at once — none of them need
   to be named individually anymore, since they all end in `.log`.
   Size-capped at 5M per file so one pathological log can't silently
   balloon the artifact.

Tested locally before committing, not just written and hoped: built a
realistic multi-package tree (Meson's `meson-logs/meson-log.txt`,
CMake's `CMakeError.log` + `CMakeConfigureLog.yaml`, Ninja's
`.ninja_log`, an unrelated `README.md`, and one deliberately
stale/pre-marker file) and ran the actual updated commands against it.
Confirmed: the listing shows every file including the non-log
`README.md`; the content copy correctly grabs the three genuine logs;
the stale file is correctly excluded by the mtime filter; the
unrelated `README.md` is correctly excluded from content copying
(visible in the listing, not duplicated as content).

Also worth naming honestly: this project's own sandbox git remote had
gone stale mid-session (an earlier `git fetch` in this same turn showed
`origin/main` one commit behind the real GitHub state, because the
`meson-log.txt` fix from the previous entry — applied and pushed by the
person building this — had already landed under a different commit hash
than the local sandbox commit that produced the patch file). Caught via
a failed `git am` on a genuinely fresh clone, not silently — re-fetched
properly and rebuilt this change against the real current state rather
than assuming the earlier local commit was still authoritative.

Not yet re-run against real CI — the next concrete step.

## f4-qt CI: diagnostic-log collection was missing `meson-log.txt` -- xkbcommon's own failure had zero evidence collected for it, found by checking the actual zip

The reordering from the previous entry worked exactly as intended:
diagnostic logs arrived quickly this time, before the slow cache save.
But checking the actual collected zip for anything explaining
`xkbcommon`'s `xcb/xkb.h` failure turned up nothing at all — only
`config.log` files from unrelated autotools packages (`icu`, `libffi`,
`libiconv`, `m4`, `xz_utils`). Real, concrete reason, not a mystery:
`xkbcommon` builds via **Meson**, not CMake or Autotools like every
other package this collection mechanism was built around, and Meson
writes its own log to `meson-logs/meson-log.txt` inside the build
folder — a filename this project's `find` patterns never searched for
at all, in either the Conan-cache location or the `f4-src` location.

Added `meson-log.txt` to both `find` patterns. Tested against a
realistic directory layout before committing, not just written and
hoped: created a fake `<build>/meson-logs/meson-log.txt` under a
`~/.conan2/p/b/...` path with a timestamp after the job-start marker,
ran the actual updated `find`/`cp` command, confirmed it gets collected
correctly.

This doesn't fix `xkbcommon` itself — it fixes the *ability to see why*
it's failing, which is what was actually missing. The next CI run
should finally have the real Meson-side detail (likely showing exactly
what `PKG_CONFIG_PATH`/environment Meson's own pkg-config dependency
lookup saw) needed to fix the actual `xcb/xkb.h` problem correctly,
rather than guessing at environment-propagation theories a third time.

Not yet re-run against real CI — the next concrete step.

## f4-qt CI: reordered diagnostic-log collection/upload to run *before* the slow cache save; `PKG_CONFIG_PATH` fix confirmed NOT to have solved xkbcommon's `xcb/xkb.h`

**Real CI run confirms the `${PKG_CONFIG_PATH:-}` syntax fix itself
works correctly** (no more "parameter not set" script crash) — but the
underlying `xkbcommon` failure is unchanged: `xcb/xkb.h: file not
found`, identical to before. The `PKG_CONFIG_PATH` prefix genuinely
didn't fix the real problem. Worth noting for whoever picks this up
next: `xkbcommon` builds via Meson, not CMake/Autotools like every
other package fixed so far in this build — Meson has its own way of
constructing subprocess environments for its own internal pkg-config
invocations, which may not inherit an env var set on the outer `conan
install` process the same way CMake/Autotools-driven builds do. Not
chasing this further yet without more direct evidence (a real
`meson-log.txt` or similar from inside xkbcommon's own build folder
would help) — not guessing a third time blind.

**Real, sensible workflow reordering, raised directly in conversation**:
diagnostic-log collection and upload used to run *after* the Conan/
ccache cache save, which routinely takes 7-20+ minutes (the cache only
grows across runs, nothing prunes it) — meaning the actually
time-critical artifact (needed immediately to diagnose what broke) was
stuck waiting behind an operation that's purely about making the *next*
run faster. Nothing in either direction depends on the other's
ordering. Reordered so diagnostic collection/upload now run
immediately after the build step (right after the quick `ccache stats`
check), with the cache save moved after them. Verified this is a pure
reorder, not guessed: diffed the workflow file's own sorted line
content before and after the change — byte-for-byte identical, only
the step sequence changed.

Not yet re-run against real CI — the next concrete step.

## f4-qt: PKG_CONFIG_PATH fix broke the script itself under `set -eu` -- real CI run caught it, fixed and tested properly this time

The previous entry's `PKG_CONFIG_PATH` fix had a genuine bug, caught
immediately on the very next real CI run: `./tools/build-f4-qt.sh: 1:
eval: PKG_CONFIG_PATH: parameter not set`. `build-f4-qt.sh` runs under
`set -eu` (line 5) -- referencing `$PKG_CONFIG_PATH` bare fails hard
under `set -u`'s nounset behavior when the variable has never been set
at all (not just empty), which is the normal state on a fresh GitHub
Actions runner. Should have been caught before committing; wasn't.

Fixed with `${PKG_CONFIG_PATH:-}` instead of the bare `$PKG_CONFIG_PATH`
-- the standard, correct way to safely reference a potentially-unset
variable under `set -u`, defaulting to empty rather than erroring.
Tested properly this time, not just assumed correct: extracted the real
generated command from `--print-plan` and actually executed it under
`set -eu` in two scenarios -- `PKG_CONFIG_PATH` genuinely unset (the
real CI case that broke), and already set to something (confirming the
fix still appends correctly rather than only working in the broken
case's absence). Both passed. Also scanned the rest of the script for
any other bare reference to an external (not script-defined) environment
variable that could share the same risk -- found none: every other
`${VAR}`/`$VAR` in the script is either a POSIX-guaranteed builtin
(`$PWD`) or a variable the script itself always assigns before use
(`SRC`, `OUT`, `REPO_ROOT`, `DEPS_LOCK`, etc.) -- `PATH`/
`PKG_CONFIG_PATH` were the only references to variables that come from
outside the script's own control, and `PATH` is POSIX-guaranteed
present unlike the optional `PKG_CONFIG_PATH`.

Not yet re-run against real CI — the next concrete step.

## f4-qt: real CI progress confirms glib/harfbuzz/elfutils fixes worked; two new items caught -- cache-save timeout gap, new xkbcommon failure

**The `harfbuzz`/`glib`/`elfutils` fixes are confirmed working**: a real
CI run got all the way past that entire chain of issues without a
single recurrence, reaching a completely new, unrelated failure
(`xkbcommon`). The whole `crc32`/`__libelf_crc32`/`elfutils` saga from
the last several entries is now moot.

**A real gap the user caught directly, not from a log but from watching
the run live**: the "Save Conan downloads and ccache storage" step was
still visibly running 7+ minutes in — roughly a third of the whole
job's typical wall-clock cost — with no way to tell whether it was
genuinely hung or just slow on a cache that only ever grows (nothing
prunes it across runs). This is exactly the kind of gap this project's
own two prior "audit everything" passes were supposed to catch and
didn't. Added `timeout-minutes: 20` to that step specifically — not
tighter (e.g. 10), since killing a save that would have genuinely
finished in 8-9 minutes would recreate the exact "lost all progress"
disaster this project already fixed once elsewhere.

**New failure, unrelated to anything already fixed**: `xkbcommon`'s X11
variant fails with `xcb/xkb.h: No such file or directory`. Checked
directly rather than guessed: `libxcb-xkb-dev` (which genuinely does
provide this exact header on Debian/Ubuntu, confirmed via `dpkg-query
-L`) is already in this workflow's own apt-get install list, and the
`xorg/system` Conan package's own recipe source independently confirms
the same package name is correct. Plain `pkg-config --exists xcb-xkb`
also succeeds cleanly against a real installed `libxcb-xkb-dev` --
package and `.pc` file both genuinely present and correctly registered.
The likely remaining gap, not yet confirmed against a live CI run:
whatever `PKG_CONFIG_PATH` Conan's own generators construct for this
package's build may not include the system's default pkgconfig
directories, a common pattern for Conan-managed builds that curate an
explicit path to avoid picking up wrong-version system libraries.
Prepended the standard Debian/Ubuntu multiarch pkgconfig locations to
the main `conan install` invocation's environment, additively
(preserving whatever Conan's own value already is).

Not yet re-run against real CI — the next concrete step.

## f4-qt: found the real, well-evidenced answer for "who needs glib" while waiting on upstream — `harfbuzz`'s own `with_glib=True` default

Traced this properly instead of waiting idle for the upstream reply.
Cloned the actual pinned `f4` commit and grepped every CMakeLists.txt
directly: zero references to `glib` or `harfbuzz` anywhere in the
project's own code — it only requests Qt6's `Core Gui Qml Quick
QuickControls2 Network Svg` components. So `glib` is unambiguously
transitive, coming from somewhere inside Qt's own dependency graph, not
from f4-qt itself.

Found the real answer, not another guess: multiple independent real
users' Conan dependency-graph dumps (`conan-center-index` issues #9794,
#19632, #20383, #27705 -- all unrelated projects, unrelated to this
one) consistently show `glib` appearing in *every* Qt build's graph
specifically alongside `harfbuzz`. ConanCenter's own published
`harfbuzz` recipe page confirms why: **`with_glib=True` is harfbuzz's
own default**, on every platform. `harfbuzz` itself is unavoidable --
Qt's `Gui` module needs it for text shaping, no way around that -- but
harfbuzz's glib integration (`hb-glib.h`, GLib-type conversion helpers)
is a convenience layer for GLib-based *callers* of harfbuzz, not
something Qt's own direct C-API usage of harfbuzz depends on.

Added `harfbuzz/*:with_glib=False` alongside (not instead of) the
existing `glib/*:with_elf=False` and the `crc32` hook -- this is a
well-evidenced, likely-complete answer, but not verified against a live
`conan graph info` resolution (not available in this sandbox), so kept
as defense in depth rather than assumed sufficient to remove the other
fixes. If this genuinely eliminates `glib` from the graph, the
`elfutils`/`crc32`/`__libelf_crc32` chase from the last few entries
becomes moot entirely -- the next real CI run will show which.

Still waiting on the upstream maintainer's own answer to the same
question; this doesn't replace that, just gets there faster if the
evidence checks out.

Not yet re-run against real CI — the next concrete step.

## f4-qt: session paused, waiting on an upstream question — `glib/*:with_elf=False` applied, whether `glib` is needed at all is open

The `elfutils`/`crc32` hook (previous entries) is confirmed working end
to end: the diagnostic log shows `[HOOK - hook_elfutils_crc32.py]
post_source(): ... patched elfutils lib/crc32.c` firing for real, and
the build progressed past the original `duplicate symbol: crc32` error
to a *different*, related one: `ld.lld: error: undefined hidden symbol:
__libelf_crc32`. Traced directly against elfutils' real source
(`libelf/libelf_crc32.c:32`: `#define crc32 attribute_hidden
__libelf_crc32`) -- the blunt `static` patch broke an internal alias
elfutils' own code depends on elsewhere. Not yet fixed; this is where
the crc32 chase currently stands.

**A better question got asked instead of continuing that chase**: does
f4-qt, a Qt file-manager GUI, need an ELF/DWARF-parsing toolkit at all?
Traced precisely, not guessed: `glib`'s own recipe source confirms
`elfutils` is pulled in only for the `gresource` CLI tool (`if
self.options.get_safe("with_elf"): ...requires.append(
"elfutils::libelf")`), a GNOME/GTK resource-embedding convention
f4-qt's own Qt code has no reason to touch. Applied
`glib/*:with_elf=False` -- same pattern already proven for `with_mount`
(the earlier `libmount`/zig-header collision).

**Went one step further and found something genuinely worth asking
upstream about**: Qt's own actual recipe source
(`recipes/qt/6.x.x/conanfile.py`) shows `"with_glib": False` as Qt's
own *default*, and `glib` is only ever required when that option is
explicitly turned on (`if self.options.with_glib: self.requires(
"glib/2.78.3")`). This project's own build command never sets
`qt/*:with_glib=True` anywhere -- checked directly, not assumed. Yet
`glib` is force-built from source by *upstream f4's own official*
`ci/build-portable-qt-linux.sh` too (confirmed identical to this
project's own `--build` list in an earlier, already-committed
cross-check). Something in the graph still needs `glib` for a reason
not yet traced -- possibly a real Qt submodule dependency, possibly a
vestigial force-build entry that never actually triggers. Not resolved
with the tools available here (would need a live `conan graph info`
resolution against the real graph to trace definitively).

**The person building this asked f4's own upstream maintainer directly
why this Qt build needs glib at all.** Session paused here to wait for
that answer rather than keep guessing at the dependency graph blind.
`with_elf=False` stays applied regardless of the answer -- harmless
either way (a no-op if glib turns out unnecessary, still useful if it
stays for some other reason). The `crc32`/`__libelf_crc32` alias
breakage is the next concrete technical item once the session resumes,
unless the glib answer removes the need to chase it at all.

Not yet re-run against real CI since the `crc32` alias breakage was
found -- the next concrete step once this resumes, informed by
whatever the upstream maintainer says about `glib`.

## f4-qt: `elfutils` crc32 hook root cause finally found — cached source from earlier CI attempts means `source()` never re-runs, so `post_source` never fires

The diagnostics fixed two entries ago (`-vv` verbosity specifically)
paid off decisively this time: the full CI log clearly shows
`static-everywhere hook: hook_elfutils_crc32.py module loaded` firing
three separate times — confirming Conan genuinely finds and imports the
hook file — but **no** `post_source() entered for ...` message appears
anywhere after that, for `elfutils` or any other package. Not a
condition bug, not a scoping issue: `post_source` itself is never
invoked at all, for anything.

Real, well-grounded diagnosis: this project's own `actions/cache`
mechanism restores `~/.conan2/p` from earlier CI attempts — including
`elfutils`' already-fetched source, cached from *before* this hook ever
existed. Conan correctly treats an already-present source folder as not
needing `source()` re-invoked, and `post_source` only fires as part of
that method running. The hook was never broken; the source it needed to
patch had already been fetched and cached long before the hook was
written, and nothing was forcing Conan to fetch it again.

Fixed by forcing exactly that: `conan remove 'elfutils/*' -c` right
before the main install, scoped to `elfutils` only so the other ~34
packages' cached build progress stays untouched. Checked, not assumed,
that `conan remove` on a pattern that matches nothing is a real error in
Conan 2.x (confirmed via an open upstream GitHub issue asking for
exactly a "skip silently if missing" flag, which doesn't exist yet) --
`|| true` here is handling a genuinely expected case (first run, nothing
cached yet), not masking a real failure.

Not yet re-run against real CI — the next concrete step.

## f4-qt CI diagnostics: second, deeper audit pass — five more real gaps found and fixed, one false alarm ruled out

Five gaps found and fixed in one pass, on a pipeline this size, was
itself the signal that the first audit was too shallow — reactive
enough to catch what had already broken, not systematic enough to
catch what hadn't yet. Redid it properly: for every command in
`tools/build-f4-qt.sh`'s zig path and `f4-qt-zig-build.yml`, asked "how
could this fail or hang, and would we actually see why" rather than
re-reading the same text with the same mental model.

**Real, systemic gap: `if: failure()` does not fire on a cancelled
job.** Confirmed via a GitHub staff-answered community thread, not
assumed: a step condition of `failure()` alone does not run when the
job is cancelled (including by hitting `timeout-minutes`) — only
`cancelled()` catches that case. This is a genuinely serious blind
spot for a ~35-package from-scratch build with a 300-minute ceiling:
anything that hung rather than erroring cleanly would previously have
produced *zero* diagnostics, precisely when the wall-clock cost of
finding out is highest. Changed both diagnostic steps to
`if: failure() || cancelled()`.

**Two concrete hang risks, previously unbounded.** The smoke-test
invocation (both the `--toolchain host` and `--toolchain zig` copies)
had no timeout at all — if `f4-qt-host` hung instead of exiting cleanly
with code 2, this would silently consume the *entire* remaining job
budget with nothing to show for it, compounded by the above gap.
Wrapped both with `timeout --kill-after=30s 120s` — verified locally
that `timeout` preserves the wrapped command's real exit code when it
finishes normally, and only substitutes its own distinct code (124)
when it actually has to kill something, so the existing
`|| [ $? -eq 2 ]` check still behaves correctly either way. Also added
`ctest --timeout 300` (a hanging individual test was the same
unbounded risk, just for `ctest` instead of the smoke test).

**Disk/memory exhaustion was invisible.** A parallel, Qt-scale build
compiling many packages at `-j$(nproc)` is a real, plausible candidate
for exhausting a GitHub-hosted runner's disk or RAM — which manifests
as a process silently vanishing (SIGKILL), no compiler error text at
all, a fundamentally different and harder failure shape than anything
config.log/CMakeError.log capture already covers. Added `df -h`,
`free -h`, and a kernel OOM-kill trace check to the diagnostic
collection. Caught and fixed a subtler bug in the OOM check itself
while writing it: `dmesg` typically needs root on Ubuntu
(`kernel.dmesg_restrict`), and piping it straight into `grep` would
make a permission failure indistinguishable from "checked, found
nothing" (the pipe's exit status comes from `grep`, not `dmesg`) — a
false negative masquerading as a clean check. Fixed with `sudo dmesg`
captured to a file first, checked explicitly, with the two outcomes
(couldn't read vs. read-and-clean) kept visibly distinct. Tested both
paths locally before committing.

**Cross-checked, not just re-read: the `--build='pkg/*'` package
list.** Real-cloned the exact pinned upstream `f4` commit again and
diffed its actual `target_packages` array against this project's own
list programmatically (not by eye) — exact match, `m4` accounted for
correctly on both sides just via a different structural placement.
Ruled out as a real risk rather than silently left unchecked.

Not yet re-run against real CI — the next concrete step.

## f4-qt: `elfutils` crc32 hook was created but never fired — added diagnostics instead of guessing at a second mechanism blind

The `post_source` hook from the previous entry did get created (visible
in the CI log — the file-write command itself echoed its own content,
as expected), but **never actually fired**: none of the hook's own
diagnostic messages (`"static-everywhere hook: patched elfutils..."`,
or either warning variant) appeared anywhere in the real CI log, and the
`crc32` duplicate-symbol error was completely unchanged from before the
hook existed. Checked Conan's own docs specifically for whether hooks
in `<conan_home>/extensions/hooks/` need an explicit activation step
(some Conan 1.x versions required one): confirmed, repeatedly, across
several doc versions, that "activation... is done automatically once
the hook file is stored in the hook folder" — no separate registration
should be needed, which is what this project's mechanism already
assumed.

Given placement and naming both match documented conventions, and the
sandbox test of the file-creation mechanism itself (extracting and
actually running `--print-plan`'s exact hook-writing command, then
importing the resulting module and calling `post_source` directly)
worked flawlessly — the uncertainty is now squarely about *why Conan
itself* isn't invoking this hook in the real CI environment, not about
anything this project's own script does wrong in producing the file.
Rather than guess at a second, different hook mechanism blind (another
full CI cycle to find out it's also wrong), added real diagnostics to
the *existing* mechanism first: a module-level `print()` that fires the
instant Conan loads this file at all (regardless of whether
`post_source` is ever called for anything), and an unconditional
`print()` inside `post_source` itself for *every* package it's called
for (not just `elfutils`) — together these will tell apart "Conan never
loads hook files from this location at all" from "it loads fine but
this specific condition or Conan-version behavior has a real bug" on
the next run, rather than guessing a second mechanism blind. Tested
end-to-end in the sandbox again before committing: extracted and ran
the real hook-creation command, then genuinely imported the resulting
module and called `post_source()` against a fake package, confirming
both diagnostic prints appear and the patch itself still applies
correctly.

Not yet re-run against real CI — the next concrete step, and this time
should finally reveal *why* the hook isn't firing, not just that it
isn't.

## f4-qt: `-z muldefs` also rejected by zig cc — stopped guessing at flag spellings, fixed the elfutils/crc32 collision at the actual root instead

Third failed attempt at telling the linker to tolerate the `crc32`
collision: `-Wl,-z,muldefs` — the fix from the previous entry, chosen
specifically because other `-z` flags already worked throughout this
build — got a real CI run this time, and `zig cc` rejected it too, with
a more specific message than the earlier ones: `error: unsupported
linker extension flag: -z muldefs`. Read literally, this means `zig
cc`'s driver does parse the `-z <value>` *form* (that's why `-z relro`/
`-z now`/`-z noexecstack` work), but validates the *value* against its
own separate, narrower allowlist — `muldefs` isn't on it either, even
though the flag mechanism itself is recognized.

Three flag-spelling attempts in a row rejected by `zig cc`'s own driver
(`-rpath-link`, `--allow-multiple-definition`, `-z muldefs`), each
discovered only after a full ~15-20 minute CI cycle. Stopped guessing at
a fourth spelling and fixed the actual root cause instead, which was
already identified precisely two entries ago: `elfutils`' own `lib/
crc32.c` has no `static`/hidden-visibility marker on its `crc32`
function, which is what causes the collision with zlib's own public
`crc32()` in the first place. Implemented via a Conan `post_source`
hook (`conan.io/2.0/reference/extensions/hooks.html`) — a small Python
file at `~/.conan2/extensions/hooks/hook_elfutils_crc32.py`, created by
`quickstart-f4-qt.sh`/`build-f4-qt.sh` itself before invoking `conan
install`, which patches `lib/crc32.c` to add `static` right after
Conan fetches `elfutils`' source, before `build()` runs. This is the
correct, upstream-shaped fix (the function was never meant to be
externally visible) and works regardless of which specific linker
flags `zig cc`'s driver happens to recognize — sidesteps the whole
guessing game rather than trying a fourth spelling blind.

Tested thoroughly before committing, not just written and hoped:
extracted the exact hook-creation command `--print-plan` produces and
actually executed it (not just printed it) to catch any heredoc/
escaping issues before spending another CI cycle; validated the
resulting Python file's syntax with `ast.parse`; ran the patch's exact
string-replace logic against `elfutils`' real, current `lib/crc32.c`
(cloned directly from upstream) and confirmed it successfully adds
`static` to the real function; compiled a minimal reproduction of the
patched signature to confirm `static` on its own introduces no syntax
issue (unrelated compile errors surfaced when compiling the real file
standalone, from missing build-generated `config.h` and other
pre-existing declarations in `system.h` entirely unrelated to `crc32`
— not something this patch caused, confirmed by isolating just the
signature change in a clean minimal file that compiled and ran fine).

Not yet re-run against real CI — the next concrete step. If this
mechanism proves reliable, it's also the template for any future
"actually need to patch a third-party package's source" situation this
project runs into, rather than something built ad hoc each time.

## f4-qt: `--allow-multiple-definition` was itself an unsupported zig cc flag (another known, filed zig bug) — switched to `-z muldefs`

The `crc32` duplicate-symbol fix from the previous entry got past the
actual `crc32` conflict — confirmed by the CI run regressing to an
*earlier* failure point (`checking whether the C compiler works... no`,
the same class as the very first `elfutils` attempt), meaning the
package-scoped conf really did apply broadly to this package's LDFLAGS
(reaching even the early compiler-works probe, not just the final `.so`
link) — but the flag itself, `-Wl,--allow-multiple-definition`, turned
out to be its own separate `zig cc` limitation: `error: unsupported
linker arg: --allow-multiple-definition`. Checked, not guessed: this is
[ziglang/zig#21455](https://github.com/ziglang/zig/issues/21455), an
already-filed, still-open issue matching this exact flag — same class
of bug as the earlier `-rpath-link` case (`zig cc`'s driver only
recognizes a hardcoded allowlist of `-Wl,` flags, `ld.lld` itself
supports plenty more than that allowlist covers).

Switched to `-Wl,-z,muldefs` — same semantic effect (GNU ld/lld both
treat it as an alias for allowing multiple definitions), but parsed
through `lld`'s generic `-z <value>` handling rather than as its own
dedicated long-option flag. Reasonably confident this specific spelling
will work, not a blind guess: this project's own toolchain already
successfully passes other `-z`-prefixed flags (`-z relro`, `-z now`,
`-z noexecstack`) through `zig cc` in *every single package* built so
far in this whole build — confirming `-z`-prefixed flags generally are
on `zig`'s allowlist even where a specific long-option equivalent isn't.
Not verified against a live `zig` invocation (none available in this
sandbox) — honestly flagged as such in the code comment too, not
overstated as proven.

Not yet re-run against real CI — the next concrete step.

## f4-qt: `-pie`/`-shared` wrapper fix confirmed working (got past both openssl AND elfutils' earlier failure) — new, unrelated, real elfutils/zlib upstream bug found next

Real CI progress, confirming the previous fix genuinely worked this
time: `elfutils` got past its `__thread`-support probe entirely (no
`-pie`/`-shared` conflict at all this run) and progressed all the way
into its actual `make` build, compiling most of `libelf` — a
significantly later failure point than any previous attempt.

New failure, unrelated to anything toolchain-specific: `ld.lld: error:
duplicate symbol: crc32`, linking `libelf.so` — `elfutils`' own internal
`lib/crc32.c` and `zlib`'s own public `crc32()` both define a symbol
named `crc32`, and combining both into the same shared object once
everything is statically archived surfaces a genuine collision.
**Verified this is a real upstream elfutils issue, not a guess**:
cloned `elfutils` directly and checked `lib/crc32.c`'s actual function
definition — `uint32_t crc32(uint32_t crc, unsigned char *buf, size_t
len)`, no `static`, no hidden-visibility attribute, nothing to prevent
it from being an ordinary externally-visible symbol. With `zlib` linked
*dynamically* (the common case upstream would have tested against),
only one `crc32` ever gets resolved at runtime, so this never had reason
to surface before — it's specifically a fully-static combination that
exposes it.

Fixed with a package-scoped `elfutils*:tools.build:sharedlinkflags`
addition of `-Wl,--allow-multiple-definition`. Unlike the `-pie`/
`-shared` case, this stays package-scoped rather than becoming an
unconditional wrapper-level rule: blanket-allowing multiple definitions
project-wide would risk silently masking a genuine bug in some other
package later, where the `-pie`/`-shared` combination is never
meaningful for *any* package regardless. This particular failure is a
real build-time link step (not an early configure-time probe like the
`__thread` case), the same stage where the earlier `openssl` package-
scoped fix already proved reliable — expecting this one to hold too.
Both `crc32` implementations are the same standard algorithm, so which
one the linker keeps is behaviorally irrelevant here.

Not yet re-run against real CI — the next concrete step.

## f4-qt: previous `elfutils` fix confirmed NOT to have worked (via real `config.log` from the exact commit that supposedly fixed it) — replaced with an unconditional wrapper-level fix

The user caught a real mistake in the previous entry's own diagnosis. A
new CI run's diagnostic log looked byte-identical (including the
runner's hostname) to the prior failure, and I concluded it must be
stale/cached data from before the `elfutils*:tools.build:exelinkflags`
fix — but the run's own summary page showed it was triggered against
the exact commit containing that fix (`6b6bf8c`). The "identical
hostname" reasoning was wrong (GitHub Actions can reuse a warm runner
across close-together manual triggers of the same workflow) — the
config.log being identical meant something more direct: **the
package-scoped conf override genuinely did not take effect**, confirmed
by re-reading that exact config.log's compile line: `-pie` is still
present alongside `-shared`, unchanged.

Root cause of the override not working, best understanding without
digging further into Conan internals: OpenSSL's own Configure/Makefile
system and elfutils' plain GNU autotools apparently pull LDFLAGS from
Conan's generated files at different points/mechanisms, and a
package-scoped `tools.build:exelinkflags` conf reliably reaches one but
not the other (openssl's own final `.so` link picked it up; elfutils'
early `configure`-time `__thread`-support probe did not).

**Fixed properly instead of chasing the exact Conan mechanism further**:
moved the fix into `onebin/toolchain/zig-cc`/`zig-c++` themselves,
unconditionally — the same place that already reliably fixes the
`-rpath-link` issue. `-pie` and `-shared` are never simultaneously valid
for *any* package this project could ever build (not just inconvenient
here, not meaningful ELF at all), so both wrappers now drop `-pie`
whenever `-shared` is also present in the argument list, regardless of
which package is being compiled — no per-package Conan overrides needed
at all any more; removed the now-redundant `openssl*`/`elfutils*`
overrides from `tools/build-f4-qt.sh` entirely. Tested the filtering
logic directly against a reconstructed version of elfutils' own real
failing command line before committing — confirmed `-pie` is dropped,
`-shared` and everything else pass through unchanged.

Not yet re-run against real CI — the next concrete step.

## f4-qt CI: real progress confirmed, two things worth naming — cache-save race (benign) and `elfutils`' `-pie`/`-shared` conflict (same class as `openssl`, now fixed)

Next real CI run: got past `libmount`/`openssl` and 12 further packages
(pcre2, jasper, lcms, libtiff, freetype, libselinux, wayland, libraw,
...) before `elfutils` again — but at a *later* check than before,
confirming the `-rpath-link` fix from the previous entry actually
worked. `elfutils` now fails at `checking for __thread support`, not the
earlier `checking whether the C compiler works`.

**The "Cache save failed" warning shown in the run's Annotations panel
is not a repeat of the earlier "save never happens" bug** — checked the
full log specifically for this: `Run actions/cache/save@v4` did fire,
reached the actual `tar --posix -cf cache.tzst` archiving step, and
only then failed with `Unable to reserve cache with key ..., another
job may be creating this cache` — a real but benign race: two runs
sharing the identical cache key (built from `tools/build-f4-qt.sh`'s
hash, unchanged between these two attempts) tried to save
concurrently, and the loser gets this exact message. Almost certainly
from re-triggering the workflow before the previous run's save had
finished. Not fixing this specifically — adding `run_id` to the key
would eliminate the race but also eliminate the actual point of the
fix (letting a retry pick up a previous attempt's progress); the honest
answer here is "don't trigger two runs of this workflow at once,"
not a code change.

**`elfutils`'s new failure, from the real `config.log` this project's
diagnostic-log-on-failure step correctly collected**: the exact same
`-pie`/`-shared` conflict already diagnosed and fixed for `openssl`,
this time inside `elfutils`' own `configure` probe for `__thread`
support — the probe's own compile command has both `-shared` and this
project's global `exelinkflags`' `-pie` on the same invocation
("error: dynamic libraries cannot be position independent
executables"), confirmed directly in the collected log, not guessed.
Same fix applied, same reasoning: added `elfutils*:tools.build:
exelinkflags` dropping `-pie` for this package (matching the existing
`openssl*` override) — f4-qt only needs `elfutils`' library output
(`libdw`/`libelf`), not its `eu-*` CLI tools, so losing PIE hardening on
those specifically is an equally low-stakes trade.

Not yet re-run against real CI — the next concrete step.

## f4-qt `elfutils` build fixed: the diagnostic-log pipeline worked on the first real failure it was built for

The `config.log` capture added specifically for this class of failure
paid off immediately: got the real `elfutils` failure from the actual
`config.log`, not a guess. `zig cc`'s own compiler invocation is right
there in the log:

```
error: unsupported linker arg: -rpath-link
```

Conan's `AutotoolsDeps` generator adds one `-Wl,-rpath-link,<dep-lib-dir>`
per dependency (a linker hint for resolving *shared*-library dependencies
transitively) regardless of whether those dependencies are actually built
shared or static — this project only ever builds Profile H/S dependencies
statically, so the hint is meaningless here even when present, but `zig
cc`'s linker driver rejects it outright rather than silently accepting
and ignoring it as a no-op the way a full gcc/clang would.

Fixed in `onebin/toolchain/zig-cc` and `zig-c++` themselves — the same
wrapper scripts already filter one other Conan/Meson-generated flag
mismatch (the fontconfig `-E`/`-c` fix) — rather than fighting Conan's
generator. Filters every `-Wl,-rpath-link,*` argument (there's one per
dependency, confirmed four in elfutils' own failing command line: zlib,
bzip2, xz_utils, zstd) before exec'ing the real `zig cc`/`zig c++`.
Tested the filtering logic directly against a reconstructed version of
the real failing argument list before committing — confirmed both
`-Wl,-rpath-link,...` tokens get dropped and every other argument passes
through unchanged.

Also checked one other thing surfaced by the same diagnostic-log
collection, and it turned out to be a false alarm worth naming as such:
a `config.log` for `libmount` was also collected, which looked alarming
at a glance (that package should be excluded entirely via `glib/*:
with_mount=False`) — but its content is plain host `gcc` probing
(`-V`, `-qversion`, `minix/config.h`), the completely normal, *expected*
compiler-vendor-detection noise every autotools `configure` produces
(most of those probes are supposed to fail). Not zig-cc, not a build
failure, not related to this project's own toolchain at all — almost
certainly a native build-time helper tool compiled with the host's own
compiler as part of some other package's build. Not chased further.

Not yet re-run against real CI — the next concrete step.

## f4-qt CI: real progress to 49/55 packages, then a genuinely more serious problem found — the cache save was silently never happening

Real CI progress: got through 49 of 55 packages (past `openssl`, the fix
worked) before `elfutils` failed at the most basic possible check —
`configure: error: C compiler cannot create executables`, with zero
diagnostic detail in the terminal log (autotools hides this specific
check's real output, only writing it to `config.log`, which this
project's CI had never captured). `elfutils` is the one package in this
whole chain whose `configure` script gets *regenerated* via `autoreconf`
(with a patch applied to `configure.ac` first) rather than shipped
pre-built the way every other autotools package here is — a real,
concrete difference worth investigating once `config.log` is actually in
hand, not yet diagnosed further without it.

**A second, more serious problem found while getting that log**: asked
for the full job log rather than just the tail, and it showed something
worse than a missing `config.log` — **the Conan/ccache cache was never
actually saved for this run.** No `Post Run actions/cache@v4` appears
anywhere in the log after the build failed. This means all 49 packages
this run had already built, ICU included, were silently discarded —
the next attempt would have started completely from zero again, exactly
the kind of loss this project spent real effort avoiding earlier in the
sandbox. The combined `actions/cache@v4` action's implicit post-step
save apparently does not reliably fire on a failed job in this setup.

**Fixed properly, not patched around**: split the single `actions/
cache@v4` step into `actions/cache/restore@v4` (start of job) and an
explicit `actions/cache/save@v4` step with `if: always()` (end of job,
right after the build step) — the documented, reliable pattern for
guaranteeing a cache save regardless of how the job ends. Verified the
underlying idea works as intended for the *other* new addition too:
tested the exact `find -newer ... -exec cp` logic used to collect fresh
`config.log`/`CMakeError.log`/`CMakeOutput.log` files locally, with one
genuinely fresh file and one deliberately stale one (timestamped
"yesterday") — confirmed the stale file is correctly excluded so a
restored cache's untouched logs from unrelated earlier packages don't
drown out the one that actually matters from the failing run. Both new
steps (`Collect diagnostic logs on failure`, `Upload diagnostic logs on
failure`) only run `if: failure()`, uploaded as a separate artifact from
the normal build output.

Not yet re-run against real CI — the next concrete step, and this time
a failure should actually preserve both the build cache *and* a usable
`config.log` for whatever breaks next.

## f4-qt: LGPLv3 §4d resolved (README note, no new mechanism needed) + `openssl` `-pie`/`-shared` link conflict fixed

Two closed items from the same conversation, while the `libjpeg-turbo`
fix's CI run was in flight:

**Licensing.** Raised as a real concern: does statically linking Qt
(LGPLv3) into f4-qt (BSD-3) via `--toolchain zig` create an obligation
this project wasn't meeting? Checked properly rather than assumed: f4/
f4-qt is BSD-3 (confirmed), so the earlier OpenSSL/GPLv2 compatibility
question that mattered for far2l doesn't apply here at all — BSD-3 and
Apache-2.0 (OpenSSL ≥3.0) combine without any issue. Qt's own LGPLv3 §4d
*does* apply, though, specifically because this build asks for a
statically-linked Qt. Verified the exact license text (not memory): §4d
requires the means to relink against a modified Qt "in the manner
specified by section 6 of the GNU GPL for conveying Corresponding
Source" — and GPLv3 §6 explicitly permits conveying object code
alongside a *pointer* to source held elsewhere (a written offer, or
network access with equivalent access alongside), not physical bundling
into one archive or one server. This is the standard way virtually
every GPL/LGPL project on GitHub already satisfies this. This project
already has both required pieces: `quickstart-f4-qt.sh` *is* the relink
instructions, and this repo + the pinned `f4` commit *is* the
Corresponding Application Code + Qt's own public source. Added a README
section naming these two things as the compliance mechanism explicitly,
rather than building anything new (a `$ORIGIN`-relative dynamic-Qt
bundle was floated first and correctly rejected as solving a problem
that didn't need solving).

**`openssl` build fix.** The `-pie`/`-shared` link conflict from the
previous CI run (`error: dynamic libraries cannot be position
independent executables`) traced to OpenSSL's own Configure-generated
Makefile not respecting Conan's exe-vs-shared linker flag split the way
CMake-based packages do — it reuses one LDFLAGS for both the `openssl`
CLI executable and its provider `.so` modules, so the global
`exelinkflags`' own `-pie` collided with those `.so` links (confirmed
directly in the failing build's own command line — `-pie` and `-shared`
both present on the same invocation). Fixed with a package-scoped
override, `openssl*:tools.build:exelinkflags` matching `sharedlinkflags`
(drops `-pie`) for this package only. Cost: the standalone `openssl` CLI
tool inside this dependency loses PIE hardening — f4-qt only needs
`libssl.a`/`libcrypto.a` from this package, not that CLI tool, so this
is a low-stakes trade, not a compromise on anything the final binary
itself needs.

Not yet re-run against real CI — the next concrete step.

## f4-qt `--toolchain zig`: got past `libmount`, 32/55 packages including `libheif` fully — new failure `libjpeg-turbo`, `CMAKE_SIZEOF_VOID_P` empty

Real CI progress with the `glib/*:with_mount=False` fix applied: got
through package 32 of 55 (`libheif` built fully) before hitting a new,
different, and more foundational issue.

`libjpeg-turbo`'s `CMakeLists.txt:96` does
`math(EXPR ... "${CMAKE_SIZEOF_VOID_P} * 8")` to compute the target
bit-width. `CMAKE_SIZEOF_VOID_P` is normally populated by CMake's own
"Detecting C/CXX compiler ABI info" step, introspecting a small compiled
test binary — and that step has been silently *failing* with `zig-cc`
for every single package in this build so far ("Detecting C compiler ABI
info - failed", visible in every configure log throughout this whole
run) without consequence, because nothing else in the chain reads the
resulting variable. `libjpeg-turbo` is the first package that does, and
an empty value breaks the `math()` call outright
(`math cannot parse the expression: " * 8"`), which is also why the log
shows the bizarre "ERROR-bit build (i386)" — the whole bit-width/arch
selection logic downstream of that broken expression goes wrong too.

**Fixed the one thing we actually know for certain**: this build only
ever targets one architecture (x86_64), so forcing
`CMAKE_SIZEOF_VOID_P=8` globally (added to the same
`tools.cmake.cmaketoolchain:extra_variables` conf already used for
`ccache`) carries no risk of being wrong for some other configuration —
unlike the `statx` situation, there's no second case this could quietly
break. Not scoped to `libjpeg-turbo` specifically, since any later
package in the 55-package chain could plausibly hit the identical gap.

**Worth watching, not yet investigated**: *why* zig-cc's ABI detection
fails for CMake in the first place is still unknown — this fix
sidesteps the one concrete symptom it caused, not the underlying cause.
If a different package later depends on some *other* variable that same
broken detection step is supposed to populate, this same shape of
failure could recur under a different name. Not chasing that root cause
now, consistent with fixing what actually broke rather than the
class of thing that might break.

Recorded what's actually known about the mechanism, in case someone
picks this up later: CMake's ABI-detection step compiles a tiny probe
(`CMakeCCompilerABI.c`) containing a preprocessor-embedded marker string
(`"INFO:sizeof_dummy[XXXX]"`, `XXXX` = the real `sizeof(void*)`), then
**does not run the resulting binary** — it greps that marker directly out
of the compiled object file, which is what lets this work even when
cross-compiling. This is a different, later step than "Check for working
C compiler," which *does* pass. Three plausible, unconfirmed causes for
why the grep fails specifically with `zig-cc`: (1) `zig cc` is a Clang
wrapper known to occasionally emit its own diagnostic lines (about its
build cache, target resolution) ahead of normal compiler output, which
could throw off a parser written against vanilla GCC/Clang output; (2)
`zig cc` uses its own linker (`lld`) and CRT, so the marker string could
end up in a different ELF section layout than CMake's regex expects; (3)
unrelated to (1)/(2) — possibly a different symptom of the same class of
bug as `ziglang/zig#22765` (the header-versioning issue found earlier),
this time surfacing in the compile/link step of CMake's own probe rather
than in header content. Cheap next step if this needs a real answer
later: CMake writes the full failed-probe output to
`CMakeFiles/CMakeError.log` inside the build directory on this exact
failure path — ephemeral on a CI runner unless explicitly saved as an
artifact, not done here since the symptom is already fixed and this
isn't blocking anything right now.

## f4-qt `--toolchain zig`: found a real disable path instead of a patch — `glib/*:with_mount=False` removes `libmount` from the graph entirely

Better than either forcing risky macros or writing a source patch for
the zig/`statx` collision (previous entry): read `glib`'s actual
ConanCenter recipe source directly (`recipes/glib/all/conanfile.py`).
`glib` gates its own `libmount` dependency behind a `with_mount` option
— used only for `gio`'s Unix mount-point monitoring
(`GUnixMountMonitor`), a GNOME/GIO-specific feature f4-qt's own Qt-based
code never touches. Set `-o:h 'glib/*:with_mount=False'` in
`tools/build-f4-qt.sh`'s zig-toolchain Conan invocation — this removes
`libmount` from the dependency graph entirely, sidestepping
`ziglang/zig#22765` rather than fighting it. The confirmed-safe
`-DHAVE_CLOSE_RANGE=1` scoped fix from the previous entry is left in
place as harmless defense in depth, in case some other package in the
54-package graph still needs `libmount` for a different reason.

Not yet re-run against real CI — the next concrete step.

## f4-qt `--toolchain zig`: `close_range` fix confirmed safe by real exhaustive grep; `statx` fix reverted -- confirmed it would have risked a link failure

Cloned `util-linux/util-linux` at the exact failing tag (`v2.39.2`) and
ran a real, exhaustive `grep -rn "close_range(\|statx("` across the
whole `libblkid/` and `libmount/` trees -- not a sample, the actual
source the failing CI build uses. Results:

**`close_range()`: zero real call sites anywhere in either directory.**
The only call in the whole codebase is inside `lib/fileutils.c`'s
`#ifdef TEST_PROGRAM_FILEUTILS` block -- a standalone test-harness
`main()`, not compiled as part of the library. `libblkid`/`libmount`'s
own internal fd-closing helper (`ul_close_all_fds`) already uses a
portable `/proc/self/fd`-based approach instead. **Forcing
`-DHAVE_CLOSE_RANGE=1`, scoped to the `libmount*` package via Conan's
package-pattern conf, is confirmed safe** -- it suppresses
`fileutils.h`'s conflicting `static inline` declaration (the actual
compile error) with zero risk of an unresolved symbol at link time,
since nothing calls the real function. Kept in
`tools/build-f4-qt.sh`.

**`statx()`: two real call sites exist** -- `libmount/src/utils.c:119`
and `libmount/src/hook_mount.c:301`. Checked whether the earlier
`-DHAVE_STATX=1` idea (already reverted, never merged past a local
sandbox edit) would have been safe the same way `close_range`'s fix is,
and it would **not** have been: both call sites are gated by
`HAVE_STRUCT_STATX`/`HAVE_STRUCT_STATX_STX_MNT_ID` (whether the
*kernel-header-provided struct type* is available — independent of
glibc, essentially always true), **not** by `HAVE_STATX` (the function
declaration flag) — so forcing `HAVE_STATX=1` would not have
prevented these calls from compiling; it would only have made them
resolve to zig's `extern` declaration instead of `fileutils.h`'s own
safe raw-syscall (`syscall(SYS_statx, ...)`) fallback. Confirmed via
search that glibc's own `statx()` **library wrapper was added in glibc
2.28** — one version *after* this project's 2.27 baseline — meaning
that extern symbol genuinely isn't linkable at our pinned baseline.
Forcing `HAVE_STATX=1` would very likely have traded today's clear
compile error for a much less obvious "undefined reference to statx"
link error at the very end of a multi-hour CI run. **Not applied.**

**Real next step for `statx`, not yet implemented**: a precise 3-line
source patch — rename `fileutils.h`'s shim (and only the shim) to
something like `ul_fallback_statx`, and update the two call sites
(`utils.c:119`, `hook_mount.c:301`) to call it by that name instead of
the bare `statx` that collides with zig's header. This keeps the safe
raw-syscall implementation in actual use at both call sites while
resolving the compile-time redeclaration conflict — unlike a blanket
`-D` rename (which would rename zig's header declaration by the same
textual substitution and reproduce the identical conflict under a new
name, confirmed by reasoning through how `-D` macro substitution
actually applies across a whole translation unit). Would need a Conan
source patch mechanism (e.g. a `contrib/f4-qt/patches/` file, matching
the pattern this project already uses in `contrib/far2l/patches/`) —
not yet written.

## f4-qt `--toolchain zig` real CI run: got through 9/54 packages (incl. ICU fully) before hitting a real, upstream zig bug — `libmount` build fails

First real `f4-qt-zig-build.yml` run on GitHub Actions: 9 minutes of
uninterrupted wall-clock time got through `bzip2`, `icu` (fully — the
package that repeatedly defeated this project's own sandbox time limit),
`libde265`, `libffi`, and a handful more, confirming the core mechanism
holds up at real scale, not just on a toy example. Progress stopped at
package 10 of 54 (`libmount`, part of `util-linux`), with a real,
reproducible build failure — not a flake, not a config mistake on our
side.

**Root cause identified precisely: this is [ziglang/zig#22765](
https://github.com/ziglang/zig/issues/22765), a known, open upstream zig
bug, reproduced independently by someone else against the exact same
source (`util-linux`'s `include/fileutils.h`, `close_range`).** zig's
bundled headers for `-target x86_64-linux-gnu.X.Y` always describe the
*newest* glibc's API surface (`close_range`/`statx` declared
unconditionally as `extern`), regardless of which older glibc baseline
`-target` pins for *linking*. Packages that do their own
`configure`-time availability detection and provide a `static inline`
fallback when a symbol isn't linkable at the pinned baseline (exactly
what `util-linux`'s `fileutils.h` does for `close_range`/`statx`) collide
with zig's own unconditional header declaration: "static declaration of
'close_range' follows non-static declaration." Confirmed via direct web
search, not guessed — the linked issue reproduces the identical error
against the identical source file.

**Not a fast fix on our side.** Three real options, none attempted yet:
1. Wait for zig's own fix (issue is open, "contributor friendly" tagged,
   not yet resolved as of this check).
2. Force `util-linux`'s own `configure`-detected `HAVE_CLOSE_RANGE`/
   `HAVE_STATX` macros to `1` via a package-scoped Conan conf
   (`-c "libmount/*:tools.build:cflags=[...]"`), suppressing its own
   fallback and trusting zig's header declaration alone — risks a *link*
   failure instead if the 2.27 baseline genuinely lacks the symbol and
   `libmount`'s code actually calls it (not yet checked).
3. Disable whatever Qt/Conan option pulls `libmount` in at all, if it
   isn't strictly required for f4-qt's own build (not yet checked whether
   this is feasible without losing needed functionality).

`ccache` stats from this run: only 4/118 hits (3.4%) — expected and
harmless, this was a cold cache (first-ever run, nothing to reuse yet);
subsequent runs should benefit from the `actions/cache@v4` step. Also
noted: this run's `--out` path collision meant no artifact was produced
(expected, since the build never reached completion) — nothing to fix
there.

## f4-qt `--toolchain zig`: real end-to-end build progress in a sandbox, blocked by a genuine sandbox-only limit — GitHub Actions workflow added to finish it properly

Ran `quickstart-f4-qt.sh --toolchain zig` for real, resuming across many
sandbox tool-call windows (each capped at a few minutes of wall-clock
time). Real, confirmed progress: `libxcb-util-dev`/`libxcb-util0-dev`
were a second, previously-unnoticed gap in the preflight package list
(fixed); `uv venv` needed `--clear` to survive a resumed run after any
partial failure (fixed); ccache, wired in via Conan's
`tools.cmake.cmaketoolchain:extra_variables` conf, took the cache hit
rate from ~4% to over 90% once `base_dir`/`sloppiness` were configured
correctly for Conan's ever-changing per-attempt build folder names
(fixed, and now set automatically by `quickstart-f4-qt.sh` itself, not
left as an ad-hoc sandbox tweak).

**Genuine limit found, not a bug in the recipe**: Conan does not resume
an interrupted package build — any interruption discards the entire
in-progress build folder and restarts that package's `build()` from
scratch, including a full from-scratch `./configure` for autotools-based
dependencies like ICU. Confirmed directly by manually `cd`-ing into an
interrupted ICU build folder and running `make` there without going
through Conan at all: it correctly resumed (225 → 450 → 499 object files,
completing the whole library) — proving the *code* and *toolchain* are
fine — but Conan's own next `conan install` call ignored that
manually-completed build entirely and started a brand-new folder from
zero, because Conan's `package()` step (which finalizes a build into its
package cache) never ran for that orphaned folder. This is a genuine
constraint of a short-lived, timeout-bounded sandbox session — not
something fixable in the recipe or the toolchain.

**Fix: run it somewhere without that constraint.** Added
`.github/workflows/f4-qt-zig-build.yml`, a manually-triggered
(`workflow_dispatch`) GitHub Actions job building f4-qt via the same
`--toolchain zig` path, on `ubuntu-24.04` with a 300-minute timeout — far
beyond what any interrupted-package-restart cost could exhaust in one
uninterrupted run. Caches both `~/.conan2/p` and `~/.cache/ccache` across
runs (via `actions/cache@v4`) so a later re-run (after a recipe or
toolchain tweak) doesn't repay the full ~35-package cost from zero
either. Not yet triggered or verified — this is the next concrete step,
and the right place to actually finish this build, not a further sandbox
session.

## f4-qt `--toolchain zig`: real first user run found a real gap — Conan's "system" packages need root to auto-install; fixed with `mode=check`

A user ran `quickstart-f4-qt.sh` for real, non-root, no container — and
hit a genuine wall past what this project's own sandbox testing had
reached: Conan's `egl/system`, `opengl/system`, `xorg/system`, and
`xkeyboard-config/system` recipes each call `apt-get`/`apt.install_
substitutes()` to install dev headers (e.g. `libegl1-mesa-dev` as a
substitute for `libegl-dev`) when they detect them missing — and without
root, that fails with a buried, unhelpful `Permission denied` deep
inside a Qt subbuild's log, not a clear top-level error.

This is not a container-vs-zig problem — it's a `tools.system.
package_manager` configuration one, present regardless of compiler.
`tools/build-f4-qt.sh` had `mode=install`, copied from f4's own script
(which never hits this because their own build runs as genuine root
inside their Ubuntu 18.04 container). Changed to `mode=check`: Conan
still checks for the same packages, but reports exactly what's missing
and how to install it instead of attempting to install anything itself.

Worth noting explicitly: `egl/system`/`opengl/system`/`xorg/system` are,
by name, precisely the ABI-stable, host-provided libraries this
project's own doctrine (Profile H's host contract) already treats as
"the host provides these, don't vendor them" — Conan's own package
naming convention independently agrees with our own Layer 3 distinction.
The fix asks the user to `apt install` a handful of small, ordinary
desktop dev-header packages once, themselves, with their own `sudo` —
not something this project tries to do on their behalf, consistent with
"no root, no mess" the whole quickstart script exists to honor.

`tools/build-f4-qt.sh --help`'s `--toolchain zig` section now documents
this explicitly, so it's not a surprise on a first real run.

## f4-qt build: `--toolchain zig` implemented and its core mechanism proven — full Qt build not yet run end to end

The proposal below (container-free build via Conan + our own zig-cc/
zig-c++, the same substitution already used for far2l) is now
implemented in `tools/build-f4-qt.sh --toolchain zig`, and — crucially —
**its core mechanism was proven in this sandbox before being written,
not left as theory**:

1. A minimal Conan-driven CMake project (`conanfile.txt` +
   `CMakeToolchain`/`CMakeDeps` generators), with `conan install` pointed
   at `onebin/toolchain/zig-cc`/`zig-c++` via
   `tools.build:compiler_executables`, generates a working
   `conan_toolchain.cmake`. `cmake --preset conan-release` configures
   cleanly (`-- The CXX compiler identification is Clang 18.1.6` — zig's
   own Clang frontend, correctly detected) and `cmake --build` produces a
   real, runnable binary.
2. Adding `-target x86_64-linux-gnu.2.27` via `tools.build:cflags`/
   `cxxflags`/`exelinkflags` (Conan's own conf mechanism, the same one
   f4's own script already uses to pin `gcc-11`) lands the flag correctly
   in the generated toolchain file, confirmed by grep.
3. `onebin audit --profile hybrid --glibc-max 2.27 --level 1` on the
   result: `glibc: requires GLIBC_2.16, baseline 2.27` — **PASS Level 1,
   0 errors** — the pinning is real and independently verified by our own
   tool, not just claimed by the build.

`tools/build-f4-qt.sh` now has `--toolchain host|zig`: `host` keeps
today's exact behavior (wrap f4's own `ci/build-portable-qt-linux.sh`
wholesale, root + literally Ubuntu 18.04, kept for side-by-side
verification against upstream's own claims); `zig` is a genuine parallel
reimplementation of that script's essential steps in POSIX sh — same
Conan `target_packages` list, same `ci/build-qwindowkit.sh` call (checked
directly: it hardcodes no compiler of its own, so it's toolchain-agnostic
and reusable as-is), same `cmake`/`ctest`/audit/smoke-test/packaging/`go
build` tail — with the root/Ubuntu-18.04 guard removed entirely and the
compiler substituted. No container, no root, no specific host OS; `uv`
(one binary) and its venv are both trivially removable afterward.

**Honest scope of what's verified vs. not**: the *mechanism* (Conan +
zig-cc via `compiler_executables` + glibc pinning via `cflags`, audited
correctly) is proven, end to end, with a real built-and-run binary. The
*actual ~35-package Qt dependency stack* has not been built this way in
this session — that would take substantially longer than this pass
allowed. `--print-plan` for `--toolchain zig` produces a complete,
sensible command sequence (verified); actually running it to a finished
`f4-qt-host` binary is the next real step, not yet done. Recorded
precisely so this isn't mistaken for more than it is.

## f4-qt build: currently wraps f4's own Ubuntu-18.04-container CI wholesale — proposal to fix, not yet implemented

Read `tools/build-f4-qt.sh` and, critically, the actual script it shells
out to (`ci/build-portable-qt-linux.sh` in f4's own repo, pinned commit).
**Found a real architectural inconsistency with how this project treats
far2l.** f4's script refuses to run at all unless it's literally root
inside literally Ubuntu 18.04:

```sh
if [[ "$(id -u)" != 0 ]]; then
    echo "error: run this baseline builder as root inside Ubuntu 18.04" >&2
    exit 2
fi
if ! grep -q 'Ubuntu 18.04' /etc/os-release; then
    echo "error: glibc 2.27 contract requires the Ubuntu 18.04 build container" >&2
    exit 2
fi
```

`tools/build-f4-qt.sh` currently just invokes this wholesale and audits
the result afterward with `onebin` — meaning **on any host that isn't
literally an Ubuntu 18.04 machine (in practice: a container), this
project's own f4-qt build path is unusable without exactly the kind of
container tooling the manifesto exists to avoid needing.** That's not a
cosmetic gap; it directly contradicts what this project is for.

For far2l, we never wrapped far2l's own CI as a black box — we injected
`onebin-linux-hybrid.cmake` (`zig cc -target x86_64-linux-gnu.2.28`)
directly into far2l's own `CMakeLists.txt`, letting any modern host pin
an old glibc baseline via a toolchain flag rather than by literally
running the old OS. f4-qt's build never got the same treatment.

**Proposed fix, not yet implemented or tested end to end**: Conan (the
package manager f4's script uses to build its ~35-package Qt dependency
stack) already supports pointing it at an arbitrary compiler binary —
the script itself does exactly this for `gcc-11`:
```sh
-c 'tools.build:compiler_executables={"c":"gcc-11","cpp":"g++-11"}'
```
Point this at `onebin/toolchain/zig-cc`/`zig-c++` (`-target
x86_64-linux-gnu.2.27`, matching f4-qt's own pinned baseline) instead,
and drop the root/Ubuntu-18.04 guard entirely. Conan/CMake/Qt's own build
shouldn't need to know or care that the compiler is a zig wrapper rather
than a genuine `gcc-11` binary — this is exactly the same substitution
already proven to work for far2l's whole dependency chain. No container,
no root, no specific host OS; `zig` (one downloadable binary) and
`uv`/Conan (a Python venv) are both trivially removable afterward.

**Not proposing a from-scratch, Homebrew-style reimplementation of Qt's
build recipe** — that is a different, much larger project than this
one's scope. The right level of intervention here matches everywhere else
in this project: swap the *toolchain*, keep the *recipe* (Conan does
exactly what it already does, fetching/building the same ~35 packages the
same way f4's own maintainers chose) exactly as-is.

**Worth offering as an explicit choice, not a replacement**: a
`--toolchain host|zig` flag on `tools/build-f4-qt.sh` — `host` keeps
today's behaviour (trust f4's own CI exactly, for side-by-side
verification against upstream's own claims) and `zig` is the new,
container-free path this project's own doctrine actually calls for.
Neither makes the other redundant.

**Not yet done**: actually wiring a Conan profile through zig and
confirming Qt's own build system (CMake, but with Qt's substantial own
configure-time compiler probing) tolerates a `zig cc` compiler binary
end to end — this is a real, unverified next step, not a proven result.
Recording the proposal now so it isn't lost, not claiming it works yet.

## NetRocks OpenSSL & WebDAV: RESOLVED — Built with OpenSSL 3.0 & neon

Inspection of far2l's actual `LICENSE.txt` revealed that upstream explicitly
included the standard **OpenSSL Linking Exception** grant at the bottom of the
file. Statically linking OpenSSL (OpenSSL 3.0.15) into far2l and NetRocks
is therefore completely legal under far2l's terms.

Wiring is completed: `openssl 3.0.15` and `neon 0.34.0` are pinned in
`contrib/far2l/deps.lock`, and `tools/build-far2l.sh` passes their static paths
to CMake, enabling NetRocks-FTP (with FTPS) and NetRocks-WEBDAV out of the box.
## far2l-sdl exit segfault: FIXED via `-Wl,-z,nodelete`

The issue identified below is entirely bypassed at the toolchain level.
Instead of patching far2l to remove `dlclose()` or call `__cxa_finalize()`,
we added `-Wl,-z,nodelete` to the linker flags in `onebin-linux-hybrid.cmake`
and the Meson native file. This standard flag instructs the dynamic linker
(`ld.so`) to keep the loaded object mapped in memory for the lifetime of
the process, effectively making `dlclose()` a no-op for memory management.

As a result, any statically linked C++ destructors registered via `__cxa_atexit`
(e.g., from Fontconfig, HarfBuzz, or SDL2 inside `far2l_sdl.so`) will have
valid mapped code to execute when `exit()` is called. This perfectly
matches the "Static Everywhere" philosophy: heavily statically-linked plugins
are inherently unsafe to unmap, and `-z nodelete` guarantees their safety
with zero source-code patches.
## far2l-sdl exit segfault: ROOT CAUSE FOUND — a `dlclose()`'d plugin's `__cxa_atexit`-registered destructor

Two full `cookie-check.gdb` runs, both pasted in full. **The cookie
hypothesis is now conclusively dead, not just suspected**: within each
run the cookie is 100% constant — `0xa909d88f99f9dc9a` in run 1,
`0xb4aad96908848f12` in run 2 (different between runs, as ASLR would
produce; identical across every single one of the hundreds of
`__cxa_atexit` calls *within* a run, across every thread including
thread 10 and thread 3). No mismatch, anywhere, ever. Both prior
`_exit()`-avoids-the-problem and cookie-mismatch theories are retired.

**The real evidence, sitting in plain sight in both transcripts**: right
before the crash, thread 10 registers a dense run of `__cxa_atexit`
calls from addresses in the `0x7fffe40...`/`0x7fffec8f8...`-style range —
**not** the main executable's own range (`0x555555...`) and **not**
standard system libraries (`0x7ffff7...`) — the shape of a separately
`dlopen`'d module (a far2l plugin). Immediately after, `[Detaching after
vfork from child process ...]` appears (far2l forking a helper), and
**the crash address itself lands within a few hundred bytes of that same
thread's last `__cxa_atexit` caller addresses** (run 1:
`caller=0x7fffe4082232`/`0x7fffe40822f9` immediately before, crash at
`0x7fffe4082b20`).

This matches far2l's own plugin system exactly: `far2l/src/plug/
plclass.cpp:90` calls `dlclose()` when unloading a `.far-plug-wide`
plugin. If a plugin registers a `static` C++ object with a non-trivial
destructor (which any nontrivial plugin plausibly does — a global config
cache, a logger, a `std::string` table, anything), `__cxa_atexit`
registers that destructor to run at **process** exit — but the plugin's
own code and data get unmapped the moment `dlclose()` runs. Every
following `exit()` call still tries to invoke that now-dangling function
pointer, landing in unmapped memory — exactly the shape confirmed here.
This is a well-known, well-documented class of bug in `dlopen`/`dlclose`
based plugin systems generally, not specific to musl/glibc/zig-cc/Static
Everywhere at all — it would affect *any* toolchain.

**This is now upstream far2l's bug to fix, not this project's toolchain.**
Recorded as a new item in `contrib/far2l/UPSTREAM.md`: either (a) never
`dlclose()` a plugin whose static objects might have registered
`__cxa_atexit` handlers (the simplest, safest fix — leak the mapping,
the standard workaround for this exact class of bug), or (b) call
`__cxa_finalize(handle)` for the plugin's own load address *before*
`dlclose()`, which explicitly runs and de-registers exactly that
plugin's own atexit-registered destructors first, leaving nothing
dangling. Not yet written up as a filed issue or PR — the mechanism is
confirmed, the exact plugin responsible is not yet identified (would
need `info symbol` or the plugin's own load-address range from `info
proc mappings`, not yet done — the *class* of bug is now certain, the
specific plugin is a fast follow-up, not a blocker for reporting this
upstream).

## far2l-sdl exit segfault: `_exit()` workaround rejected (correctly) — root-causing continues; script to compare the TLS pointer-guard cookie at registration vs. crash time

A prior reply in this session's dialogue proposed skipping
`__run_exit_handlers` entirely via `_exit()` instead of `return` at the
end of `WinPortMain`, as a pragmatic way to stop the crash without
root-causing it. **The user rejected that patch, correctly, and it was
never committed here** — the reasoning holds up: unlike deprioritizing
WebDAV/GnuTLS (a scope decision — a feature simply isn't built yet),
`_exit()` would silently discard every application-level cleanup running
in a static destructor anywhere in the process, forever, to avoid
understanding one specific crash. That's a correctness sacrifice on the
altar of speed, not the kind of "fix minimally" this session's own
course-correction called for.

**Root-causing continues.** One fact from the two backtraces so far,
underweighted until now: **the exact same crash address
(`0x00007fffc97e7550`) appeared in both independent runs.** If the
`PTR_MANGLE`/`PTR_DEMANGLE` cookie genuinely differed randomly between
threads (ASLR-influenced, as it normally would if two threads legitimately
had different per-thread secrets), the resulting demangled garbage should
differ between separate process invocations too — getting the identical
address twice argues either that ASLR isn't actually randomizing the
relevant state in this environment, or that whatever discrepancy exists
is itself deterministic rather than a one-off race.

**`cookie-check.gdb`** (attached alongside this reply) breaks on every
`__cxa_atexit` call, logging the calling thread and the live TLS
pointer-guard cookie (`%fs:0x30`) each time — auto-continuing, so it
doesn't require manual stepping through however many registrations
happen — then lets execution run to the actual crash and prints the
cookie there too, plus frame 1's raw (still-mangled) stored pointer
alongside the demangled garbage, for direct comparison. If the cookie at
any `__cxa_atexit` call differs from the cookie at the crash, that is the
confirmed root cause and points at exactly which registration is the bad
one (the caller address printed alongside each hit). If every cookie
matches throughout, that rules out a pointer-guard mismatch entirely and
redirects the investigation toward the raw stored value being wrong to
begin with (e.g. genuine memory corruption of the `__exit_funcs` list
itself, or an ABI mismatch in how the destructor's context pointer
`entry->d.cxa.arg` is laid out). Either outcome moves this forward
concretely — no rebuild required, this runs against the exact binary
already in hand: `gdb -q -x cookie-check.gdb --args ./far2l`.

## far2l-sdl exit segfault: `MALLOC_CHECK_=3` did nothing — rules out heap-metadata corruption, narrows to a stale function-pointer use-after-free

Same binary (no rebuild — the user was explicit that rebuilding takes
real time and won't happen without a direct instruction to do so), run
again with `MALLOC_CHECK_=3 ./far2l`: identical plain segfault, no early
`malloc(): ...` abort. This is a genuinely informative negative result,
not a dead end: `MALLOC_CHECK_` only catches **heap metadata**
corruption — a write past a chunk's boundary, a double free, a bad
chunk-size field. It does **not** catch "a heap pointer whose *contents*
silently became something else because the chunk was freed and its
memory reused for unrelated data" — which is exactly what a dangling
function pointer left behind by an exited thread would look like: the
pointer value itself was never corrupted, the memory it points at just
stopped being what it used to be.

This rules out classic buffer-overflow-style heap corruption as the
cause and narrows the earlier hypothesis (§ below) specifically to: a
`static` object with a non-trivial destructor, constructed on one of
far2l-sdl's many short-lived worker threads, registered its destructor
via `__cxa_atexit` to run at *process* exit — and by the time that
destructor call actually happens, the memory backing either the object
or the registration itself has been reused for something else entirely
(consistent with the crash IP landing inside a malloc arena's
reserved-but-uncommitted gap, not real code).

**Next step, still no rebuild needed — one more `gdb` session against
the exact same binary, one command, copy-pasteable:**
```sh
gdb -ex run -ex 'frame 1' -ex 'info registers' -ex disassemble -ex 'frame 0' -ex 'info registers' -ex quit --args ./far2l
```
This reproduces the same crash and, in the same session, dumps frame
1's (`__run_exit_handlers`) registers and disassembly — glibc ships
without source but the machine code itself is on disk, so `disassemble`
should work even without debug symbols — which shows exactly which
register held the bad function pointer immediately before the crashing
call, and frame 0's own registers at the crash point. That's enough to
tell whether the bad pointer looks like a genuine (if stale) code
address, a small integer (uninitialized/zeroed memory), or something
else recognizable, without needing a rebuild or new instrumentation.

## far2l-sdl exit segfault: real backtrace analyzed — crash IP lands in a malloc-arena PROT_NONE gap, executing garbage as code

Two real backtraces from the user's own reproducible crash (both consistent):

```
Thread 1 "far2l" received signal SIGSEGV, Segmentation fault.
0x00007fffc97e7550 in ?? ()
#0  0x00007fffc97e7550 in ?? ()
#1  __run_exit_handlers (status=0, run_list_atexit=true, run_dtors=true) at ./stdlib/exit.c:108
#2  __GI_exit (status=<optimized out>) at ./stdlib/exit.c:138
#3  __libc_start_call_main (main=0x5555557d2df0, ...) at ../sysdeps/nptl/libc_start_call_main.h:74
#4  __libc_start_main_impl (...) at ../csu/libc-start.c:360
#5  _start ()
```

**The decisive new fact: `info proc mappings` at the crash point shows
`0x00007fffc97e7550` falling inside a `---p` (`PROT_NONE`, zero
permissions) region** — specifically the large reserved-but-uncommitted
gap between `0x7fffc41c2000` and `0x7fffc8000000`, one of several
identical `rw-p` (~132 KiB) + `---p` (~64 MiB) pairs scattered through
the address space. **This is the textbook shape of a glibc per-thread
malloc arena**: a small committed region followed by a large reserved,
inaccessible one, one pair per thread that has ever called `malloc`.

Putting the two facts together: **`__run_exit_handlers` is trying to
*call* an address that is not code at all — it's sitting in the
unmapped, reserved portion of a thread's malloc arena.** This is not "a
bug in some destructor's logic"; it's a corrupted or stale function
pointer in glibc's own `atexit`/`__cxa_atexit` registration list,
almost certainly written by (or pointing into memory that used to
belong to) one of the many short-lived worker threads
`far2l`/`far2l_sdl.so` create and destroy during a session — visible in
both gdb transcripts as a churn of `[New Thread ...]` /
`[Thread ... exited]` pairs right before the crash. A `static` (not
`thread_local`) object with a non-trivial destructor, first constructed
on a worker thread, registers its destructor via `__cxa_atexit` to run
at **process** exit regardless of which thread constructed it — if
anything about that registration or the object's storage becomes
invalid once the constructing thread is gone, this is exactly the
resulting crash shape.

**Fast, zero-rebuild next diagnostic, not a rebuild or a deep-dive:**
run once more with glibc's built-in heap-corruption checker, which
aborts *at the moment* of corruption with a diagnostic, rather than
segfaulting later during exit:
```sh
MALLOC_CHECK_=3 ./far2l
```
If that changes the failure to an early, loud `malloc(): ...` abort
(likely with a partial backtrace pointing at the actual corrupting
write), that confirms heap corruption and gives a real location to fix.
If it doesn't fire and the same exit-time segfault still happens, that
argues more specifically for a stale/thread-local `atexit` registration
race rather than a stray heap write, which narrows where to look next
without guessing further.

## far2l-sdl exit segfault: reproduced the build, could not reproduce the crash in this sandbox — need a backtrace, not more guessing

Built far2l-sdl for real, per the user's own confirmed-working recipe
(this session's sandbox had been pointed at the wrong checkout — `v_2.8.0`,
which has no SDL backend at all — the correct one is the pinned commit,
`/tmp/far2l-sdl-src` in this sandbox's own history, `65c29da43`).
`--help` runs and exits 0 cleanly. Tried to reproduce the reported exit
segfault under `Xvfb` + `xdotool` (closing the window, then `SIGTERM`)
three times; each time far2l exited 0 with no crash, likely because a
headless virtual framebuffer with no window manager doesn't exercise the
same shutdown path a real desktop session does. **Chasing that further
by fighting Xvfb/window-manager quirks in a sandbox is exactly the kind
of rabbit hole this correction exists to stop** — noted and stopped
deliberately rather than continued.

Read `WinPort/src/Backend/SDL/SDLMain.cpp`'s shutdown path instead, to
have *something* concrete rather than nothing: `WinPortMainBackend`
constructs `SDLConsoleApp app`, calls `app.Run()` (which internally joins
`_worker`, the thread running far2l's actual entry point, before
returning), then lets `app` go out of scope — `~SDLConsoleApp()` calls
`Destroy()` (`_backend->Detach()`, `_backend.reset()`,
`SDL_DestroyWindow()`), then `SDL_Quit()` runs after that. Nothing jumped
out as an obvious use-after-free or double-free on a straight read, but
a straight read is not a substitute for the actual crash's backtrace, and
guessing at a fix without one risks exactly the wasted-effort pattern
this correction is about.

**Needed to actually fix this, fast, next: a backtrace from a real crash.**
```sh
ulimit -c unlimited
./far2l   # reproduce the crash normally, then:
gdb ./far2l core -ex bt -ex quit   # or: coredumpctl gdb, if using systemd-coredump
```
or simpler, if gdb is installed: `gdb -ex run -ex bt -ex quit --args ./far2l`
and reproduce interactively. Either output, pasted back, turns this from
a guess into a real fix in one pass.

## COURSE CORRECTION — read this before touching Task 15 again

The previous session went well past the point of diminishing returns:
building GnuTLS/nettle/gmp from source for WebDAV, chasing a suspected
Clang codegen bug via disassembly, for a protocol NetRocks-SHELL/FISHPLUS
already cover. **That kind of depth is explicitly out of bounds until the
two items below are done.** This is not a suggestion, it's the priority
order for every session from here on:

1. **`far2l-sdl` segfaults on exit. Fix that first, minimally.**
2. **Build the f4-qt wrapper and get a working artifact to the user.**

Nothing else — no rare-protocol chasing, no rebuilding a dependency's
dependency's dependency from source, no toolchain archaeology for its own
sake — until both of those are real. If a build step needs a library the
host's package manager already has, use the host's, dynamically, the way
Profile H is supposed to work. Don't vendor and rebuild it statically
"to be safe" unless something concrete actually requires that.

**The user's own build, done by hand, already works better than where the
previous session's from-source rabbit hole was headed** — network,
archives, and editor syntax highlighting all functional, using the host's
own dev packages via a `-isystem` include-path fix rather than rebuilding
anything from source:

```sh
cmake -S /tmp/far2l -B . \
  -DCMAKE_TOOLCHAIN_FILE="$REPO/toolchain/onebin-linux-hybrid.cmake" \
  -DCMAKE_BUILD_TYPE=Release -DICU_MODE=prebuilt \
  -DUSEWX=no -DUSESDL=YES -DPYTHON=no -DUNRAR=no \
  -DNR_OPENSSL=no -DNR_AWS=no -DCMAKE_DISABLE_FIND_PACKAGE_OpenSSL=TRUE \
  -DCMAKE_C_FLAGS="-isystem /usr/include/x86_64-linux-gnu" \
  -DCMAKE_CXX_FLAGS="-isystem /usr/include/x86_64-linux-gnu" \
  -DCMAKE_INSTALL_PREFIX=./install
```

Note what's *absent*: no `-DNETROCKS=no`, no `-DMULTIARC=no`, no
`-DCOLORER=no` — those stay at far2l's own defaults (yes) and link
against whatever the host's `apt`-installed dev packages provide,
dynamically. This is Profile H working as designed, not a compromise.
The one known, confirmed-real problem with this exact build: **`far2l`
(the SDL config) segfaults on exit.** That is today's actual bug, not a
`gnutls` build.

## WebDAV/GnuTLS deprioritized -- disproportionate effort for a low-value target; NetRocks-SHELL/FISHPLUS already cover network transfer

Attempted the GnuTLS chain (`gmp` → `nettle` → ...) needed for `neon`/WebDAV.
`gmp 6.3.0` built and verified clean. `nettle 3.10.2` built, but its own
`gcm-test` crashes (`SIGILL`/`ud1` trap) under zig's bundled Clang 18.1.6 at
`-O2` — root cause identified (a dead-branch `0 ? typecheck(...) : real(...)`
idiom in `gcm.h`, used to type-check a function pointer at compile time,
gets miscompiled: the provably-unreachable branch's NULL-pointer/alignment
check is left in as a live trap instead of being eliminated). `-O1` avoids
it; not reconfirmed with a full test run.

**Stopping here, deliberately, not out of the finding being wrong but
because it's disproportionate:** this project is pre-1.0, and WebDAV is
one protocol among several NetRocks already supports without it —
`NetRocks-SHELL`/`NetRocks-FISHPLUS` already give real, working,
zero-extra-dependency network file transfer today (§6.2.1). Chasing a
single compiler miscompilation four dependencies deep (`gmp`→`nettle`
→`libtasn1`→`gnutls`→`neon`) for one optional protocol is exactly the
kind of low-value depth this project should defer past its "prove it"
milestone, not power through. No `gmp`/`nettle` pins were added to
`deps.lock` — nothing here was verified enough to commit.

**Not resuming without a real reason to.** If picked up again later:
start from `-O1` for `nettle` specifically (or an even narrower
per-file override) and confirm with `make check`, or open a report
against zig's bundled Clang. Until then, WebDAV stays out of the
`v_2.8.0` Level-1 target list, same as it already implicitly was.

## `libnfs` pinned and `NetRocks-NFS.broker` builds clean; real finding for the last group-4 dependency: `neon`/WebDAV needs GnuTLS, not mbedTLS

Continuation of the same Task 15 group 4 effort. `mbedtls`+`libssh` (previous
two entries below) covered SFTP/SCP; this one covers NFS and identifies what
WebDAV actually needs.

`libnfs 6.0.2` (LGPL-2.1, no mandatory third-party dependency) pinned in
`contrib/far2l/deps.lock`, built static via `onebin-linux-hybrid.cmake`
with `-DCMAKE_DISABLE_FIND_PACKAGE_GSSAPI=TRUE
-DCMAKE_DISABLE_FIND_PACKAGE_GnuTLS=TRUE` (both are optional, non-`REQUIRED`
probes in libnfs's own CMakeLists.txt that degrade gracefully — forced off
regardless of build-host state, same reasoning as `WITH_GSSAPI=OFF` for
libssh). A smoketest creating a real `nfs_context` and parsing a real
`nfs://` URL passed `onebin audit --profile hybrid --level 1 --strict`
clean (`needed: libc.so.6 libpthread.so.0`). Found a real header quirk
while writing it: `nfsc/libnfs.h` uses `size_t` throughout without
including `<stddef.h>` itself — confirmed by reading the header, not
assumed.

**Confirmed by building the actual `NetRocks-NFS.broker` target, not just
the smoketest.** far2l's `cmake/modules/FindLibNfs.cmake` uses *singular*
cache variable names (`LIBNFS_LIBRARY`/`LIBNFS_INCLUDE_DIR`) — unlike
`FindLibSSH.cmake`'s plural early-exit trick used for the SFTP pin. Pre-
seeding the plural forms first (by analogy with libssh) silently left
`NetRocks-NFS` unconfigured; caught by checking `CMakeCache.txt` directly
rather than assuming the two Find modules share a convention. With the
right names: `-- libnfs found -> enjoy NFS support in NetRocks`. Built
from the pinned `v_2.8.0` tag, same flags as the `NetRocks-SFTP.broker`
pass. `onebin audit --profile hybrid --level 1`: `needed: libc.so.6
libdl.so.2 libpthread.so.0`, **0 errors** — the same already-documented
`OB0060` `/var/tmp` warning as every other NetRocks broker, not new.

**Real limit, documented rather than glossed over:** unlike libssh's
loopback-`sshd` round trip, no live NFS server exists in this build
sandbox — `/proc/fs/nfsd` is absent and `nfs` doesn't appear in
`/proc/filesystems` (no loadable kernel NFS module inside a container).
Verification stops at context creation + URL parsing + clean link + the
real far2l target building — not a full client<->server exchange.

**The real finding for the last group-4 dependency, `neon` (WebDAV):**
checked upstream's own build docs directly — neon only supports OpenSSL
or GnuTLS for HTTPS, no mbedTLS backend exists at all. Since OpenSSL
stays excluded for the `04-REFERENCE-far2l.md` §7.7 licence reason,
**GnuTLS becomes the necessary choice for this one dependency**,
reversing this project's own earlier bias against it (mbedTLS was
strictly better for libssh — see the two entries below). GnuTLS pulls in
`nettle`+`gmp`+`libtasn1`+`p11-kit`, a materially heavier chain than
anything pinned so far. Not started this pass — the next real step for
Task 15 group 4.

`04-REFERENCE-far2l.md` updated: §5's libnfs/neon rows, and a new §6.2.3
with the full writeup.

## `NetRocks-SFTP.broker` itself now builds and audits clean against the mbedTLS/libssh pins -- not just a standalone smoketest

Continuation of the same pass. The previous entry below verified
`mbedtls`+`libssh` in isolation; this one builds the actual far2l target
that consumes them.

far2l's `cmake/modules/FindLibSSH.cmake` is a hand-written `find_library`/
`find_path` module with no transitive-dependency info of its own.
Pre-seeding its cache variables directly —
`-DLIBSSH_LIBRARIES="<libssh.a>;<libmbedtls.a>;<libmbedx509.a>;
<libmbedcrypto.a>;<libz.a>"` `-DLIBSSH_INCLUDE_DIRS=<libssh include dir>`
— skips the search entirely (the module's own early-exit: "in cache
already") and lets one CMake variable carry the whole static link chain,
matching `NetRocks/CMakeLists.txt`'s own
`target_link_libraries(NetRocks-SFTP utils ${LIBSSH_LIBRARIES})`.

Built `NetRocks-SFTP.broker` from the pinned `v_2.8.0` tag with the same
flags as the documented `far2l-tty` recipe (`04-REFERENCE-far2l.md`
§6.2) plus `-DCOLORER=no -DMULTIARC=no -DUSEUCD=no` to narrow this pass
to just the SFTP question (none of those three libraries are built in
this session's fresh sandbox — nothing here persists between sessions,
noted repeatedly elsewhere in this file). CMake's own configure log:
`-- libssh found -> enjoy SFTP support in NetRocks`. Builds to
completion — a real dynamically-linked PIE ELF.

`onebin audit --profile hybrid --level 1`: `needed: ld-linux-
x86-64.so.2 libc.so.6 libdl.so.2 libpthread.so.0` — exactly the Profile H
allowlist, **0 errors**. No `libcrypto`/`libssl`/`libgcrypt`/`libgnutls`
anywhere in `NEEDED` — confirms the static link is real, not just
correct in the CMake summary. `--strict` promotes the single already-
documented `OB0060` `/var/tmp` false positive (the same one noted for
every other NetRocks broker in `04-REFERENCE-far2l.md` §6.2.1, traced to
a genuine runtime-fallback string in `utils/src/InMy.cpp`) to a failure
— not a new finding, the identical known pattern.

`04-REFERENCE-far2l.md` updated: §5's libssh row and a new §6.2.2 now
say mbedTLS specifically (this project's actual, verified choice)
instead of listing GnuTLS/gcrypt/mbedTLS as interchangeable options.

**Not yet done:** this used the same ad-hoc `cmake` pattern as every
other pin in this file before `tools/build-far2l.sh` exists — folding it
into that script is still open, and so is `libnfs`/`neon` (WebDAV), the
rest of Task 15 group 4.

## Task 15 group 4 (network, the hard remainder) started: mbedTLS pinned instead of GnuTLS/libgcrypt, libssh builds clean, real end-to-end SSH handshake verified

Picked up where the previous pass left off: `far2l-sdl` (archives + network/
FISH + graphics groups) is done; this pass starts Task 15 group 4 —
`libssh` + a GPL-compatible crypto backend for `NetRocks-SFTP.broker`.

**Correction to this project's own plan, found by reading libssh's actual
`CMakeLists.txt` before pinning anything, not by assumption:** the
Task-15-order entry below says "libssh + a GnuTLS/libgcrypt crypto
backend". Checked directly against libssh 0.12.2: `WITH_GCRYPT` still
exists but now emits `message(WARNING "libgcrypt cryptographic backend
is deprecated and will be removed in future releases.")` at configure
time. GnuTLS was never actually tried — it pulls in nettle/gmp/libtasn1/
p11-kit, a much heavier chain than anything else pinned in `deps.lock` so
far. **Pinned mbedTLS instead**: Apache-2.0 (same GPL-compatibility
reasoning as `04-REFERENCE-far2l.md` §7.7's OpenSSL exclusion), a single
self-contained source tree, not deprecated. `04-REFERENCE-far2l.md`
line 388 already listed mbedTLS as a supported backend — only this
file's own Task-15-order note was stale.

`mbedtls 3.6.6` (LTS, supported to March 2027) pinned in
`contrib/far2l/deps.lock`, hash cross-checked against the release notes'
published SHA256. Built static via `onebin-linux-hybrid.cmake`. A
smoketest calling a real `mbedtls_sha256()` passed `onebin audit
--profile hybrid --level 1 --strict` clean (`needed: libc.so.6` only,
`-fPIE -pie` required — `ET_EXEC` trips `OB0054`, same as every other
pin in this file).

**Real bug found in libssh itself, not this project's code:** mbedTLS's
stock `mbedtls_config.h` ships `MBEDTLS_THREADING_C`/
`MBEDTLS_THREADING_PTHREAD` both disabled by default. libssh's
`src/threads/mbedtls.c` falls into the `#else` branch of its own
`#ifdef MBEDTLS_THREADING_ALT / #elif MBEDTLS_THREADING_PTHREAD` when
neither is defined, and that branch uses `#warn` (GCC/old-Clang-only)
instead of the portable `#warning` — zig's Clang 18 rejects `#warn`
outright as an invalid preprocessing directive, a hard compile error
regardless of whether the function is ever called. Confirmed the real
fix: rebuilding mbedTLS with `python3 scripts/config.py set
MBEDTLS_THREADING_C` and `... set MBEDTLS_THREADING_PTHREAD` (mbedTLS
already links pthread via its own `find_package(Threads)`, so this is
free) routes libssh down the `MBEDTLS_THREADING_PTHREAD` branch instead,
and it compiles clean. Recorded in `deps.lock`'s `mbedtls` entry so
`tools/build-far2l.sh`'s eventual mbedtls step applies it.

`libssh 0.12.2` pinned in `deps.lock`, built against this pass's own
zlib and mbedTLS pins: `WITH_MBEDTLS=ON WITH_GCRYPT=OFF
CMAKE_DISABLE_FIND_PACKAGE_OpenSSL=TRUE WITH_GSSAPI=OFF WITH_SERVER=OFF
WITH_PCAP=OFF WITH_EXAMPLES=OFF WITH_NACL=OFF WITH_SFTP=ON
BUILD_SHARED_LIBS=OFF`. `WITH_NACL` gracefully degrades to `OFF` on its
own (`find_package(NaCl)` result, confirmed by reading
`DefineOptions.cmake` directly) — not a hard requirement.

**Verified with more than a link check, for real:** started this
project's own `sshd` on loopback with a freshly generated ed25519 host
key and an ed25519 client key restricted to `authorized_keys`-only auth.
A smoketest's `ssh_connect()` + `ssh_userauth_publickey_auto()` both
succeeded — a genuine SSH2 key exchange and public-key authentication
through the mbedTLS backend end to end, not a synthetic API-surface
check. `onebin audit --profile hybrid --level 1 --strict` on the
resulting binary: **PASS, 0 errors, 0 warnings**; `needed: ld-linux-
x86-64.so.2 libc.so.6 libpthread.so.0` — no `libcrypto`/`libssl`/
`libgcrypt`/`libgnutls` anywhere in `NEEDED`, confirming OpenSSL and
libgcrypt really are absent from the link, not just from the CMake
configure summary.

**Not yet done:** the actual `NetRocks-SFTP.broker` CMake target (far2l's
own build, not a standalone smoketest) hasn't been configured against
these pins yet; folding `mbedtls`+`libssh` into `tools/build-far2l.sh`'s
`sftp`/full configs; and `04-REFERENCE-far2l.md`'s NetRocks-SFTP row
(line 388) could be tightened to name mbedTLS as this project's actual
choice rather than leaving all three backends listed as equally live
options. `libnfs` and `neon` (WebDAV) — the rest of Task 15 group 4 per
the order below — remain untouched.

## Toolchain fix: `onebin-linux-hybrid.cmake` now finds Debian/Ubuntu's multiarch headers automatically

Found by a real user hitting it building `far2l-sdl` with `apt`-installed
dev packages (`libsdl2-dev` and friends), not in any of this project's
own sandboxes: `zig-cc` failed with `'SDL2/_real_SDL_config.h' file not
found`, even though `/usr/include/SDL2/SDL.h` itself was found correctly.

Debian/Ubuntu (and derivatives) split multiarch-aware system headers into
`/usr/include/<triplet>/` (e.g. `x86_64-linux-gnu`) rather than plain
`/usr/include`. Their `apt` dev packages routinely install a thin
`/usr/include/<pkg>/foo.h` wrapper that `#include`s a `_real_foo.h` (or
equivalent) living **only** under the triplet directory — `SDL2/SDL_config.h`
does exactly this. `onebin-linux-hybrid.cmake` only ever added plain
`/usr/include`, so anything relying on this pattern failed. Confirmed via
`find /usr/include -name _real_SDL_config.h` → only present under
`/usr/include/x86_64-linux-gnu/SDL2/`.

Fixed in the toolchain file itself, not just documented: `gcc -dumpmachine`
gives the exact triplet the host's own default compiler was built for;
the toolchain file now runs this once (via `execute_process`, deliberately
**not** `find_program` — its result is itself cached per build directory,
and a toolchain file is evaluated more than once per configure run, so a
spurious `NOTFOUND` cached from an early evaluation before `PATH` is fully
visible in that context would otherwise stick for the build directory's
whole lifetime, which is exactly the bug that shipped in this fix's own
first draft and was caught by testing it for real rather than trusting it
on inspection alone) and adds `-isystem /usr/include/<triplet>` alongside
the existing plain `/usr/include`. Falls back to a no-op on hosts without
`gcc` (e.g. Alpine) rather than guessing a triplet. Overridable via
`-DONEBIN_MULTIARCH_DIR=...` if the auto-detected value is ever wrong.

Verified for real: reconfigured `onebin/toolchain/tests/` from scratch,
confirmed `ONEBIN_MULTIARCH_DIR` resolves to `x86_64-linux-gnu` on this
sandbox, confirmed the flag reaches both the compile and link command
lines, rebuilt the smoketest clean, and `onebin audit --profile hybrid
--level 1 --strict` on the result: PASS, 0 findings — the fix doesn't
regress anything already working.

## far2l-sdl dependency rebuild in progress: a real hazard found while rebuilding fontconfig — `DESTDIR` is not optional

Rebuilding the graphics-group dependency chain from scratch (this
project's built libraries live only in the ephemeral sandbox that built
them — see `NOTES` below on why nothing here persisted from the prior
session's own sandbox) surfaced a real, worth-remembering hazard:
**`fontconfig`'s own Meson custom install script
(`conf.d/link_confs.py`) does not respect `DESTDIR`.** Running `meson
install -C build` — even with `DESTDIR=$STAGING` set, which correctly
redirects every *ordinary* install target — still made that one custom
script symlink files directly into the **real, absolute**
`/etc/fonts/conf.d` and overwrite `/etc/fonts/fonts.conf` on the actual
build host, not the staging directory. This happened **twice** in this
session (the second time via the same command run again while
re-verifying the first fix), each time confirmed and corrected by
diffing against the untouched package (`dpkg-deb -x` on the downloaded
`.deb`) and either force-reinstalling the Ubuntu package
(`--force-confmiss`) or copying the packaged file back by hand, then
diffing again to confirm an exact match before moving on.

**On a shared or long-lived host, this would have been a real, silent
corruption of the system's actual font configuration** — not a sandbox
inconvenience. The correct, permanent fix for any future rebuild of this
dependency: **do not run `fontconfig`'s `meson install` at all.** Copy
`libfontconfig.a`, `fontconfig.pc`, and the `fontconfig/` header
directory out of the build tree by hand (`build/libfontconfig.a`, the
source tree's `fontconfig/` include directory, and the generated `.pc`
found under `build/`) instead of trusting the install step to stay
inside `DESTDIR`. `contrib/far2l/deps.lock`'s `fontconfig` entry should
carry this warning verbatim the next time it's touched, so nobody
re-discovers it by overwriting their own `/etc/fonts` again.

Progress so far, this pass, rebuilding into a fresh `/tmp/deps-prefix`:
`zlib` → `bzip2` → `xz` → `libarchive` → `freetype` (pass 1) →
`harfbuzz` → `freetype` (pass 2, `FT_CONFIG_OPTION_USE_HARFBUZZ`
confirmed defined) → `expat` → `fontconfig` (via the manual-copy
workaround above) → `uchardet` (real CMake target name is
`libuchardet`, not `uchardet_static` — found via `cmake --build .
--target help`) → `sdl2` (CMake, not Meson — an earlier guess in this
file was wrong; `-DSDL_STATIC=ON -DSDL_SHARED=OFF
-DCMAKE_POSITION_INDEPENDENT_CODE=ON -DSDL_TEST=OFF`, X11 found and
`dlopen`'d as designed, Wayland not found in this sandbox so left off,
clean install with no host-filesystem side effects unlike fontconfig)
all built and installed. **Every dependency in `deps.lock` is now built
into `/tmp/deps-prefix`.**

**`far2l-sdl`'s CMake configure step now succeeds**, for real, against
this pass's own rebuilt dependencies — cloned far2l fresh and checked out
the pinned `65c29da43971eb1a4f4f43097621cb384a95e04d` commit directly
(git confirms `git hash: 65c29da43`, `Version: 2.8.0-2026-08-18-65c29da43-beta`,
matching the preview-build framing). One new finding: far2l's own
`FindUchardet.cmake` uses `find_library`/`find_path`, not `pkg-config` —
`PKG_CONFIG_PATH` alone (which found every other dependency correctly)
was not enough; needed explicit `-DUCHARDET_LIBRARY=.../libuchardet.a
-DUCHARDET_INCLUDE_DIR=.../include` cache variables, the same pattern
already documented for X11 in `onebin-linux-hybrid.cmake`'s own history.
`-DCOLORER=no` still needed (libxml2 not pinned yet). One harmless
warning: MTP plugin disabled (no `libusb-1.0` dev package in this
sandbox) — not a blocker, not part of this build's scope.

**The build completed, for real — 100%, all plugins, the SDL backend
module, the whole thing.** And the headline result:

```
== /tmp/build-sdl/install/far2l ==
  profile: hybrid (--profile)   class: ELF64 LE x86_64 ET_DYN
  interp:  /lib64/ld-linux-x86-64.so.2
  needed:  ld-linux-x86-64.so.2 libc.so.6 libdl.so.2 libm.so.6 libpthread.so.0
  glibc:   requires GLIBC_2.28, baseline 2.28
  warn  OB0060  ...two build-path findings, already-documented false positives on far2l's own /var/tmp and print-fragment runtime strings...
PASS  Level 1  (0 errors, 2 warnings, 0 infos)
```

**far2l-sdl's main binary passes Level 1 clean** — the graphical file
manager, no toolkit on the target, exactly the claim the top-level README
makes. `needed:` is the allowlist and nothing else; `GLIBC_2.28` exactly,
matching the pinned baseline.

One real, small trap found and fixed along the way: `UCHARDET_INCLUDE_DIR`
must point at the directory *containing* `uchardet.h` directly
(`.../include/uchardet`), not its parent (`.../include`) — far2l's own
`#include <uchardet.h>` is flat, matching the system-package convention
(`/usr/include/uchardet.h`), which our own install layout
(`.../include/uchardet/uchardet.h`) doesn't match by default.

**`far2l_sdl.so` (the dlopen'd SDL backend module) is not yet clean —
two real findings, not yet fixed:**

```
== /tmp/build-sdl/install/far2l_sdl.so ==
  needed:  libc.so.6 libdl.so.2 libm.so.6 libpthread.so.0 libz.so.1
  FAIL  OB0010  not on the allowlist: libz.so.1
  FAIL  OB0036  no PT_INTERP in a file audited as Profile H
FAIL  Level 1  (2 errors, 3 warnings, 12 infos)
```

**Both resolved, same session, small atomic steps:**

1. **`OB0036` was not a bug — it was the wrong audit command.**
   `onebin` already has exactly the right tool for this: `--profile
   module` (`OB_PROFILE_M`), whose entire purpose is auditing a
   `dlopen`'d shared object, and which correctly does **not** require
   `PT_INTERP` (`check_profile_m` in `c_profile.c` — it checks the
   *opposite*, that `PT_INTERP` is *absent*, and emits an informational
   `OB0038` instead). Re-running with `--profile module` instead of
   `--profile hybrid` made `OB0036` disappear immediately, as designed.
   `onebin`'s check logic was correct all along; this session's own
   first audit invocation used the wrong profile for a plugin artifact.
2. **`libz.so.1` was real, and it was not the host's zlib leaking in —
   it was our own.** `zlib`'s CMake build unconditionally produces
   *both* `libz.a` and `libz.so`/`libz.so.1`/`libz.so.1.3.2` regardless
   of `-DBUILD_SHARED_LIBS=OFF`, and both ended up installed side by
   side in `/tmp/deps-prefix/zlib/lib`. The link command for
   `far2l_sdl.so` was entirely correct (no host `-L` paths at all,
   confirmed by inspecting `link.txt` directly) — but with both a `.a`
   and a `.so` present in the *same* `-L` directory, the linker's
   default preference for the dynamic one over the static one silently
   won. Fixed by deleting the accidentally-built shared artifacts from
   `deps-prefix/zlib/lib` (keeping only `libz.a`) and relinking just the
   `far2l_sdl` target.

**Confirmed, for real, after both fixes:**

```
== /tmp/build-sdl/install/far2l ==
  needed:  ld-linux-x86-64.so.2 libc.so.6 libdl.so.2 libm.so.6 libpthread.so.0
PASS  Level 1  (0 errors, 2 warnings, 0 infos)

== /tmp/build-sdl/install/far2l_sdl.so ==  (audited as --profile module)
  needed:  libc.so.6 libdl.so.2 libm.so.6 libpthread.so.0
PASS  Level 1  (0 errors, 3 warnings, 13 infos)
```

**Both far2l-sdl artifacts now pass Level 1 clean.** The two remaining
`OB0060` warnings on each are the already-documented false positives on
far2l's own genuine `/var/tmp` and `/tmp/far2l-*-fragment` *runtime*
strings (not build paths) — not a defect, not blocking, already recorded
earlier in this file's history.

`tools/build-far2l.sh` itself now matches this pass's verified reality,
not the pre-build assumptions it started with. Two real discrepancies
fixed, both confirmed against the actual build rather than guessed:

1. **far2l installs flat**, not into `<prefix>/bin`/`<prefix>/lib/far2l`
   as `04-REFERENCE-far2l.md §3.4` originally documented — confirmed by
   listing the real install tree (`far2l`, `far2l_sdl.so`,
   `far2l_ttyx.broker` directly under the prefix). §3.4 corrected in
   place with a note; `audit_plan_for_config`'s relpaths fixed to match
   (`far2l`, not `bin/far2l`).
2. **`far2l_sdl.so` must be audited with `--profile module`, not
   `--profile hybrid`** — confirmed real: `hybrid` incorrectly demands
   `PT_INTERP`, which a `dlopen`'d shared object never has by design.
   Fixed in the script.

Also scoped `cmake_config_args`'s `sdl` case down to
`-DNETROCKS=no -DMULTIARC=no -DCOLORER=no`, matching exactly what this
pass actually verified (graphics group only) rather than claiming the
full `deps.lock`-stated default (NetRocks/MultiArc/Colorer still `yes`)
works when it hasn't been built that way yet — documented inline as
temporary, not a design decision.

**Verified the corrected script for real**, not just re-generated golden
files: `./tools/build-far2l.sh --config sdl --out /tmp/build-sdl
--audit-only` against this pass's actual build directory reproduces
every finding from the manual audits exactly — all three artifacts show
**0 errors**; the run's overall exit code is 1 only because
`--strict` (called for by `04-REFERENCE-far2l.md §9`'s own policy for
this configuration) promotes the two-or-three already-known `OB0060`
runtime-string warnings on each artifact to failures — expected,
documented behaviour, not a script bug. `make far2l-plan`: all four
golden plans regenerated and matching, shellcheck clean.

far2l-sdl's own build-vs-audit loop is, as of this pass, **complete**:
configured, built, both real findings chased down and fixed, all three
artifacts independently confirmed clean, and the automation script now
reproduces all of it correctly:

```
== /tmp/build-sdl/install/far2l_ttyx.broker ==  (--profile hybrid,
   --allow libX11.so.6,libXi.so.6,libICE.so.6,libSM.so.6,libXext.so.6)
  needed:  libICE.so.6 libSM.so.6 libX11.so.6 libXext.so.6 libXi.so.6
           libc.so.6 libdl.so.2 libpthread.so.0
PASS  Level 1  (0 errors, 1 warning, 3 infos)
```

**All three far2l-sdl artifacts (`far2l`, `far2l_sdl.so`,
`far2l_ttyx.broker`) now audit clean.** The broker's `needed:` is exactly
the six-soname allowlist this project settled on for it back when the
TTYX/libc++ toolchain conflict was fixed — no surprises, confirming that
finding held for this build too. What's left for far2l overall:
`tools/build-far2l.sh` itself has not yet been used for this pass (every
step so far used ad-hoc manual commands, deliberately, to keep each one
independently verifiable) — folding this pass's exact flags back into
the script is the next step.

## Housekeeping: two `deps.lock` files had diverged — consolidated to one

Found while syncing this session's sandbox with `origin/main`:
`onebin/contrib/far2l/deps.lock` (stale, never touched since its first
draft) and `contrib/far2l/deps.lock` (the one all the real archives/
graphics-group work since has gone into) existed side by side and had
diverged completely — different versions, different hashes, some entries
present in only one. `tools/build-far2l.sh` doesn't machine-parse either
file (it only checks `test -d "$DEPS_PREFIX/$dep"` against a hardcoded
per-config list), so this was never a functional bug, only a documentation
consistency one — but a genuinely confusing one for anyone who found the
wrong file first. Deleted the stale `onebin/`-prefixed copy;
`contrib/far2l/deps.lock` (repo root) is now the one and only copy.

## far2l-sdl: CRITICAL CORRECTION -- SDL backend is not in any tagged far2l release; build in progress against a pinned master preview

**Found by checking the real source before linking against it, not by
assumption.** `04-REFERENCE-far2l.md` §6.3's `far2l-sdl` recipe, and
this project's own graphics-group work (FreeType → HarfBuzz →
Fontconfig → SDL2) up to this point, all rested on an unverified premise:
that `-DUSESDL=YES` builds against the pinned `v_2.8.0` tag. **It does
not.** Checked directly: `v_2.8.0`'s source tree has no
`WinPort/src/Backend/SDL` directory and no `USESDL` CMake option at all.
Checked far2l's full git history: the SDL backend was added by commit
`85ec8e14f` ("SDL Backend"), **88 commits after** `v_2.8.0`, on
`master`, and has not been tagged since — `v_2.8.0` is still the latest
tag as of this check.

This is not a new problem for this project — it is the *exact* situation
already documented and handled correctly for `NetRocks-FISHPLUS` in
`04-REFERENCE-far2l.md` §6.2.1: a real, working feature that exists only
on far2l's unstable `master`. The same policy now applies here, and
`04-REFERENCE-far2l.md` §6.3 has been corrected in place with a note
explaining this, rather than silently rewritten: pin a specific `master`
commit for a **preview** build, do not claim it as the official Level-1
`v_2.8.0`-based target, and re-check `git ls-remote --tags` before
promoting it.

**None of the graphics-group work so far is wasted** — FreeType,
HarfBuzz, Fontconfig, and SDL2 are all real, independently-verified
static builds (see the entries below) that far2l-sdl needs regardless of
which far2l commit ends up using them.

Pinned far2l at `master` `65c29da43971eb1a4f4f43097621cb384a95e04d`
(2026-08-18 16:50:05 +0300, "possible fix" — an actively-developed
commit, same day as this pin) in `contrib/far2l/deps.lock`. Also pinned
and built, for real, a dependency this project hadn't needed before:
`uchardet 0.0.8` (character-encoding detection, required whenever
`USEUCD=YES`, far2l's own default) — static via
`onebin-linux-hybrid.cmake`, discovered by far2l's own
`FindUchardet.cmake` through `CMAKE_LIBRARY_PATH`/`CMAKE_INCLUDE_PATH`.
Not yet exercised by its own smoketest.

**`far2l-sdl`'s CMake configure step succeeded**, for real, against this
project's own static SDL2/FreeType/HarfBuzz/Fontconfig (all found
correctly via `pkg-config`) plus the `uchardet` pin above. `-DCOLORER=no`
added (not in §6.3's original recipe) because the Colorer plugin needs
`libxml2`, not yet pinned in this project — a later, separate step, not
a blocker for the SDL backend itself.

**Not yet done, and not to be claimed done until it is:** the actual
`far2l` build (`ninja far2l`) was still running, not yet complete or
verified, when this entry was written. No `onebin audit` has run against
any far2l-sdl artifact yet. Do not write "far2l-sdl builds" anywhere in
this project's docs until that binary exists, has been audited, and —
per this project's own established bar for GUI artifacts — actually
runs.

## Graphics group (step 4 of 4) COMPLETE: SDL2 pinned and verified -- dlopens its own windowing/GPU/audio backends

`sdl2 2.32.10` pinned in `contrib/far2l/deps.lock` — the last library in
the graphics group, and per the top-level README, "the point of the
exercise": far2l-sdl is a graphical file manager with no toolkit on the
target. Built via CMake (`onebin-linux-hybrid.cmake`, SDL2 has its own
upstream CMakeLists.txt), `-DSDL_STATIC=ON -DSDL_SHARED=OFF
-DCMAKE_POSITION_INDEPENDENT_CODE=ON` (PIC needed: `far2l_sdl.so` is a
`dlopen`'d module, `04-REFERENCE-far2l.md` §3.2). Every windowing/GPU/
audio backend left at its upstream default — X11, Wayland, ALSA,
PulseAudio, libudev, D-Bus, IBus — all `dlopen`'d by SDL2 itself, by
design, exactly matching this project's own Layer 3 doctrine ("protocol
first, `dlopen` only where physics demands it"). Nothing in the build
recipe was needed to make that happen; it's how SDL2 already ships.

Verified for real, not just a link check: a smoketest calls
`SDL_Init(SDL_INIT_VIDEO)`, lists every compiled-in video driver (x11,
wayland, offscreen, dummy, evdev — confirms the `dlopen` surface
actually got compiled in), creates a window via the `dummy` driver
(`SDL_VIDEODRIVER=dummy` — no real display in the build sandbox), fills
its surface, and updates it. `needed: libc.so.6 libdl.so.2 libm.so.6
libpthread.so.0` — inside the Profile H six-soname allowlist, nothing
else linked in. `onebin audit --profile hybrid --level 1 --strict`:
PASS, 0 errors, 0 warnings.

One real finding, fixed in `onebin` itself, not just documented: its
own host-contract soname list (`01-SPEC-audit.md` §7.7,
`onebin/src/audit/checks/c_host.c`) only ever covered GPU/audio, the
doctrine's originally-stated scope. The first real audit of an
SDL2-linked binary reported 15 `OB0071` warnings for exactly the
windowing/desktop-integration sonames SDL `dlopen`s by design (X11,
Wayland, xkbcommon, D-Bus, plus an ES1 GLES variant not covered by the
already-listed ES2 name). A real gap, not a false positive — a
`dlopen`-only windowing backend is exactly the Layer 3 pattern this
project's own doctrine describes, the linter just hadn't been taught
the sonames yet. Fixed by extending `KNOWN_HOST_LIBS` and the matching
spec list, with three new tests in `tests/t_checks_host.c`. `make
test`: 268 passed, 0 failed, 3 skipped (was 259). `make coverage`: gate
still passes unchanged (90.89% line / 95.28% branch). This is the third
instance of "the reference application dictates the linter," after the
TTYX broker's `--allow` list and Profile M.

**Graphics group (FreeType → HarfBuzz → Fontconfig → SDL2) is now
complete.** Task 15's three groups (archives, network, graphics) are
all done. What remains before Task 15 itself is complete:
`tools/build-far2l.sh` still doesn't exist — every library in
`deps.lock` so far has been built with ad-hoc manual CMake/Meson
invocations, one at a time, to keep each step independently verifiable
(a deliberate choice recorded repeatedly in this file). The actual
`far2l-sdl` target has not yet been configured or linked against any of
these libraries together — that, and writing the script that
automates what this file's entries did by hand, are the next real
steps.

## Graphics group (step 3 of 4) continued: fontconfig pinned and verified -- reads the HOST's real fonts

`expat 2.8.3` and `fontconfig 2.18.3` pinned in `contrib/far2l/deps.lock`,
built statically via a new Meson native file
(`onebin/toolchain/onebin-linux-hybrid-meson.ini` -- fontconfig and the
planned SDL2 step use Meson, not CMake). Verified: `fc-match`,
`fc-cache`, `fc-list`, `fc-query` and `fc-cat` all pass `onebin audit
--profile hybrid --level 1 --strict` with 0 findings (`needed: libc.so.6
libm.so.6 libpthread.so.0`, `GLIBC_2.28` exactly -- nothing newer than
the baseline). `fc-match` run against the real host's `/etc/fonts` +
`/usr/share/fonts` correctly resolved `"DejaVu Serif"` and `"monospace"`
to real installed font files -- Layer 2 actually exercised.

Also fixed this pass: `zig-cc` silenced `-E` whenever Meson's
`compiler.preprocess()` (used for fontconfig's gperf-template
preprocessing) appended a trailing `-c` — GCC honors `-E` regardless of
a later `-c`, zig's bundled Clang instead honors whichever came last.
Wrapper now strips a redundant `-c` when `-E` is present.

Three real findings, all fixed, in order of discovery:

1. FreeType's installed `.pc` declares a *public* `Requires: zlib`, and
   this project's own zlib build never installed a `zlib.pc` — pkg-config
   silently substituted the **host's** system zlib, linking a dynamic
   `libz.so.1` (GLIBC_2.35) into an otherwise-clean binary. Fixed by
   installing a `zlib.pc` for this project's own static zlib build and
   pointing `PKG_CONFIG_PATH` at it ahead of the system one — still
   needs folding into the zlib step for real once
   `tools/build-far2l.sh` exists.
2. fontconfig bakes `--sysconfdir`/`--datadir`/cache-dir in at *compile*
   time with no runtime override. Building it against this project's own
   sandbox `--prefix` baked in *our* install path instead of the host's
   real `/etc/fonts` — a direct violation of this project's own Layer 2
   doctrine ("fontconfig reads the host's fonts",
   `04-REFERENCE-far2l.md` §3.5/§7.7). Fixed with explicit
   `--sysconfdir=/etc --datadir=/usr/share
   -Dcache-dir=/var/cache/fontconfig`, independent of `--prefix`.
3. **The actual cause of the `GLIBC_2.35`/`hypotf` finding reported in
   an earlier version of this entry**, and it wasn't harfbuzz's fault:
   Meson runs the final link step as a *separate*
   compiler-as-linker-driver invocation using only
   `c_link_args`/`cpp_link_args`, never `c_args`/`cpp_args` — unlike
   CMake, which folds `CMAKE_C_FLAGS_INIT` into the link command too
   (why `onebin-linux-hybrid.cmake` never hit this).
   `onebin-linux-hybrid-meson.ini` had `-target x86_64-linux-gnu.2.28`
   only in `c_args`/`cpp_args`, not in the link args. Without `-target`
   at link time, zig's bundled Clang driver falls back to the *native
   host* target for link-time decisions (sysroot, default crt/libc
   search, multiarch triple) even though every object file was compiled
   correctly for the pinned baseline — so `NEEDED` SONAMEs still looked
   right, but individual undefined symbols (`hypotf`, from
   `libharfbuzz.a`) silently bound against the host's newest available
   versioned symbol instead of the pinned baseline's. Confirmed with a
   controlled A/B: the exact same `libharfbuzz.a` object, linked with
   `-target` present, binds `hypotf` at `GLIBC_2.2.5`; linked without
   it, `GLIBC_2.35` — same relocation, different linker behaviour purely
   from `-target`'s absence. Fixed by adding `-target
   x86_64-linux-gnu.2.28` to `c_link_args`/`cpp_link_args` too. This
   also fixed the previously-unexplained Meson build-tree `RUNPATH`
   auto-injection (`/usr/lib` etc. into `DT_RUNPATH` with no explicit
   `-rpath` flag anywhere) noted in an earlier version of this entry —
   the rebuilt binaries carry no RPATH/RUNPATH at all. `patchelf
   --remove-rpath` is no longer needed anywhere.

Any other Meson-based dependency in this file (SDL2, next) must use the
corrected `onebin-linux-hybrid-meson.ini` — if a `requires GLIBC_x.y`
newer than the baseline shows up again, check
`c_link_args`/`cpp_link_args` for `-target` first.

Next: SDL2, the last graphics-group library and, per the top-level
README, "the point of the exercise."

## Graphics group (step 3 of 4) continued: HarfBuzz pinned, FreeType rebuilt (pass 2) with it enabled

`harfbuzz 14.2.1` pinned in `contrib/far2l/deps.lock`, built statically
against the FreeType-without-HarfBuzz pass from the entry below,
Cairo/Graphite2/GLib/ICU/gobject/introspection and the subset/raster/
vector/GPU sub-libraries all disabled — far2l-sdl only needs core
shaping through `hb-ft`. Verified: a smoketest linked against the
resulting `libharfbuzz.a` shaped real text (`"Static Everywhere"`)
against the same real host font used below into 17 glyphs with
non-zero advances. `onebin audit --profile hybrid --level 1 --strict`:
`needed: libc.so.6 libm.so.6 libpthread.so.0`, 0 errors.

Then closed the circular dependency: rebuilt `freetype 2.14.3` a second
time (still the same pinned version — no `deps.lock` change needed for
FreeType itself) with `-DFT_DISABLE_HARFBUZZ=OFF -DFT_DYNAMIC_HARFBUZZ=OFF
-DFT_REQUIRE_HARFBUZZ=ON` against the HarfBuzz build above. Two real
traps found and fixed doing this, both now documented in `deps.lock`'s
comment so the next person doesn't rediscover them:

1. FreeType's CMake defaults to `FT_DYNAMIC_HARFBUZZ=ON`, which makes it
   `dlopen()` HarfBuzz at runtime instead of linking it — silently
   reintroducing a `dlopen` this project spent real effort ruling out
   elsewhere (see the far2l-tiny/Profile-S entry further down this
   file). Must be turned off explicitly.
2. The `*_INCLUDE_DIR`/`*_LIBRARY` cache-variable pattern this file uses
   for every other dependency doesn't apply to FreeType's HarfBuzz
   discovery: FreeType ships its own `builds/cmake/FindHarfBuzz.cmake`,
   which wants singular `HarfBuzz_INCLUDE_DIR`/`HarfBuzz_LIBRARY` found
   via pkg-config, not the cache variables `find_package(Freetype)` and
   `find_package(ZLIB)` accept elsewhere. Pointing `PKG_CONFIG_PATH` at
   the HarfBuzz build's installed `harfbuzz.pc` is what actually gets it
   found.

Verified the rebuild is not a no-op: `nm` on the resulting
`libfreetype.a` shows 29 undefined `hb_*` symbols (it did not before),
and `FT_CONFIG_OPTION_USE_HARFBUZZ` is now defined in the installed
`ftoption.h`. A second smoketest, forcing the autohinter
(`FT_LOAD_FORCE_AUTOHINT`) — the code path that actually consults
HarfBuzz for OpenType coverage analysis during hinting — on the same
host font rasterised glyph `'A'` to a 16×15 bitmap. `onebin audit
--profile hybrid --level 1 --strict`: `needed: libc.so.6 libm.so.6
libpthread.so.0`, 0 errors.

Next: `Fontconfig`, then `SDL2`.

## Graphics group (step 3 of 4) started: FreeType builds and rasterises a real host font

`freetype 2.14.3` pinned in `contrib/far2l/deps.lock`, static, ZLIB
enabled (using this project's own pinned build), HarfBuzz/PNG/Brotli/
BZip2 support disabled for this first pass — HarfBuzz is next and
depends on FreeType, so the standard way through their circular
dependency is: build FreeType without HarfBuzz first, build HarfBuzz
against that, then rebuild FreeType a second time with HarfBuzz enabled.
PNG/Brotli/BZip2 support (embedded colour bitmaps / WOFF2 / bzip2-
compressed PCF fonts) aren't needed by `far2l-sdl`.

Verified with something stronger than a synthetic round-trip: a
smoketest linked against the resulting `libfreetype.a` opened a real
host font — `/usr/share/fonts/truetype/dejavu/DejaVuSerif-Bold.ttf`,
found 3506 glyphs, rasterised glyph `'A'` to a 20×18 bitmap. This is
Layer 2 (`04-REFERENCE-far2l.md §3.5`/§7.7's "fontconfig reads the
*host's* fonts" point) actually exercised, not just Layer 1 code
compiling. `onebin audit --profile hybrid --level 1 --strict`: `needed:
libc.so.6 libpthread.so.0`, 0 errors.

Next: `HarfBuzz` (against this FreeType build), then a FreeType rebuild
with `-DFT_DISABLE_HARFBUZZ=OFF`, then `Fontconfig`, then `SDL2`.

## Archives group (step 1 of 4) complete: libarchive builds and round-trips tar.gz/tar.bz2/tar.xz/zip against our own pinned zlib/bzip2/xz

`libarchive 3.8.9` pinned in `contrib/far2l/deps.lock`, configured with
CLI tools, its own test suite, and OpenSSL/mbedTLS/Nettle/LZO/expat/
PCRE2POSIX all disabled, pointed explicitly at this project's own static
`zlib`/`bzip2`/`xz` builds via `*_INCLUDE_DIR`/`*_LIBRARY` cache
variables rather than a global search path. A smoketest wrote and read
back `tar.gz`, `tar.bz2`, `tar.xz` and `zip` archives through the
resulting `libarchive.a` (all four round-tripped correctly) and passed
`onebin audit --profile hybrid --level 1 --strict`: `needed: libc.so.6
libpthread.so.0`, 0 errors.

**Archives group is now done**: `zlib` → `bzip2` → `xz` → `libarchive`,
each pinned with a locally-computed hash and each verified against the
real `onebin` binary. Next up is graphics (step 3): `FreeType` →
`HarfBuzz` → `Fontconfig` → `SDL2`. (Step 2, network, needed nothing —
see the entry below.)

## Task 15 order, confirmed: archives (1) → network/FISH (2, already free) → graphics (3) → network/libssh-crypto (4)

[Task 15](#tasks) begins here. Scope: network, archives and graphics — the
third-party libraries `-DNETROCKS`, `-DMULTIARC` and `-DUSESDL` pull in,
per `04-REFERENCE-far2l.md §5`. **Small atomic steps, one pinned+built+
audited library per step** — not one giant deps.lock written from memory
and hoped to compile.

The order below was revised once already this pass and the revision was
confirmed by the person driving this project, so it now stands as
decided, not tentative:

1. **archives** (`zlib` ✅ → `bzip2` ✅ → `xz` ✅ → `libarchive` ✅ — group complete):
   fewest licence traps, and `zlib` is a transitive dependency of nearly
   everything below it anyway, so it is pinned first regardless of
   grouping.
2. **network, and it turns out this needs nothing from deps.lock at
   all.** far2l already ships `NetRocks-SHELL` (classic FISH — shells out
   to the host's `ssh`, needs zero third-party libraries) today, at the
   pinned `v_2.8.0` tag. A newer, faster evolution, `NetRocks-FISHPLUS`
   (designed in `unxed/f4`, also zero third-party libraries), exists on
   `master` and is confirmed, by the person driving this project, to be
   close to landing in the next tagged release — at which point it
   becomes part of the `far2l-tty`/`far2l-sdl` Level-1 targets with no
   further work here. **No upstream proposal needed; nothing to do but
   wait for the tag and re-point the pin.** Until then, `far2l-tty`
   ships real, working, doctrine-clean network access via
   `NetRocks-SHELL` alone — there is no network gap to route around.
   Full detail and both builds' audit results: `04-REFERENCE-far2l.md
   §6.2.1`.
3. **graphics** (`FreeType` ✅ (pass 1, no HarfBuzz yet) → `HarfBuzz` → `Fontconfig` → `SDL2`): no
   crypto/licence entanglement, and `far2l-sdl` is explicitly "the point
   of the exercise" per the top-level README.
4. **network, the hard remainder** (`libssh` + a GPL-compatible crypto
   backend for SFTP/SCP; `libnfs`; `neon` for WebDAV): OpenSSL-dependent
   protocols in NetRocks (FTPS, AWS S3) are explicitly disabled in the
   build recipe via `-DNR_OPENSSL=no -DNR_AWS=no -DCMAKE_DISABLE_FIND_PACKAGE_OpenSSL=TRUE`,
   avoiding GPLv2/Apache-2.0 licence incompatibility and completely preventing
   CMake from discovering host OpenSSL headers. `NetRocks-SFTP.broker` (SFTP/SCP)
   only depends on `libssh` (which on Linux distros can use GnuTLS/libgcrypt/
   mbedTLS — see the correction below: this project pinned mbedTLS, not
   GnuTLS/libgcrypt) and does not include OpenSSL headers directly;
   `NetRocks-SHELL.broker` (SHELL/FISH)
   is completely standalone (PTY-driven `ssh` client). Both build and remain
   available in NetRocks even with OpenSSL fully disabled.

**Verified this pass, for real, not simulated — three archives-group
libraries, each built, linked into its own smoketest, and audited with
the real `onebin` binary (built from this repo's own `onebin/` sources):**

- **`zlib 1.3.2`** — GitHub release asset, hash computed locally. Static
  `.a` via `onebin-linux-hybrid.cmake` (real `zig 0.13.0`).
  `onebin audit --profile hybrid --level 1 --strict`: **PASS, 0 findings**, `needed: libc.so.6` only.
- **`bzip2 1.0.8`** — no CMake support upstream (plain Makefile only), so
  the 7 library `.c` files were compiled directly through the `zig-cc`/`zig-ar` wrappers instead of through a toolchain-file CMake build; same
  Profile H flags. Same clean result.
- **`xz 5.8.3`** (liblzma only, `-DBUILD_SHARED_LIBS=OFF`, no CLI tools)
  — hash computed locally **and cross-checked against upstream's own `doc/SHA256SUMS`**, not just one mirror: this dependency shipped a real
  supply-chain backdoor in versions 5.6.0/5.6.1 (CVE-2024-3094), so
  `deps.lock`'s comment for this line says so, permanently, for whoever
  edits it next. Same clean result.

**Also verified this pass:** `NetRocks-SHELL` (from the `v_2.8.0` pin) and
`NetRocks-FISHPLUS` (from `far2l` `master` pinned at `607459dedacc26c4b4ea981531f16bd281c9a21b`, 2026-08-18) both build clean with
`onebin-linux-hybrid.cmake` and both audit as `needed: libc.so.6
libdl.so.2 libpthread.so.0`, 0 errors — see item 2 above and `04-REFERENCE-far2l.md §6.2.1` for the full writeup, including a minor `onebin` false-positive found along the way (`OB0060` flags far2l's genuine
`/var/tmp` runtime-fallback string in `utils/src/InMy.cpp` as if it were a
leaked build path).

**Not yet done:** `tools/build-far2l.sh` — still just the `04-REFERENCE-far2l.md §10` contract, no script exists, so nothing has
consumed `deps.lock` yet; every build this pass (including `libarchive`,
now also pinned and verified — see the top of this file) used ad-hoc
CMake/manual invocations to keep each step independently verifiable.
Next atomic step: graphics, starting with `FreeType`.

**Toolchain finding, and a correction to this file's own prior entries:**
getting that clean pass required patching `onebin-linux-hybrid.cmake` to
add `-s` to the link flags. Without it, a hybrid build — even one that
already passes `-ffile-prefix-map` for its own source and build
directories, exactly as earlier entries in this file assumed was
sufficient — still FAILs `OB0060` with warnings pointing at paths like
`.../zig/lib/libc/glibc/sysdeps/x86_64/...`. These come from **zig's own
bundled glibc CRT startup objects** (`crti`, `crtn`, `start-*.S`, ...),
which were already compiled with embedded DWARF debug info referencing
*zig's own build tree* when zig itself was built — no
`-ffile-prefix-map` on a downstream invocation can reach object code
that predates it. `-s` (strip symbols and debug info at link time) does
reach it, and is a no-downside default for `CMAKE_BUILD_TYPE=Release`
regardless. Confirmed no regression: `onebin/toolchain/tests/`' existing
`hello_c`/`hello_cxx` smoketest still builds and still audits PASS Level
1 through the patched file.

**Not yet done:** `bzip2`/`xz`/`libarchive` (rest of the archives group),
`tools/build-far2l.sh` itself (still just the four-line contract in
`04-REFERENCE-far2l.md §10`, no script exists), and therefore no far2l
build has actually consumed `deps.lock` yet — today's zlib build used a
standalone smoketest, not far2l's own CMake, to keep this step small and
independently verifiable. Next atomic step: pin and build `bzip2` the
same way (smallest remaining archives-group library), then `xz`, then
attempt `libarchive` against both.

## Toolchain finding: `zig cc -target` does not search host library paths — fixed; a second, unresolved issue found while trying

While attempting to also build `far2l_ttyx.broker` (needs `libX11`/`libXi`,
installed via `apt install libx11-dev libxi-dev` — correctly host-provided
per Profile H, not something to add to `deps.lock`):

**Fixed, and landed in `onebin-linux-hybrid.cmake`:** `zig cc -target
x86_64-linux-gnu.2.28` does not search the host's normal system library
directories by default, even though the target otherwise matches the host
exactly — confirmed directly (`zig cc -target ... -lX11` fails with
`unable to find dynamic system library 'X11'... searched paths: none`).
Worse, `find_package(X11)` fails at CMake *configure* time, before any
compiler flag matters, because it uses `find_library()`/`find_path()`
against `CMAKE_LIBRARY_PATH`/`CMAKE_INCLUDE_PATH` — a separate mechanism
from linker `-L` flags. Fixed by adding both: linker `-L` flags for the
actual link step, and `list(APPEND CMAKE_LIBRARY_PATH/CMAKE_INCLUDE_PATH
...)` for `find_package()` to succeed at all. Without this, Profile H
cannot find *any* host library, which defeats the profile's entire point.

**Found, not yet fixed — and the mechanism is narrower and harder than
first thought.** `find_package(X11)` succeeds via `CMAKE_LIBRARY_PATH`
alone (confirmed: `-- Found X11: /usr/include`), so the fix above is
correct and sufficient for library *discovery*. But compiling the one C++
file that actually uses X11 (`WinPort/src/Backend/TTY/TTYX/TTYX.cpp`)
still fails the same way: `<cerrno> tried including <errno.h> but didn't
find libc++'s <errno.h> header`.

The first hypothesis — that this project's own global `CMAKE_INCLUDE_PATH`
addition was leaking `/usr/include` into every C++ target's compile order —
was tested and **ruled out**: removing that line entirely (it is gone from
`onebin-linux-hybrid.cmake` now; only `CMAKE_LIBRARY_PATH` remains) did not
change the error at all. The real cause is narrower and not ours to fix
from the toolchain file alone: `find_package(X11)` itself adds
`target_include_directories(far2l_ttyx PRIVATE /usr/include)` for that one
target, because X11's headers happen to live directly in `/usr/include`
rather than a scoped subdirectory like `/usr/include/X11` (only `X11/Xlib.h`
etc. do — the include *root* is still the bare, shared `/usr/include`).
Any C++ file needing X11 therefore gets the host's plain `/usr/include`
on its search path, which is exactly what breaks zig's bundled libc++'s
internal header shims (they expect to see their own `<errno.h>`-equivalent
before the host's). C-only files, and `far2l-tty` without `TTYX`, are
unaffected — confirmed both before and after this investigation.

Not solved this session. Candidate directions for later, not attempted:
forcing `-isystem` order so zig's libc++ headers always come first
regardless of what a target adds; or building this specific target against
libstdc++ instead of libc++ (zig supports both); or accepting that `TTYX`
under zig+libc++ is a known limitation and building it with the plain glibc
`gcc` instead, in the same install tree, if CMake allows a per-target
compiler override. Left as a known, precisely diagnosed gap rather than a
rushed fix.

## far2l-tty: built, audited, PASS Level 1, runs — first real end-to-end result

Confirmed for real, not simulated: `far2l` (v_2.8.0, NetRocks/MultiArc/
Colorer/UCD disabled — the third-party deps in `contrib/far2l/deps.lock`
were not yet built for this pass) configured with
`onebin-linux-hybrid.cmake` via the `zig-cc`/`zig-c++` wrappers, built
completely, produced a real dynamically-linked PIE binary. `onebin audit
--profile hybrid --level 1` on the result: `needed:` is exactly
`ld-linux-x86-64.so.2 libc.so.6 libdl.so.2 libm.so.6 libpthread.so.0` —
the allowlist and nothing else — **0 errors, PASS, exit 0**. `far2l
--help` runs and prints real output. `--strict` currently shows FAIL only
because of 10 `OB0060` build-path warnings (this ad-hoc manual cmake
invocation didn't pass `-ffile-prefix-map`, which the toolchain file
normally supplies automatically) — not a structural problem.

This is the project's first confirmed instance of the whole chain working
end to end: `onebin` (the linter) auditing a binary built by
`onebin`'s own toolchain files, of a real, complex, third-party
application, correctly. The install step separately hit a real far2l
CMake bug (`share/far2l/themes` install rule recurses on itself, producing
a `lib/far2l/lib/far2l/lib/far2l/...` path until "File name too long") —
unrelated to Static Everywhere, worth an upstream bug report, did not
block auditing the binary itself.

Next actual step, not yet done: build the third-party deps in
`contrib/far2l/deps.lock` and rerun via `tools/build-far2l.sh` itself
(not the ad-hoc manual `cmake` invocation used for this pass) to get
NetRocks/MultiArc/Colorer/UCD included, and to audit the
`far2l_ttyx.broker` artifact too.

## READ THIS FIRST: do not attempt Profile S (static, no dlopen) for far2l or f4/f4-qt

**And read `04-REFERENCE-far2l.md §2.5` before designing anything else for
far2l.** That section was written after actually reading far2l's source
(something not done before the audit tool was specified and built). It
documents a multi-process system — shells out to `/bin/sh`, forks a
sibling broker binary, **re-executes itself under `sudo`** via symlinks
back to its own binary — and it also corrects an overcorrection from an
earlier revision of this note: **process-invocation via `/bin/sh`'s
POSIX-guaranteed path, or via `$PATH` lookup for `sudo`/clipboard tools,
is not a portability defect.** It is a different, older, much more stable
contract than shared-library linking, and far2l uses it correctly
(`execlp` for `$PATH` lookup, parameterised clipboard commands, no
hardcoded version-specific paths). `onebin` has no way to see this layer
and was never asked to; that is a scope boundary worth a future note
([`FUTURE-IDEAS.md`](./FUTURE-IDEAS.md)), not an urgent gap in
`01-SPEC-audit.md`.

The two findings that **do** stand on their own, independent of any of the
above: `utils/src/InstallPath.cpp:47` calls `dlsym(RTLD_DEFAULT, ...)` in
core code with no NULL check, so a statically linked far2l **segfaults at
startup** rather than merely failing an audit — Profile S is out for a
confirmed reason, not a philosophical one. And NSS
(`getpwuid`/`getpwnam`/`getgrnam`) is load-bearing for the panel's
owner/group columns, not an edge case.


Confirmed by an actual build attempt (far2l-tiny, Profile S, musl,
`--fetch`'d and built to completion): even with every optional plugin and
every GUI backend disabled at cmake configure time, the resulting `far2l`
binary still contains musl's literal `"Dynamic loading not supported"`
dlopen stub string, which `onebin`'s OB0033 check correctly reports as a
FAIL, not a false positive. far2l calls `dlopen` unconditionally somewhere
in code that cannot be disabled by any cmake flag — very likely WinPort's
`LoadLibrary` shim and/or the `resurrect` feature (far2l detaches and
re-attaches to itself across an SSH disconnect, which structurally
requires attaching to a running process — see the user's own description
of this feature). far2l-tiny (Profile S) is **not achievable without a
real upstream patch removing that call**, contradicting
`04-REFERENCE-far2l.md §6.1`'s "no plugins and no GUI, because Profile S
has no dlopen" claim. **Do not re-attempt far2l-tiny as a quick fix. Do
not spend a session rediscovering this.** The correct next steps are
either (a) find and patch the specific dlopen call site upstream, or (b)
retarget far2l-tiny at Profile H instead of Profile S and drop the "Level
1 with zero findings" claim for it, documenting why. far2l's real,
intended targets remain `far2l-tty` and `far2l-sdl` (Profile H, dlopen
explicitly allowed by design) — build and audit those first; they were
never expected to be dlopen-free.

The same risk applies to **f4/f4-qt**: `05-REFERENCE-f4-qt.md §7.7`
already documents that f4's Go core does `dlopen` via `purego`/`goffi`
even under `CGO_ENABLED=0` — this was recorded there as evidence that
Profile S *can* dlopen in principle (amending DESIGN-onebin.md §11 row 1),
but it equally means **f4 itself is a dlopen user, not a dlopen-free
program**. Do not attempt to build f4 or the Qt wrapper (f4-qt) under
Profile S expecting zero dlopen evidence. Target Profile H for both, the
same as far2l.


The live state of this repository. **Updated on every change.** If it disagrees
with any other document, this file is right and the other document is stale —
say so in your report.

Last updated: 2026-08-16.

---

## Milestone

**v0.1 "Prove it"** — `onebin audit` for ELF, plus the far2l reference build.
Roadmap in [DESIGN-onebin.md §10](./DESIGN-onebin.md). Task list in
[00-AGENT-TASK.md §4](./00-AGENT-TASK.md).

## Tasks

| # | Task | State |
|---|---|---|
| 0 | repository hygiene | done |
| 1 | build skeleton, `make`, `make test`, `tests/test.h` | done |
| 2 | `util/buf` — bounds-checked reader | done |
| 3 | `util/ver` — version parsing and comparison | done |
| 4 | `tests/mkelf` — the fixture generator | done |
| 5 | `elf/image` | done |
| 6 | `elf/dynamic`, `elf/verneed`, `elf/symbols` | done |
| 7 | findings, baselines, reporters | done |
| 8 | the checks, **including Profile M** | done |
| 9 | the CLI | done |
| 10 | malformed corpus and fuzzer | done |
| 11 | coverage and lint test | done |
| 12 | self-audit and documentation | done |
| 13 | `tools/audit.sh` learns about modules | done |
| 14 | CMake toolchain files + `zig-*` wrappers | done |
| 15 | `tools/build-far2l.sh` + `contrib/far2l/deps.lock` | **done** — archives+graphics+network groups all wired (openssl/neon/mbedtls/libssh/libnfs), stale in-script comment fixed |
| 16 | `contrib/far2l/UPSTREAM.md` | done |
| 17 | `tools/build-f4-qt.sh` + `contrib/f4-qt/deps.lock` | **done** |
| 18 | Level 1 runtime gate for GUI artifacts (03-TESTPLAN.md) | **done** |

`make test`: 259 passed, 0 failed, 3 skipped. `make test-asan` and `make
test-ubsan` both clean.

`tools/audit.sh` implements the profile ladder as of Task 13, so the shell
stopgap and the C tool will agree once the C tool exists.

`src/elf/elf_const.h` exists as of Task 4 — the generator needed the constants
before the parser did. Task 5 extended it rather than starting it, and added
`src/util/limits.h` (the `ONEBIN_MAX_*` bounds from `01-SPEC-audit.md §11`,
written once for every parsing module to share) and `src/elf/image.h/.c`:
loads `e_ident` and the ELF header, indexes program headers, resolves
PN_XNUM, and implements `ob_image_vaddr_to_offset`. It produces no findings
and does not decide whether `ET_REL`/`ET_CORE` are acceptable — that is an
audit-level decision for Task 8. All 19 cases in `03-TESTPLAN.md §5.5` are
covered by `tests/t_image.c`, plus the worked example from
`02-REFERENCE-elf.md §9` and a regression test for the ELF32 `p_flags`
offset bug the reference calls out by name.

Task 6 added `src/elf/dynamic.h/.c` (walks `PT_DYNAMIC`, both cycle-free by
construction since it is a flat array; the string-table reader
`ob_dynamic_string` implements `02-REFERENCE-elf.md §6`'s `string_at()`
exactly, including the `ONEBIN_MAX_STRING` cap), `src/elf/verneed.h/.c`
(the `.gnu.version_r` walk from `02-REFERENCE-elf.md §7`, both cycle guards,
growable-not-preallocated storage so a crafted `vn_cnt`/`DT_VERNEEDNUM`
can't force a large allocation before a single byte is validated), and
`src/elf/symbols.h/.c` (the three-tier symbol-count fallback from
`01-SPEC-audit.md §6.4` — `DT_HASH`, section headers, `DT_GNU_HASH` — plus
on-demand single-symbol reads rather than materialising up to a million
entries). All three keep Task 5's contract: no findings, no audit-level
decisions, only "what did the bytes say" plus a few structural flags. Every
numbered case in `03-TESTPLAN.md §5.6` (35 items) has a test, split across
`tests/t_dynamic.c`, `tests/t_verneed.c` and `tests/t_symbols.c` by which
module it exercises; items 27-29 turned out to already be safe by
construction from Task 5's `ob_image_vaddr_to_offset` (it never computes
`p_vaddr + p_filesz`), so those are regression tests confirming that rather
than new production code.

## Reference application

[far2l](https://github.com/elfmz/far2l), pinned at `v_2.8.0`. See
[04-REFERENCE-far2l.md](./04-REFERENCE-far2l.md).

| Build | Target | State |
|---|---|---|
| `far2l-tiny` (TTY, no plugins) | Profile S, Level 1 | recipe not written |
| `far2l-tty` (TTY + plugins + X11 helper) | Profile H, Level 1 | recipe not written |
| `far2l-sdl` (SDL graphical backend) | Profile H, Level 1 | recipe not written |
| `far2l-wx` (wxWidgets) | Profile H, Level 0 | expected to fail Level 1, by design |

**`far2l-sdl` is the point of the exercise.** A graphical file manager that needs
no toolkit on the target is the demonstration; the terminal builds are the easy
half. Do not let it slip to a later milestone.

## The Qt reference application

[f4-qt](https://github.com/Zoinen/f4/tree/zoin), pinned at `1a03511`. See
[05-REFERENCE-f4-qt.md](./05-REFERENCE-f4-qt.md). It ships today; what we owe is
a build we can reproduce and audit ourselves.

| Build | Target | State |
|---|---|---|
| `f4-qt-linux` (static Qt host inside the Go launcher) | Profile H 2.27, Level 1 | **blocked**: private ZoinGallery submodule (§7.8) |
| `f4-qt-windows` | Profile H, Level 1 | recipe not written |
| `f4-qt-macos` | signed bundle, Level 2 | out of scope for v0.1 |

Task 7 added `src/util/str.c` (`01-SPEC-audit.md §9.3` sanitisation),
`src/util/json.c` (a plain growable buffer plus JSON string escaping —
deliberately not a generic streaming builder; `audit/report_json.c`
hand-assembles the fixed §9.2 schema directly), `src/util/vec.c` (growable
array of fixed-size elements, backing the finding list and the baseline's
fingerprint list), `src/audit/finding.c` (the finding record, sort/dedup,
severity-name mapping), `src/audit/baseline.c` (load/apply/write, §9.4),
and `src/audit/report.{h,c,_text.c,_json.c}` (the struct tying identity +
ELF facts + findings + baseline together, and the two renderers). Several
ambiguities §9's prose leaves open are resolved and documented in
`onebin/NOTES.md` — notably that `OB_SEV_OK` findings are always shown in
text output (unlike `OB_SEV_INFO`, which needs `--verbose`), matching §9.1's
own worked example, which this project's golden fixture for Profile H
reproduces byte-for-byte. Six golden fixtures exist under
`onebin/tests/golden/` (JSON and text each), covering hybrid/static/module
profiles, a baseline suppression, a length-≥4 array, and sanitised hostile
strings end to end.

Task 8 (the checks) is complete: `elf/strings.c` (the whole-buffer
scanner, §6.5), a profile-detection function added to `elf/image.c`
(`ob_profile_detect` — kept there rather than in a new module so it doesn't
need to depend on `elf/dynamic.h`, which already depends on `elf/image.h`;
takes primitive facts instead of the structs directly), all seven check
families (`c_needed`, `c_glibc`, `c_profile`, `c_rpath`, `c_harden`,
`c_hygiene`, `c_host`), `c_meta.c` (§7.8, level-3-only, the only check that
touches the filesystem beyond the audited file), `audit/checks_common.c`
(`ob_checks_resolve_profile`), and `audit/audit.c` (orchestration: opens
and reads the file — the only layer that does — maps parse failures to the
fatal `OB0001-3`/`OB0090-93` findings, and populates every descriptive
field on `ob_report` before running every check).

Task 9 (the CLI) is complete: `src/main.c` parses the full grammar from
`01-SPEC-audit.md §5.2` — `--profile`, `--glibc-max`, `--level`, `--allow`
(repeatable), `--baseline`, `--write-baseline`, `--format`, `--strict`,
`--quiet`, `--verbose`, `--no-color`, `--max-file` (accepted and
validated, not yet enforced — see `onebin/NOTES.md`) — plus `--` and
multi-file worst-exit-code aggregation. `--write-baseline` aggregates
findings across every file given into one sorted, deduped baseline.
**`onebin` is a real, runnable tool**: `onebin audit /bin/ls` works end to
end against real system binaries, not just synthetic fixtures.

Task 10 (the malformed corpus and the fuzzer) is complete. The 35-case
malformed corpus from `03-TESTPLAN.md §5.6` already existed, spread across
`tests/t_dynamic.c`, `tests/t_verneed.c` and `tests/t_symbols.c` since
Task 6 — no separate `t_malformed.c` was written; see `onebin/NOTES.md`
for why duplicating them would have cost more than it protected.
`tests/fuzz.c` is new: the exact xorshift PRNG the spec requires, a
9-entry seed corpus (five presets plus four manual ELF32/64 × LE/BE
variants — mkelf's presets aren't class/endian-parameterised, see
`onebin/NOTES.md`), all six mutation strategies, `alarm()`-based timeout
capture, and a crash dump with a reproduction command on any signal. Runs
entirely in-process against the parsing+checks pipeline, not the built
binary, so ASan/UBSan see everything.

`make fuzz FUZZ_ITERS=200000`, plus additional runs up to 100000
iterations each at four other seeds, all completed with **zero crashes,
zero timeouts, and zero sanitizer reports**.

Task 11 is complete: both coverage and lint. `make coverage` found and
fixed a real bug on its first real run: the test harness forks a child
per test for crash isolation, and every child terminates via `_exit()`,
which bypasses gcov's atexit-based flush — so every test was reporting 0%
coverage despite passing. Fixed with an explicit `__gcov_dump()` before
each `_exit()`, guarded so the symbol never appears in non-instrumented
builds. `make coverage` now runs `tools/coverage-gate.sh`, which
aggregates line/branch percentages across every `src/` file and **exits
non-zero below threshold**. Current result: **90.89% line / 95.28%
branch** coverage (gate: 90%/85%), with `util/buf.c` and `util/ver.c`
both at 100% as required. One test (`symbols_count_via_section_headers`)
is a known, commented `SKIP()` rather than a rushed fix — see
`onebin/NOTES.md`.

`tests/t_lint.c` implements all ten architecture rules from
`03-TESTPLAN.md §5.7` and found four real issues on its first run: raw
buffer indexing in `elf/strings.c` (fixed to go through `ob_rd8`), a
`strcat()` call in `util/str.c` (rule 5 bans the function outright —
replaced with a bounds-checked `memcpy`), two unchecked `malloc()` calls
in `src/main.c` (fixed), and two finding IDs (`OB0004`, `OB0005`)
declared in the spec's registry but never emitted anywhere — both are now
implemented for real in `audit/audit.c` rather than exempted. `OB0035`
remains the one deliberate, allowlisted exception (see `onebin/NOTES.md`).


Task 14 is also complete: `onebin/toolchain/onebin-linux-static.cmake`
(Profile S), `onebin-linux-hybrid.cmake` (Profile H), and the four
`zig-cc`/`zig-c++`/`zig-ar`/`zig-ranlib` wrapper scripts (all shellcheck-
clean). Verified against a real `zig 0.13.0`, not just parsed: `cmake`
configures and builds a two-file C+C++ smoketest via each toolchain file
in `onebin/toolchain/tests/`, and **`onebin audit` reports PASS Level 1
for both resulting binaries**. Building for real turned up two corrections
`DESIGN-onebin.md §8`'s sketch needed: zig silently ignores a bare
`-static-pie` for musl targets (the working combination is `-fPIE -pie
-static`), and zig's linker rejects `-Wl,--exclude-libs,ALL` outright —
omitted under zig with a `message(STATUS ...)` explaining why, since it
was already documented as a default rather than a hard requirement.
Full writeup in `onebin/NOTES.md`.

Task 12 is also complete: `onebin/README.md` and `tools/selftest.sh`.
`make selftest` builds `onebin` itself with Profile S flags (`musl-gcc
-static-pie`, falling back to `cc -static-pie` against glibc, or a
clearly-worded `SKIP` if neither links) and audits the result. The report
is genuinely not a clean PASS — `onebin`'s own source contains, as literal
detection needles, several of the exact strings its own checks look for
(`"dlopen"`, `"/etc/nsswitch.conf"`, `"libnss_"`, `"libgcc_s.so.1"`,
`"libstdc++.so.6"`), so the audited binary necessarily contains them too.
`selftest.sh` prints the real result and then explains why, rather than
faking a clean pass or special-casing its own build — see
`onebin/NOTES.md` for the full writeup, including a small concrete
musl-vs-glibc comparison found along the way (glibc's static iconv/gconv
machinery embeds extra host-toolchain paths musl doesn't have).

## Open design questions

| # | Question | State |
|---|---|---|
| 1 | **Profile D — carry your own loader.** Profile S forbids `dlopen`, which rules out plugins, GPU and audio, i.e. most real programs. Proposal in [DESIGN-onebin.md §13](./DESIGN-onebin.md). | **decided (§13.6): support both `memfd_create`+`dlopen` and a carried loader, tried in that order, graceful degradation to "feature unavailable" if both fail.** Not scheduled, no code |
| 8 | **Profile U — True Universal Binary (Direct DRM uAPI + Vulkan dma-buf + SCM_RIGHTS Helper).** Unified single-binary model combining static musl execution with hardware acceleration via kernel DRM ioctls, dma-buf fd passing, and out-of-process host driver helper. | Drafted in [FUTURE-IDEAS.md §1.10](./FUTURE-IDEAS.md#110-what-profile-u-would-look-like-if-it-existed): §1.10.1 the in-process engine, §1.10.2 the re-cut around the boundary, §1.10.3 the wire-protocol doctrine. |
| 2 | One file vs. one file plus modules for Profile H. Current answer: ship the modules beside the binary and say so; `onebin pack` closes the gap in v0.4. | decided for v0.1 |
| 3 | `memfd_create` + `dlopen("/proc/self/fd/N")` as a true single-file route. | **decided: this is the first-attempted route in §13.6's graceful-degradation order**, not a competing alternative to Profile D — see DESIGN §13.6 |
| 6 | **Should `contrib/`'s per-project build recipes generalise into a shared, Homebrew-formula-like database** once far2l's and f4-qt's own entries exist? [FUTURE-IDEAS.md §2](./FUTURE-IDEAS.md). | **not a milestone.** Revisit after Tasks 15+ and a third candidate recipe exist |
| 5 | **Does Level 1 need a runtime gate for GUI applications?** f4-qt's CI proves a static Qt binary can pass every static check and still fail to start. | **yes, provisionally** — 05-REFERENCE-f4-qt.md §7.4. Needs writing into 03-TESTPLAN.md |
| 4 | **One image per architecture instead of one per OS.** Speculation, not a plan: [FUTURE-IDEAS.md §1](./FUTURE-IDEAS.md). | **not a milestone.** Only §1.11 touches v0.1, and everything in it is free |
| 7 | **`libwinescape` — raw syscalls from a Windows binary under Wine, bypassing Win32.** A live experiment (not this repository's) already confirms the guest-cooperates premise §1.5 argues by analogy. [FUTURE-IDEAS.md §3](./FUTURE-IDEAS.md). | **not this project's code.** Design and task spec live in `unxed/f4`'s `WINE.md`; tracked here only as a cross-reference |

## Decisions taken since the documents were first written

- `--exclude-libs,ALL` is opt-out, not a rule — it breaks any application that
  exports an ABI to its own plugins.
- Profile M exists: modules get audited, with the executable-only checks skipped.
- Layer 3 includes the process, not just the library. Shelling out to the host's
  `7z` is correct behaviour.
- Profile order of preference is **H first, D when H cannot reach far enough
  back, S as a deliberate niche** — not "S is the ideal and H is the compromise".
- **`PT_INTERP` does not expand `$ORIGIN`** — the kernel opens it literally, so
  a carried loader can only be named absolutely or relative to the CWD. Found
  by reading `far2l-portable`; it constrains Profile D and validates
  `DESIGN-onebin.md §13`'s choice to `execve` the loader explicitly rather
  than set an interpreter path. `04-REFERENCE-far2l.md §12`.
- **The baseline applies to every object in the artifact, not to the final
  link.** Binary package caches (Conan, vcpkg, prebuilt tarballs) do not encode
  the glibc a package was built against, so a cache hit silently raises the
  baseline and nothing fails. From f4-qt, §7.3.
- **Profile S can `dlopen`** if the language runtime carries its own FFI
  machinery — `DESIGN-onebin.md §11` row 1 is a statement about the C toolchain,
  not about static binaries. From f4-qt, §7.7.
- **"One binary" is a claim about the downloaded artifact**, not about the
  process table or the number of executables inside it. From f4-qt, §7.1.
- **`~/Apps` is the install location**, and Override Mode installs there rather
  than into `~/.local/share`. The recovery path for a broken self-update is "the
  user deletes a directory they can see", which only works if they can see it.
  Manifesto §7.2, `DESIGN-onebin.md` §4 and §5.7.

## Update: `-stdlib=libstdc++` ruled out for the TTYX/libc++ conflict

Tried directly, outside CMake: `zig c++ -stdlib=libstdc++` silently
ignores the flag (`argument unused during compilation`) and always uses
its own bundled libc++ regardless — confirmed with an isolated invocation,
not a guess. The likely real fix is that `find_package(X11)`'s
`target_include_directories` uses plain `-I` (high priority) rather than
`-isystem` for `/usr/include` — upstream CMake/far2l's own `FindX11.cmake`
usage, not something fixable from this project's toolchain file alone.
Stopping here for this session rather than patching upstream modules under
time pressure. **`far2l-tty` without `TTYX` remains a clean, confirmed
PASS Level 1** — that result stands unaffected by any of this.

## Update: the TTYX/libc++ conflict is FIXED, and `far2l_ttyx.broker` now builds

Found the exact mechanism by reading `WinPort/src/Backend/TTY/TTYX/CMakeLists.txt`
directly: it calls plain `include_directories(${X11_INCLUDE_DIR})`, not
`target_include_directories(... SYSTEM ...)`, giving `/usr/include` `-I`
(high) priority instead of `-isystem` (low) — confirmed as the exact cause
by an isolated `zig c++` reproduction, and confirmed the fix by the same
isolated method before touching CMake again: adding `/usr/include` back in
as `-isystem` (in *either* flag order relative to the offending `-I`)
restores libc++'s priority and compiles cleanly.

Added `-isystem /usr/include` to `onebin-linux-hybrid.cmake`'s common
flags. **Real result: `far2l_ttyx.broker` now builds completely** — a
real, dynamically-linked PIE ELF, `TTYX.cpp` compiles without error. This
does not touch upstream far2l at all; it is a toolchain-file-only fix.

Audited for real: `onebin audit --profile hybrid --level 1 --allow
libX11.so.6 --allow libXi.so.6` on the broker gives `needed: libICE.so.6
libSM.so.6 libX11.so.6 libXext.so.6 libXi.so.6 libc.so.6 libdl.so.2
libpthread.so.0` — **3 errors**: `libICE.so.6`, `libSM.so.6`,
`libXext.so.6` are not on the allowlist. This is a genuine, useful
finding, not a toolchain problem: `04-REFERENCE-far2l.md §9`'s planned
`--allow` list (`libX11.so.6`, `libXi.so.6`) is **incomplete** — linking
against real X11 transitively pulls in ICE/SM (session management) and
Xext, which the reference document didn't anticipate. `04-REFERENCE-far2l.md
§9`'s table needs updating to add these three to the broker's `--allow`
list, and `tools/build-far2l.sh`'s `audit_plan_for_config` for `tty`/`sdl`
needs the same three sonames added. Not yet done — the next small step.
