# STATUS

## READ THIS FIRST: do not attempt Profile S (static, no dlopen) for far2l or f4/f4-qt

**And read `04-REFERENCE-far2l.md §2.5` before designing anything else for
far2l.** That section was written after actually reading far2l's source
(something not done before the audit tool was specified and built), and it
documents that far2l is a multi-process system that shells out to
`/bin/sh`, forks a separate broker binary, and **re-executes itself under
`sudo`** — plus that `utils/src/InstallPath.cpp` calls
`dlsym(RTLD_DEFAULT, ...)` in core code without a NULL check, so a static
far2l segfaults at startup rather than merely failing an audit.

It also names a real gap in this project's own premise: the host contract
and `onebin`'s whole notion of "dependencies" cover **shared libraries**,
while far2l's actual host dependencies are **executables** (`/bin/sh`,
`sudo`, `xclip`, its own broker). A statically linked far2l could score a
perfect Level 1 and still be unable to run a command. "Zero dependencies"
was being measured in the wrong units — that is a gap in
`01-SPEC-audit.md`, and it should be addressed before any further
conformance-level work.


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
| 15 | `tools/build-far2l.sh` + `contrib/far2l/deps.lock` | **next** |
| 15 | `tools/build-far2l.sh` + `contrib/far2l/deps.lock` | not started |
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
