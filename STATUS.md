# STATUS

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
| 8 | the checks, **including Profile M** | **next** |
| 9 | the CLI | not started |
| 10 | malformed corpus and fuzzer | not started |
| 11 | coverage and lint test | not started |
| 12 | self-audit and documentation | not started |
| 13 | `tools/audit.sh` learns about modules | done |
| 14 | CMake toolchain files + `zig-*` wrappers | not started |
| 15 | `tools/build-far2l.sh` + `contrib/far2l/deps.lock` | not started |
| 16 | `contrib/far2l/UPSTREAM.md` | not started |
| 17 | `tools/build-f4-qt.sh` + `contrib/f4-qt/deps.lock` | not started |
| 18 | Level 1 runtime gate for GUI artifacts (03-TESTPLAN.md) | not started |

`make test`: 126 passed, 0 failed, 2 skipped. `make test-asan` and `make
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

## Open design questions

| # | Question | State |
|---|---|---|
| 1 | **Profile D — carry your own loader.** Profile S forbids `dlopen`, which rules out plugins, GPU and audio, i.e. most real programs. Proposal in [DESIGN-onebin.md §13](./DESIGN-onebin.md). | proposal written, **not decided**, no code |
| 2 | One file vs. one file plus modules for Profile H. Current answer: ship the modules beside the binary and say so; `onebin pack` closes the gap in v0.4. | decided for v0.1 |
| 3 | `memfd_create` + `dlopen("/proc/self/fd/N")` as a true single-file route. | open, see DESIGN §11 row 14 |
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
