# AGENT TASK — implement `onebin audit` v0.1 and the far2l reference build

**Read this file completely before doing anything. Then read `02-REFERENCE-elf.md` completely. Then read `01-SPEC-audit.md` and `03-TESTPLAN.md`. Only then write code.** Before you start Task 13, read `04-REFERENCE-far2l.md` completely as well.

You are implementing v0.1 of the `onebin` toolkit described in `DESIGN-onebin.md` of this repository. v0.1 is two things:

1. **A conformance linter for ELF binaries** — Tasks 0–12. One command-line tool, no library, nothing else.
2. **The build recipe for the reference application** — Tasks 13–16. Shell and CMake, no C. This is what makes the linter worth having: `04-REFERENCE-far2l.md` explains why far2l, and contains every fact about it that you will need.

Do them in that order. Tasks 13–16 are smaller than they look and they are not optional.

---

## 0. Operating rules — these are absolute

1. **You have no internet access.** You will not download anything, install anything, `git clone` anything, or `pip install` anything. Every constant, structure layout, and algorithm you need is written out in `02-REFERENCE-elf.md`; every fact about far2l is written out in `04-REFERENCE-far2l.md`. If something you need is not there, it is out of scope — do not guess it.

   This applies with full force to far2l. **You cannot clone it, build it, or look at its sources**, and you must not pretend otherwise. You are writing the recipe, not running it. Anything in your training data about far2l that contradicts `04-REFERENCE-far2l.md` is older than that document — the document wins. Do not invent option names, file names, dependency versions, or upstream tags.
2. **No third-party dependencies. Ever.** The tool links against the C standard library and nothing else. No JSON library, no test framework, no argument parser, no `libelf`, no `libbfd`. If you find yourself wanting one, write the 80 lines yourself.
3. **Do not `#include <elf.h>`.** It may be absent, and its contents vary between libcs. Define every constant yourself, in `src/elf/elf_const.h`, copying the values from `02-REFERENCE-elf.md`. This is not optional.
4. **Never cast a struct onto file bytes.** Do not do `Elf64_Ehdr *eh = (Elf64_Ehdr *)buf;`. That is unaligned access, it is undefined behaviour, and it breaks on big-endian and on ELF32-vs-ELF64. Read every field individually through the bounds-checked byte readers specified in `01-SPEC-audit.md §4`. There is a lint test that will fail your build if you violate this.
5. **Never invent an ELF constant, offset, or size.** If `02-REFERENCE-elf.md` does not list it, you do not need it.
6. **Do not modify** `STATIC-EVERYWHERE.md`, `DESIGN-onebin.md`, `CONFORMING.md`, or `04-REFERENCE-far2l.md`. Task 0 lists the only edits you are allowed to make to existing files. If you find something wrong in any of them, write it in `onebin/NOTES.md` and report it — that is what rule 8 and §7 item 5 are for.
7. **Do not write the rest of the toolkit.** No `libonebin`, no `ob_host_*`, no `ob_update_*`, no `ob_desktop_*`, no PE support, no Mach-O support, no signing, no `onebin pack`. Those are v0.2+. If you have spare effort, spend it on tests.

   Likewise, do not *fork* far2l, vendor it, reimplement parts of it, or write patches against sources you cannot see. Tasks 13–16 produce a build recipe and nothing else.
8. **When the spec is ambiguous**, check `01-SPEC-audit.md §12 "Ambiguity resolutions"` first. If your case is not listed, choose the behaviour that **fails closed** (report a problem rather than stay silent), implement it, and add a one-line entry to `onebin/NOTES.md` describing the decision. Never silently pick a behaviour.
9. **Run `make test` after every task.** A task is not done until the full suite passes. Never move to the next task with a red suite.
10. **Do not weaken a test to make it pass.** If a test fails, the code is wrong until you have proven otherwise in writing. If a test is genuinely wrong, fix it *and* say so in `onebin/NOTES.md`.
11. **Determinism is a hard requirement.** No timestamps, no hostnames, no absolute paths, no hash-map iteration order, no `rand()` without a fixed seed, no locale dependence (`LC_ALL=C` everywhere) in any output. Running the tool twice on the same input must produce byte-identical output.

---

## 1. What you are building, in one paragraph

