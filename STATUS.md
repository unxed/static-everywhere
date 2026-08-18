# STATUS

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
   CMake from discovering host OpenSSL headers. Remote server access is provided
   licence-cleanly by `NetRocks-SHELL` / `NetRocks-FISHPLUS`.

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
| 15 | `tools/build-far2l.sh` + `contrib/far2l/deps.lock` | **in progress** |
| 16 | `contrib/far2l/UPSTREAM.md` | not started |
| 17 | `tools/build-f4-qt.sh` + `contrib/f4-qt/deps.lock` | not started |
| 18 | Level 1 runtime gate for GUI artifacts (03-TESTPLAN.md) | not started |

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
| 1 | **Profile D — carry your own loader.** Profile S forbids `dlopen`, which rules out plugins, GPU and audio, i.e. most real programs. Proposal in [DESIGN-onebin.md §13](./DESIGN-onebin.md). | proposal written, **not decided**, no code |
| 2 | One file vs. one file plus modules for Profile H. Current answer: ship the modules beside the binary and say so; `onebin pack` closes the gap in v0.4. | decided for v0.1 |
| 3 | `memfd_create` + `dlopen("/proc/self/fd/N")` as a true single-file route. | open, see DESIGN §11 row 14 |
| 6 | **Should `contrib/`'s per-project build recipes generalise into a shared, Homebrew-formula-like database** once far2l's and f4-qt's own entries exist? [FUTURE-IDEAS.md §2](./FUTURE-IDEAS.md). | **not a milestone.** Revisit after Tasks 15+ and a third candidate recipe exist |
| 5 | **Does Level 1 need a runtime gate for GUI applications?** f4-qt's CI proves a static Qt binary can pass every static check and still fail to start. | **yes, provisionally** — 05-REFERENCE-f4-qt.md §7.4. Needs writing into 03-TESTPLAN.md |
| 4 | **One image per architecture instead of one per OS.** Speculation, not a plan: [FUTURE-IDEAS.md §1](./FUTURE-IDEAS.md). | **not a milestone.** Only §1.11 touches v0.1, and everything in it is free |

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