A single static C11 binary called `onebin`, whose only subcommand in v0.1 is `audit`. It reads an ELF file from disk into memory, parses its program headers and dynamic section without using section headers where avoidable, and reports whether the binary conforms to the Static Everywhere manifesto: which shared libraries it needs, what the highest glibc symbol version it requires is, whether hardening flags are present, whether build-machine paths leaked into it, and which host-contract libraries it appears to `dlopen`. It prints a human-readable report or a stable JSON document, and it exits 0 on pass, 1 on failure, 2 on a usage or I/O error.

It must be able to audit **itself** and pass. It must also audit a *set* of files in one invocation — an executable plus the modules it loads — because that is the shape of every real application, including the reference one.

---

## 2. Repository state you are starting from

```
static-everywhere/
├── README.md              (do not rewrite; Task 0 allows two small fixes)
├── STATIC-EVERYWHERE.md   (do not touch)
├── DESIGN-onebin.md       (do not touch)
├── CONFORMING.md          (do not touch)
├── LICENSE                (CC0, for the documents)
└── audit.sh               (the shell stopgap; Task 0 moves it)
```

---

## 3. Repository state you must end with

```
static-everywhere/
├── README.md
├── STATIC-EVERYWHERE.md
├── DESIGN-onebin.md
├── CONFORMING.md
├── 04-REFERENCE-far2l.md
├── LICENSE                        CC0 — applies to the .md documents
├── tools/
│   ├── audit.sh                   moved here in Task 0
│   └── build-far2l.sh             Task 15
├── contrib/
│   └── far2l/
│       ├── deps.lock              Task 15 — name version sha256 url, one per line
│       ├── UPSTREAM.md            Task 16 — changes far2l would need, as prose
│       └── patches/               Task 16 — empty is the correct answer
└── onebin/
    ├── LICENSE                    MIT — applies to everything under onebin/
    ├── README.md                  build + usage, ~100 lines, written in Task 12
    ├── NOTES.md                   your decision log (see rule 8)
    ├── Makefile                   POSIX make; see §5
    ├── include/
    │   └── onebin/
    │       └── audit.h            public-ish API used by the CLI and by tests
    ├── src/
    │   ├── main.c                 argv parsing, subcommand dispatch, exit codes
    │   ├── util/
    │   │   ├── buf.c/.h           bounds-checked byte reader (the ONLY place
    │   │   │                      that touches raw file bytes)
    │   │   ├── str.c/.h           safe string ops, ASCII sanitiser
    │   │   ├── vec.c/.h           growable array of pointers
    │   │   ├── json.c/.h          hand-written JSON writer
    │   │   └── ver.c/.h           symbol-version string parser + comparator
    │   ├── elf/
    │   │   ├── elf_const.h        every constant, copied from the reference
    │   │   ├── image.c/.h         load file, identify, index PT_* segments
    │   │   ├── dynamic.c/.h       PT_DYNAMIC walk, DT_* extraction, strtab
    │   │   ├── verneed.c/.h       .gnu.version_r walk
    │   │   ├── symbols.c/.h       dynsym + versym, best-effort
    │   │   └── strings.c/.h       string scan over the file image
    │   └── audit/
    │       ├── audit.c/.h         orchestration: run all checks, collect findings
    │       ├── finding.c/.h       finding record, severity, fingerprint
    │       ├── baseline.c/.h      load/apply/write baseline files
    │       ├── report_text.c      human output
    │       ├── report_json.c      JSON output
    │       └── checks/
    │           ├── c_needed.c
    │           ├── c_glibc.c
    │           ├── c_profile.c
    │           ├── c_rpath.c
    │           ├── c_harden.c
    │           ├── c_hygiene.c
    │           └── c_host.c
    ├── toolchain/                 Task 14
    │   ├── onebin-linux-static.cmake
    │   ├── onebin-linux-hybrid.cmake
    │   ├── zig-cc                 wrapper scripts, see Task 14
    │   ├── zig-c++
    │   ├── zig-ar
    │   └── zig-ranlib
    └── tests/
        ├── test.h                 the tiny harness (see 03-TESTPLAN.md §2)
        ├── mkelf.c/.h             ELF fixture generator (03-TESTPLAN.md §3)
        ├── t_buf.c
        ├── t_ver.c
        ├── t_json.c
        ├── t_str.c
        ├── t_mkelf.c              the generator's own round-trip tests
        ├── t_image.c
        ├── t_dynamic.c
        ├── t_verneed.c
        ├── t_symbols.c
        ├── t_checks_needed.c
        ├── t_checks_glibc.c
        ├── t_checks_profile.c
        ├── t_checks_rpath.c
        ├── t_checks_harden.c
        ├── t_checks_hygiene.c
        ├── t_checks_host.c
        ├── t_checks_module.c      Profile M + the reference-application shapes
        ├── t_baseline.c
        ├── t_report.c
        ├── t_cli.c                spawns the built binary, checks exit codes
        ├── t_malformed.c          the malformed-input corpus
        ├── t_lint.c               source-level architecture rules
        ├── fuzz.c                 deterministic mutation fuzzer
        ├── t_far2l_plan.c         Task 15 — golden test for --print-plan
        └── golden/                *.json expected outputs, and far2l-*.plan
```

You may add files. You may not remove any of the above.

---

## 4. Ordered tasks

Do these **in order**. Each has a hard acceptance gate. Do not start task N+1 until task N's gate passes.

### Task 0 — repository hygiene (do this first, it is 5 minutes)

The repository currently contradicts itself. Fix exactly these things and nothing else:

- Add `onebin/LICENSE` containing the MIT licence text, copyright `The Static Everywhere contributors`, year `2026`. `README.md` and `DESIGN-onebin.md` both promise MIT/Apache-2.0 for code while the only LICENSE in the tree is CC0. **Write the MIT text from memory; it is short and you know it.** Do not attempt to fetch it.
- In `README.md`, change the "Status" section's "No code has been written yet" sentence to reflect what exists once you are done. Change nothing else in that file.
- Create `onebin/NOTES.md` with a heading and an empty "Decisions" list.

**Gate:** every relative link in `README.md` resolves to a file that exists. Verify by script, not by eye.

### Task 1 — build skeleton

`onebin/Makefile`, a `main.c` that prints `onebin 0.1.0` for `--version` and a usage block for `--help`, and the test harness `tests/test.h` with one trivially passing test.

**Gate:** `make && make test` succeeds. `./build/onebin --version` prints exactly `onebin 0.1.0\n`. `make clean` leaves the tree byte-identical to before the build (verify with a checksum listing).

### Task 2 — `util/buf` — the bounds-checked reader

The single most important file in the project. Every byte of every input file is read through it. See `01-SPEC-audit.md §4` for the exact API and semantics.

**Gate:** `t_buf.c` passes with 100% line and branch coverage of `buf.c`. `03-TESTPLAN.md §5.1` lists the mandatory cases; all of them must be present.

### Task 3 — `util/ver` — version string parsing and comparison

`GLIBC_2.28`, `GLIBCXX_3.4.29`, `GLIBC_PRIVATE`, `GLIBC_ABI_DT_RELR`. Getting `2.9 < 2.10` right is the point of this file.

**Gate:** `t_ver.c` passes, 100% line and branch coverage of `ver.c`, and every row of the table in `01-SPEC-audit.md §6.2` is a test case.

### Task 4 — `tests/mkelf` — the fixture generator

You cannot test an ELF parser without ELF files, and you cannot download any. Build them. Full API and layout contract in `03-TESTPLAN.md §3`.

**Gate:** `t_mkelf.c` passes. The generator can emit ELF32/ELF64 × little/big-endian × exec/dyn, and `t_mkelf.c` verifies the emitted bytes at hand-computed offsets for at least one file of each of those eight combinations.

### Task 5 — `elf/image` — load and identify

Read the file into memory (never `mmap` — see `01-SPEC-audit.md §3.2`), validate `e_ident`, read the ELF header, index the program headers, build the vaddr→offset translation table from `PT_LOAD`.

**Gate:** `t_image.c` passes. Every malformed-header case in `03-TESTPLAN.md §5.5` returns a clean error, never a crash and never a hang.

### Task 6 — `elf/dynamic`, `elf/verneed`, `elf/symbols`

Walk `PT_DYNAMIC`; extract `DT_NEEDED`, `DT_RPATH`, `DT_RUNPATH`, `DT_SONAME`, `DT_FLAGS`, `DT_FLAGS_1`, `DT_TEXTREL`, `DT_BIND_NOW`, `DT_VERNEED`, `DT_VERNEEDNUM`, `DT_STRTAB`, `DT_STRSZ`, `DT_SYMTAB`, `DT_SYMENT`, `DT_HASH`, `DT_GNU_HASH`, `DT_VERSYM`. Then walk `.gnu.version_r`. Then, best-effort, the dynamic symbol table.

**Gate:** `t_dynamic.c`, `t_verneed.c`, `t_symbols.c` pass. Every cycle, overflow, and out-of-range case in `03-TESTPLAN.md §5.6` terminates with an error in bounded time.

### Task 7 — findings, baselines, and the two reporters

`finding.c`, `baseline.c`, `report_text.c`, `report_json.c`. Output must be sorted and byte-stable.

**Gate:** `t_report.c` and `t_baseline.c` pass. The JSON writer round-trips every escape case in `03-TESTPLAN.md §5.3`. Golden files exist for at least six fixtures and match byte-for-byte.

### Task 8 — the checks

One file per check family, in the order they appear in `01-SPEC-audit.md §7`. Implement them one at a time, with the test file for each written **before** the check itself.

**Gate:** every finding ID in `01-SPEC-audit.md §8` is produced by at least one test and suppressed by at least one test. `03-TESTPLAN.md §4` gives the required matrix.

Profile M (`OB0038`, `OB0039`) is part of this task, not an afterthought. The profile ladder in `01-SPEC-audit.md §7.3` is the same one as `02-REFERENCE-elf.md §3`: **write it once**, in `elf/image.c`, and have the check call it. Two copies will drift and one of them will be the wrong one.

### Task 9 — the CLI

Argument parsing, exit codes, `--format`, `--profile`, `--glibc-max`, `--level`, `--strict`, `--allow`, `--baseline`, `--no-color`, `--quiet`, `--verbose`. Exact grammar in `01-SPEC-audit.md §5`.

**Gate:** `t_cli.c` passes. Every flag has a test. Every exit code has a test. Unknown flags, missing operands, and `--` handling all have tests.

### Task 10 — the malformed corpus and the fuzzer

`t_malformed.c` (the enumerated corpus) and `fuzz.c` (deterministic mutation).

**Gate:** `make test-asan` and `make test-ubsan` both pass clean. `make fuzz FUZZ_ITERS=200000` completes with zero crashes, zero hangs, and zero sanitizer reports.

### Task 11 — coverage and the lint test

`make coverage` and `tests/t_lint.c`.

**Gate:** line coverage ≥ 90% and branch coverage ≥ 85% over `src/`, with 100% line coverage on `util/buf.c` and `util/ver.c`. `make coverage` **exits non-zero** below threshold — it is a gate, not a report. `t_lint.c` passes.

### Task 12 — self-audit and documentation

`onebin/README.md`, and `make selftest` which builds `onebin` with Profile S flags and audits itself.

**Gate:** `make selftest` prints a passing Level 1 report for the tool itself, or, if the build environment cannot produce a static binary, prints a clearly-worded SKIP with the reason. Never a silent pass.

---

### Task 13 — teach `tools/audit.sh` about modules

The shell stopgap has the same bug the C tool had: it decides Profile S vs H on
`DT_NEEDED` alone, so it reports every plugin as a broken hybrid. Fix it with the
same ladder (`01-SPEC-audit.md §7.3`), add a `-m`/`--module` flag to force it, and
keep the script under 150 lines. It stays POSIX `sh` and it stays dependent on
nothing but `readelf` and `strings`.

**Gate:** running it on a `.so` on the build machine — pick any from `/usr/lib` —
reports it as a module and does not emit the "no PT_INTERP" failure. Running it on
`/bin/sh` still reports a hybrid. Both results pasted into your report.

### Task 14 — the CMake toolchain files

`onebin/toolchain/onebin-linux-static.cmake` and `onebin-linux-hybrid.cmake`, per
`DESIGN-onebin.md §8`, plus the four `zig-*` wrapper scripts (CMake needs a
program per language and per tool; `zig cc` is two words and CMake will not
accept that).

Requirements you must not skip, all of them from `04-REFERENCE-far2l.md §7.1` and
`DESIGN-onebin.md §8`:

- `ONEBIN_EXPORT_DYNAMIC` option. `OFF` → `-Wl,--exclude-libs,ALL`. `ON` →
  `-Wl,--export-dynamic` and **no** `--exclude-libs`. Applications with a plugin
  ABI need `ON`, and the far2l configurations set it.
- `ONEBIN_GLIBC_BASELINE`, default `2.28`, used in the `-target` triple.
- `--gc-sections` set from the toolchain file. Do not assume the project adds it:
  far2l adds it only when the compiler is not Clang, and `zig cc` is Clang.
- `-ffile-prefix-map` for both source and binary directories, so our own
  reference build does not trip our own `OB0060`.
- RELRO, BIND_NOW, non-executable stack, `-fstack-protector-strong`.
- The static file sets `CMAKE_FIND_LIBRARY_SUFFIXES ".a"`, `BUILD_SHARED_LIBS
  OFF`, `-static-pie`.

**Gate:** `cmake -DCMAKE_TOOLCHAIN_FILE=… ` configures and builds a two-file
"hello world" C and C++ project that you write in `onebin/toolchain/tests/`, for
whichever of the two profiles the environment can actually run. If `zig` is not
installed, the gate is that `cmake -P` parses both files without error and the
wrappers pass `shellcheck`; print a SKIP naming what was missing. **A SKIP is an
acceptable outcome here. A silent pass is not.**

### Task 15 — `tools/build-far2l.sh`

The interface is specified in `04-REFERENCE-far2l.md §10`. Read it before writing
a line. The four configurations and their exact `cmake` arguments are in §6 of the
same document; copy them, do not improvise them.

You cannot run this script to completion — there is no network and no far2l
source. That is why `--print-plan` exists and why it is the part with a test:

- `--print-plan` prints, to stdout, every command the script would run, in order,
  one per line, with no side effects whatsoever. It must work with no network, no
  far2l checkout, no compiler and no `zig`.
- `tests/golden/far2l-{tiny,tty,sdl,wx}.plan` hold the expected output.
  `t_far2l_plan.c` runs the script four times and compares bytes.
- The plan must be deterministic: no timestamps, no `$PWD`, no hostnames, no
  absolute paths outside those given on the command line.
- `contrib/far2l/deps.lock` is created in this task with the far2l tag pinned to
  the value in `04-REFERENCE-far2l.md §2` and one line per third-party
  dependency. **Leave the sha256 column as `-` for anything you cannot hash**,
  and say so in `NOTES.md` — a fabricated hash is worse than a missing one.
- The script never fetches unless `--fetch` is given explicitly. Default is
  `--no-fetch`, and `--no-fetch` with a missing source tree is a clean error with
  a message telling the user which command to run.

**Gate:** `make far2l-plan` regenerates nothing and passes; `t_far2l_plan` is
green; `shellcheck tools/build-far2l.sh` is clean (or SKIP with a reason if
`shellcheck` is absent); running the script with `--no-fetch` and no source tree
exits non-zero with a message naming `--fetch`.

### Task 16 — the far2l write-up

Two short files and nothing else:

- `contrib/far2l/UPSTREAM.md` — the changes far2l would need for a *better* result
  than the one we can get today, as prose, with the reasoning. At minimum: static
  registration of plugins so Profile S can have them (`04-REFERENCE-far2l.md
  §7.3`), and anything you discovered while writing Tasks 14–15. These are
  proposals for a maintainer to consider, not demands, and they are written that
  way.
- `contrib/far2l/patches/` stays **empty**, with a `.gitkeep` and a one-line
  README saying that an empty directory is the correct answer and why.

**Gate:** both files exist; `patches/` contains no patch; `UPSTREAM.md` contains
no claim about far2l's source that is not traceable to `04-REFERENCE-far2l.md`.

---

## 5. Build system requirements

Plain POSIX `make`. No CMake, no autotools, no shell-outs to anything that might be absent.

Mandatory targets:

| Target | Behaviour |
|---|---|
| `all` | builds `build/onebin` |
| `test` | builds and runs the whole suite; non-zero on any failure |
| `test-asan` | rebuilds with `-fsanitize=address,undefined -fno-omit-frame-pointer` and runs `test` |
| `test-ubsan` | rebuilds with `-fsanitize=undefined -fno-sanitize-recover=all` and runs `test` |
| `fuzz` | runs the mutation fuzzer for `$(FUZZ_ITERS)` iterations, default 20000 |
| `coverage` | `--coverage` build, runs `test`, prints a per-file table, **fails below threshold** |
| `golden` | regenerates `tests/golden/*.json`; never run automatically by `test` |
| `selftest` | Profile S build of `onebin`, then `onebin audit` on itself |
| `lint` | runs `t_lint` alone |
| `clean` | removes `build/` and nothing else |
| `install` | `cp build/onebin $(DESTDIR)$(PREFIX)/bin/` |
| `far2l-plan` | runs `tools/build-far2l.sh --print-plan` for all four configurations and diffs against `tests/golden/far2l-*.plan`; non-zero on any difference |

Base flags:

```
CFLAGS = -std=c11 -O2 -g -Wall -Wextra -Werror -Wpedantic \
         -Wshadow -Wconversion -Wsign-conversion -Wstrict-prototypes \
         -Wmissing-prototypes -Wpointer-arith -Wwrite-strings \
         -Wcast-qual -Wvla -Wformat=2 -Wundef \
         -D_FILE_OFFSET_BITS=64
```

`-Werror` stays on. If a warning is genuinely unavoidable, suppress it at the narrowest possible scope with a `#pragma` and a comment explaining why — never by removing the flag.

Sanitizer and coverage builds must go into separate object directories so they never contaminate the normal build.

If a sanitizer is unavailable in the environment, `make test-asan` must print a clear SKIP and exit 0. It must **not** silently pretend to have run.

---

## 6. Definition of done

All of the following, verified by running commands, not by inspection:

- [ ] `make && make test` — green, zero warnings from the compiler
- [ ] `make test-asan` — green or explicitly skipped with a reason
- [ ] `make test-ubsan` — green or explicitly skipped with a reason
- [ ] `make fuzz FUZZ_ITERS=200000` — zero findings
- [ ] `make coverage` — meets the thresholds in Task 11 and exits 0
- [ ] `make selftest` — passes or explicitly skips
- [ ] `make lint` — green
- [ ] `make clean && make` — reproducible; a second build produces byte-identical objects
- [ ] Every finding ID in `01-SPEC-audit.md §8` has a positive test and a negative test
- [ ] Every relative link in every `.md` file in the repository resolves
- [ ] `onebin/NOTES.md` records every ambiguity you resolved
- [ ] No file under `onebin/` contains a URL you invented, a TODO without an owner, or commented-out code
- [ ] `make far2l-plan` — green
- [ ] `tools/audit.sh` correctly classifies a shared library and an executable
- [ ] Both toolchain files parse; the hello-world gate passes or SKIPs with a stated reason
- [ ] `contrib/far2l/patches/` is empty, and `contrib/far2l/deps.lock` contains no fabricated hash
- [ ] Nothing anywhere in the tree states a fact about far2l that is not in `04-REFERENCE-far2l.md`

---

## 7. How to report back

When you finish, produce a short report containing, in this order:

1. The output of `make test` (final summary lines only).
2. The output of `make coverage` (the per-file table).
3. The contents of `onebin/NOTES.md`.
4. A list of anything in the spec you could not implement and why.
5. A list of anything you found wrong in the spec itself.
6. The four `--print-plan` outputs, and one paragraph on what a person with a
   network connection must do to turn them into a real build.
7. Anything in `04-REFERENCE-far2l.md` you could not act on because the document
   did not say enough. Be specific: "§6.3 does not say which SDL version" is
   useful; "more detail on far2l would help" is not. This list is the handover to
   whoever has a network connection, and it is the most valuable thing you will
   produce in Tasks 13–16.

Items 5 and 7 are not a formality. The spec was written without access to your build environment; if `02-REFERENCE-elf.md` contradicts what you observe in a real binary produced by the local compiler, **the real binary wins** — report the discrepancy and follow the observed behaviour, noting it in `NOTES.md`.
