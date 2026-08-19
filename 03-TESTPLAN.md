# TEST PLAN — `onebin audit` v0.1

This is not a suggestion. **Every numbered item below is a required test.** A task in `00-AGENT-TASK.md` is not complete until its tests exist, pass, and meet the coverage thresholds.

---

## 1. Principles

1. **Tests come first.** For every check in `01-SPEC-audit.md §7`, write the test file before the implementation. You will get the check wrong otherwise, because the interesting cases are the ones you would not have thought to handle.
2. **Every test is hermetic.** No network. No dependency on files outside the repository. No dependency on the host having a compiler toolchain, `readelf`, `python`, or any particular libc. Anything that needs an external tool must detect its absence and report `SKIP`, never silently pass.
3. **Every test is deterministic.** Same input, same output, every run, on every machine. `LC_ALL=C` is set by the Makefile for all test targets. Any randomness uses the fixed-seed PRNG in §6.
4. **A test that only checks "it did not crash" is not a test.** Assert on the actual output: which finding IDs, which severities, which subjects, which exit code.
5. **Negative tests matter as much as positive ones.** Every finding needs a fixture that produces it *and* a fixture that must not produce it. False positives destroy a linter's credibility faster than false negatives.
6. **Test isolation is by `fork()`.** A buggy parser will segfault. One crashing test must report as a failure and let the rest of the suite continue.

---

## 2. The harness — `tests/test.h`

No framework exists that you can download, so write ~150 lines. Required API:

```c
/* Registration: each test file defines tests with this macro and they
 * self-register via a constructor or an explicit list in a generated main. */
TEST(name) { ... }

/* Assertions. All record the file, line, and both values on failure,
 * then abort the current test (not the process). */
ASSERT_TRUE(expr)
ASSERT_FALSE(expr)
ASSERT_EQ_INT(actual, expected)
ASSERT_EQ_U64(actual, expected)
ASSERT_EQ_STR(actual, expected)
ASSERT_EQ_MEM(actual, expected, len)     /* prints a hex diff on failure */
ASSERT_NULL(p) / ASSERT_NOT_NULL(p)
ASSERT_OK(call)  / ASSERT_ERR(call)

/* Domain-specific — these will be used hundreds of times, so make them good. */
ASSERT_HAS_FINDING(report, "OB0051")
ASSERT_NO_FINDING(report, "OB0051")
ASSERT_FINDING_SEV(report, "OB0051", OB_SEV_ERROR)
ASSERT_FINDING_SUBJECT(report, "OB0010", "libfoo.so.1")
ASSERT_COUNTS(report, errors, warns, infos)

SKIP("reason")     /* records as skipped, not passed; printed in the summary */
```

Runner requirements:

- Each test runs in a `fork()`ed child. A child that segfaults, aborts, or is killed by a signal is reported as a failure **naming the signal**, and the run continues.
- A per-test timeout (default 10 seconds, `alarm()` in the child). A timeout is a failure named as such. **This is what catches infinite loops in the version-record walk.**
- Output: one line per test, then a summary `N passed, M failed, K skipped`.
- `./build/tests --filter <substring>` runs a subset. `--list` lists names. `--verbose` prints assertions as they pass.
- Exit non-zero if any test failed. **Skipped tests do not fail the run, but the summary must print them prominently** — a suite that silently skips half its tests is worse than no suite.

---

## 3. The fixture generator — `tests/mkelf.c`

You cannot download ELF binaries and you must not depend on the host compiler. So build ELF files byte by byte.

### Layout contract

Every generated file uses this fixed layout. Keep it simple so tests can compute offsets by hand:

```
0x000  ELF header
0x040  program headers          (ELF64; 0x034 for ELF32)
  ...  .interp        (optional, NUL-terminated string)
  ...  .dynstr        (all strings, NUL-separated, starts with a NUL byte)
  ...  .dynsym        (optional)
  ...  .gnu.version   (optional, uint16 per dynsym entry)
  ...  .gnu.version_r (optional)
  ...  .dynamic       (Elf*_Dyn array, DT_NULL terminated)
  ...  .rodata        (arbitrary strings the test wants findable)
  ...  section headers (optional)
```

**One `PT_LOAD` covering the entire file, with `p_offset == 0` and `p_vaddr == BASE`.** Use `BASE = 0x400000` for `ET_EXEC` and `BASE = 0` for `ET_DYN`. This makes `vaddr_to_offset(v) == v - BASE` for the whole file, so every test can compute expected addresses trivially, and a bug in address translation shows up immediately rather than being masked.

### API

```c
typedef struct eg eg;

eg  *eg_new(int cls /*32|64*/, int endian /*EG_LE|EG_BE*/,
            uint16_t machine, uint16_t type);
void eg_free(eg *);

/* Structure */
void eg_set_interp   (eg *, const char *path);          /* adds PT_INTERP    */
void eg_set_soname   (eg *, const char *soname);
void eg_add_needed   (eg *, const char *soname);
void eg_set_rpath    (eg *, const char *value);
void eg_set_runpath  (eg *, const char *value);
void eg_add_dyn      (eg *, uint64_t tag, uint64_t val); /* raw escape hatch */
void eg_set_flags    (eg *, uint64_t dt_flags, uint64_t dt_flags_1);
void eg_set_textrel  (eg *, int on);

/* Segments */
void eg_set_gnu_stack(eg *, int present, uint32_t p_flags);
void eg_set_gnu_relro(eg *, int present);
void eg_add_extra_load(eg *, uint64_t vaddr, uint64_t filesz, uint32_t flags);

/* Versions */
void eg_add_verneed  (eg *, const char *file,
                      const char *const *versions, size_t nversions);

/* Symbols */
void eg_add_dynsym   (eg *, const char *name, uint16_t versym_index,
                      uint8_t info, uint16_t shndx);
void eg_set_hash_style(eg *, int sysv /*DT_HASH*/, int gnu /*DT_GNU_HASH*/);

/* Content */
void eg_add_rodata_string(eg *, const char *s);
void eg_add_section  (eg *, const char *name, uint32_t type,
                      const void *data, size_t len);   /* forces section hdrs */
void eg_set_shdrs    (eg *, int emit);

/* Emit. Returns malloc'd buffer; caller frees. */
uint8_t *eg_emit(eg *, size_t *out_len);
int      eg_write(eg *, const char *path);

/* Post-emit mutation, for the malformed corpus. Offsets come from eg_off(). */
typedef enum { EG_OFF_EHDR, EG_OFF_PHDR, EG_OFF_DYNAMIC, EG_OFF_DYNSTR,
               EG_OFF_VERNEED, EG_OFF_DYNSYM, EG_OFF_SHDR, EG_OFF_RODATA } eg_part;
size_t eg_off(const eg *, eg_part);
void   eg_poke8 (uint8_t *buf, size_t len, size_t off, uint8_t  v);
void   eg_poke16(uint8_t *buf, size_t len, size_t off, uint16_t v, int be);
void   eg_poke32(uint8_t *buf, size_t len, size_t off, uint32_t v, int be);
void   eg_poke64(uint8_t *buf, size_t len, size_t off, uint64_t v, int be);
```

`eg_poke*` must bounds-check and abort the test on an out-of-range offset — a mutation helper that silently writes nothing produces tests that pass for the wrong reason.

### Convenience builders

Because most tests want a realistic baseline and then one thing changed:

```c
eg *eg_preset_hybrid_ok(void);   /* ET_DYN, PT_INTERP, libc.so.6 + libm.so.6,
                                    GLIBC_2.2.5 + GLIBC_2.28, RELRO, BIND_NOW,
                                    non-exec stack, no RPATH — must audit clean */
eg *eg_preset_static_ok(void);   /* ET_DYN, no PT_INTERP, no DT_NEEDED,
                                    PT_DYNAMIC present (static-PIE) — clean */
eg *eg_preset_static_nopie(void);/* ET_EXEC, no PT_DYNAMIC at all */
eg *eg_preset_shared_lib(void);  /* ET_DYN + DT_SONAME, no PT_INTERP */
eg *eg_preset_module(void);      /* ET_DYN, NO DT_SONAME, DT_NEEDED libc.so.6,
                                    no PT_INTERP, RELRO + BIND_NOW — a plugin as
                                    CMake actually builds one. Must audit clean
                                    as Profile M. */
```

**`eg_preset_hybrid_ok()`, `eg_preset_static_ok()` and `eg_preset_module()` must produce zero errors and zero warnings** at default settings. Assert exactly that in `t_mkelf.c`. If a preset ever starts producing a finding, either the check gained a false positive or the preset drifted — both need to fail the build loudly.

### `t_mkelf.c` — the generator tests itself

3.1 For each of the 8 combinations {ELF32, ELF64} × {LE, BE} × {ET_EXEC, ET_DYN}: emit a minimal file and assert the raw bytes at hand-computed offsets — magic, `EI_CLASS`, `EI_DATA`, `e_type`, `e_machine`, `e_phoff`, `e_phentsize`, `e_phnum`. Do **not** use the parser for these assertions; read the bytes directly. Otherwise a shared bug in the byte-order code makes both sides agree and both wrong.
3.2 Assert the emitted length equals the hand-computed sum of the parts.
3.3 Assert the byte sequence of the ELF64 LE example in `02-REFERENCE-elf.md §9` matches exactly, when the generator is configured to reproduce it.
3.4 Emit the same logical file as ELF32 and ELF64, parse both, assert the parsed *semantic* results are identical.
3.5 Emit the same logical file as LE and BE, parse both, assert identical semantic results.
3.6 Assert `eg_poke32` refuses an out-of-range offset.
3.7 Assert all five presets round-trip: emit → parse → the fields come back as configured.

---

## 4. The check matrix — required cases

For every finding ID in `01-SPEC-audit.md §8` you need **at least** a positive test (fixture produces it) and a negative test (a fixture that must not). The table below adds the cases that are easy to miss. Each row is a test.

### 4.1 `needed` — `t_checks_needed.c`

| # | Fixture | Assert |
|---|---|---|
| 1 | `hybrid_ok` | no `OB0010`, has `OB0011`? no — `OB0011` is for zero NEEDED. Assert no `OB0010`, no `OB0013`. |
| 2 | + `DT_NEEDED libfoo.so.1` | `OB0010` error, subject `libfoo.so.1` |
| 3 | + `libstdc++.so.6` | `OB0013` error, **not** `OB0010` |
| 4 | + `libgcc_s.so.1` | `OB0012` warn, **not** `OB0010` |
| 5 | + `libfoo.so.1` with `--allow libfoo.so.1` | no finding |
| 6 | `static_ok` | `OB0011` info |
| 7 | `libc.so.6` listed twice | exactly one `OB0010`-family finding; message mentions the duplicate |
| 8 | soname containing byte `0x1B` (ESC) | finding subject is sanitised; no ESC in output |
| 9 | soname 5000 bytes long | subject truncated to 200 bytes; no crash |
| 10 | `DT_NEEDED` index == `DT_STRSZ` | `OB0003` non-fatal; other checks still run |
| 11 | 5000 `DT_NEEDED` entries | bounded by `ONEBIN_MAX_NEEDED`; completes in under a second |
| 12 | allowlist entries with different case (`LIBC.SO.6`) | `OB0010` — matching is case-sensitive |

### 4.2 `glibc` — `t_checks_glibc.c`

| # | Fixture | Assert |
|---|---|---|
| 1 | verneed `libc.so.6 → GLIBC_2.2.5, GLIBC_2.28`, `--glibc-max 2.28` | pass |
| 2 | same, `--glibc-max 2.17` | `OB0020` error; message names 2.28 and 2.17 |
| 3 | verneed with `GLIBC_2.9` and `GLIBC_2.10`, max `2.9` | `OB0020` — proves numeric, not lexical, comparison |
| 4 | verneed with `GLIBC_2.10` only, max `2.9` | `OB0020` |
| 5 | verneed with `GLIBC_2.9` only, max `2.10` | pass |
| 6 | `GLIBC_ABI_DT_RELR` present | `OB0022` warn; does **not** affect the computed max |
| 7 | `GLIBC_PRIVATE` present | `OB0024` error |
| 8 | `GLIBCXX_3.4.29` from `libstdc++.so.6` | `OB0023` warn |
| 9 | `GCC_3.0` from `libgcc_s.so.1` | `OB0023` warn |
| 10 | no `.gnu.version_r` at all | `glibc_required` is null; no `OB0020` |
| 11 | `DT_VERNEEDNUM` = 3 but chain terminates after 1 | parses 1, no crash, no `OB0020` false positive |
| 12 | `DT_VERNEEDNUM` = 1 but chain has 3 | parses 1 (the smaller count wins) |
| 13 | `vn_version` = 2 | `OB0003`, walk stops, audit continues |
| 14 | versions in non-sorted order (`2.28` before `2.2.5`) | max is still `2.28` |
| 15 | ELF32 and BE variants of case 2 | identical findings |
| 16 | `DT_HASH` present, 12 symbols, one versioned to `GLIBC_2.28` | `OB0021` names the right symbol |
| 17 | no `DT_HASH`, no shdrs, no `DT_GNU_HASH` | `OB0025` info; `OB0020` still correct |
| 18 | `DT_GNU_HASH` with `nbuckets`=4 | symbol count derived correctly |
| 19 | `DT_GNU_HASH` with `bloom_size`=0 | `OB0025`; no divide-by-zero, no crash |
| 20 | `DT_HASH` with `nchain` = `0xFFFFFFFF` | clamped; completes in under a second |

### 4.3 `profile` — `t_checks_profile.c`

| # | Fixture | Assert |
|---|---|---|
| 1 | `static_ok` (ET_DYN, PT_DYNAMIC, no NEEDED, no INTERP) | **no findings at all**. This is the false-positive test that matters most. |
| 2 | `static_nopie` (ET_EXEC, no PT_DYNAMIC) | `OB0032` warn, `OB0056` info; **no** `OB0050`, **no** `OB0051` |
| 3 | `static_ok` + `PT_INTERP` | `OB0030` error |
| 4 | `static_ok` + `DT_NEEDED` | `OB0031` error; profile auto-detects as hybrid unless `--profile static` |
| 5 | `--profile static` on `hybrid_ok` | `OB0030` and `OB0031` |
| 6 | `--profile hybrid` on `static_ok` | `OB0036` error |
| 7 | static + rodata string `Dynamic loading not supported` | `OB0033` error |
| 8 | static + `.symtab` containing `dlopen` | `OB0033` error |
| 9 | static + rodata string `dlopen` only | `OB0033` **warn**, message says the evidence is a string match |
| 10 | static, stripped, no evidence | `OB0035` info; **no** `OB0033` |
| 11 | static + `/etc/nsswitch.conf` string | `OB0034` error |
| 12 | hybrid + `/etc/nsswitch.conf` string | **no** `OB0034` (the check requires no `DT_NEEDED`) |
| 13 | `PT_INTERP` = `/lib64/ld-linux-x86-64.so.2`, machine x86_64 | no `OB0037` |
| 14 | `PT_INTERP` = `/opt/weird/loader` | `OB0037` warn |
| 15 | two `PT_INTERP` segments | first is used; `OB0003` info |
| 16 | `shared_lib` preset | `OB0005` info, `OB0038` info; **no** `OB0030`–`OB0037` |
| 17 | `module` preset (ET_DYN, **no** `DT_SONAME`, has `DT_NEEDED`, no `PT_INTERP`) | profile auto-detects as **module**; `OB0038` info; **no** `OB0036`. This is the regression test for the bug the reference application found — it must fail against the pre-`OB0038` behaviour. |
| 18 | `module` preset + `DT_NEEDED libfoo.so.1` | `OB0010` error — the soname allowlist applies to modules exactly as it does to executables |
| 19 | `module` preset with no RELRO | `OB0050` error — hardening checks are not skipped for modules |
| 20 | `module` preset + rodata string `dlopen` | **no** `OB0033`. A module that calls `dlopen` is not a defect. |
| 21 | `module` preset + `PT_INTERP` | `OB0030` error — it is not a module |
| 22 | `--profile module` on `hybrid_ok` | `OB0030` error (has `PT_INTERP`) |
| 23 | `--profile hybrid` on the `module` preset | `OB0036` error — an explicit flag is obeyed even when it is wrong |
| 24 | ET_DYN, no `PT_INTERP`, no `DT_NEEDED`, no `DT_SONAME`, no `DF_1_PIE` | `OB0039` info; audited as Profile S; **no** `OB0038` |
| 25 | same, plus `DT_FLAGS_1 = DF_1_PIE` | Profile S; **no** `OB0039`, **no** `OB0038` |
| 26 | `module` preset with an undefined symbol in `.dynsym` | no finding of any kind about it |
| 27 | `--format json` on the `module` preset | `"profile": "module"`, `"profile_source": "auto"`; golden file |
| 28 | ELF32 and BE variants of case 17 | identical findings |

### 4.4 `rpath` — `t_checks_rpath.c`

| # | Value | Assert |
|---|---|---|
| 1 | no RPATH, no RUNPATH | no findings |
| 2 | `DT_RUNPATH = $ORIGIN/../lib` | `OB0041` warn |
| 3 | `DT_RUNPATH = ${ORIGIN}/lib` | `OB0041` warn |
| 4 | `DT_RUNPATH = /opt/app/lib` | `OB0040` error |
| 5 | `DT_RUNPATH = $ORIGIN/lib:/opt/x` | one `OB0041` **and** one `OB0040` |
| 6 | `DT_RPATH` set (no RUNPATH) | `OB0042` warn plus the path finding |
| 7 | both `DT_RPATH` and `DT_RUNPATH` | both checked; `OB0042` present |
| 8 | `DT_RUNPATH = ""` (empty string) | `OB0043` error |
| 9 | `DT_RUNPATH = "a::b"` | `OB0043` error |
| 10 | `DT_RUNPATH = ":$ORIGIN"` | `OB0043` **and** `OB0041` |
| 11 | 500 components | all parsed, no overflow, bounded time |
| 12 | `$ORIGINAL/lib` | `OB0040` — prefix match must not accept `$ORIGINAL` as `$ORIGIN` |

Case 12 is the one you will get wrong. `$ORIGIN` must be followed by `/`, `:`, or end of string.

### 4.5 `harden` — `t_checks_harden.c`

| # | Fixture | Assert |
|---|---|---|
| 1 | `hybrid_ok` | none of `OB0050`–`OB0055` |
| 2 | no `PT_GNU_RELRO` | `OB0050` |
| 3 | no BIND_NOW anywhere | `OB0051` |
| 4 | `DT_BIND_NOW` present only | no `OB0051` |
| 5 | `DT_FLAGS = DF_BIND_NOW` only | no `OB0051` |
| 6 | `DT_FLAGS_1 = DF_1_NOW` only | no `OB0051` |
| 7 | `PT_GNU_STACK` with `PF_X` | `OB0052` |
| 8 | no `PT_GNU_STACK` | `OB0053` warn |
| 9 | `ET_EXEC` hybrid | `OB0054` warn |
| 10 | `DT_TEXTREL` present | `OB0055` |
| 11 | `DT_FLAGS = DF_TEXTREL` | `OB0055` |
| 12 | no `PT_DYNAMIC` | `OB0056` info; no `OB0050`, no `OB0051` |
| 13 | **ELF32** `PT_GNU_STACK` with `PF_X` | `OB0052` — proves `p_flags` is read from offset 24, not 4 |
| 14 | **ELF32** `PT_GNU_STACK` without `PF_X` | no `OB0052` |
| 15 | **BE** variants of 7 and 13 | same results |

Cases 13–15 exist solely to catch the `Elf32_Phdr.p_flags` offset bug from `02-REFERENCE-elf.md §10.14`. Do not skip them.

### 4.6 `hygiene` — `t_checks_hygiene.c`

| # | Rodata string | Assert |
|---|---|---|
| 1 | none | no findings |
| 2 | `/home/builder/src/main.c` | `OB0060` warn |
| 3 | `/Users/bob/proj/x.c` | `OB0060` |
| 4 | `/usr/lib/x86_64-linux-gnu/libfoo.so` | `OB0061` |
| 5 | `/nix/store/abc-glibc/lib` | `OB0061` |
| 6 | 50 distinct `/home/...` strings | 10 findings + a message naming the total |
| 7 | `/homely/path` | **no** finding — prefix must be `/home/` |
| 8 | a 3-byte run `/ho` | not a string (minimum length 4) |
| 9 | 8 MiB of `A` with no NUL | one string, capped at 4096; no 8 MiB allocation |
| 10 | section `.debug_info` present | `OB0062` info with the size |
| 11 | section `.gnu_debuglink` present | `OB0063` info |
| 12 | no section headers at all | no `OB0062`, no `OB0063`, no crash |

### 4.7 `host` — `t_checks_host.c`

| # | Rodata string | Assert |
|---|---|---|
| 1 | `libGL.so.1` | `OB0070` info |
| 2 | `libvulkan.so.1` | `OB0070` |
| 3 | `libpipewire-0.3.so` | `OB0070` |
| 4 | `libfoo.so.1` (not in DT_NEEDED) | `OB0071` warn |
| 5 | `libc.so.6` (on the allowlist) | no `OB0071` |
| 6 | `libbar.so.2` that **is** in `DT_NEEDED` | no `OB0071` |
| 7 | `notalib.so` (no `lib` prefix) | no finding |
| 8 | `libGL.so` (no version suffix) | `OB0070` |
| 9 | `lib.so` | no finding — needs at least one name character |
| 10 | `libfoo.so.1.2.3` | `OB0071` |
| 11 | `libfoo.so.x` | no finding — suffix must be numeric |
| 12 | 100 distinct unknown sonames | capped at 20 findings |

### 4.8 Reporting, baselines, CLI

`t_report.c`:
1. Same report rendered twice produces byte-identical output.
2. Findings appear in sorted order regardless of the order they were added.
3. JSON output contains every key from `01-SPEC-audit.md §9.2`, in that exact order, even when values are null/empty.
4. `counts` matches the actual number of findings at each severity.
5. Text output with `--quiet` contains only the verdict and error lines.
6. Text output with `--verbose` contains info findings.
7. Colour is absent when `--no-color` is passed; absent when `NO_COLOR=1`; absent when stdout is a pipe.
8. Six golden fixtures compared byte-for-byte against `tests/golden/*.json`.

`t_baseline.c`:
1. A baseline containing a finding's fingerprint suppresses it and decrements the count.
2. Suppression changes the verdict from FAIL to PASS when it removes the only error.
3. `"suppressed": N` appears in JSON.
4. A stale entry produces `OB0100` info.
5. `--write-baseline` then re-running with `--baseline` yields zero findings and exit 0.
6. A baseline file with comments, blank lines, CRLF line endings, and trailing whitespace parses correctly.
7. A baseline file that does not exist is a usage error, exit 2.
8. A baseline containing 10000 entries loads in bounded time.

`t_cli.c` — spawns the built binary via `fork`/`execv` and inspects exit code and output:
1. `--version` prints exactly `onebin 0.1.0\n`, exit 0.
2. `--help` exits 0 and mentions `audit`.
3. No arguments: usage to stderr, exit 2.
4. Unknown subcommand: exit 2.
5. Unknown option: exit 2, message names the option.
6. `--glibc-max` without a value: exit 2.
7. `--glibc-max notaversion`: exit 2.
8. Nonexistent file: `OB0090`, exit 2.
9. A directory: `OB0091`, exit 2.
10. A FIFO: `OB0091`, exit 2, **completes in under 2 seconds** (this is the hang test — create the FIFO with `mkfifo` and never open the write end).
11. `/dev/zero` if present: `OB0091`, exit 2. SKIP if absent.
12. A 0-byte file: `OB0001`, exit 2.
13. A text file (`#!/bin/sh`): `OB0001`, exit 2.
14. An `ar` archive (`!<arch>\n`): `OB0001`, exit 2.
15. Clean fixture: exit 0.
16. Fixture with one error: exit 1.
17. Fixture with only warnings: exit 0.
18. Same, with `--strict`: exit 1.
19. Two files, one clean one failing: exit 1; both reports present.
20. Two files with `--format json`: output is a JSON **array** of two objects.
21. One file with `--format json`: output is a single JSON **object**.
22. `--` followed by a filename starting with `-`: treated as a path.
23. A file named `-`: treated as a path, not stdin.
24. `--max-file 100` on a 200-byte file: `OB0092`, exit 2.

---

### 4.9 The reference application's shape — `t_checks_module.c`

We cannot build far2l in this environment: there is no network, no far2l source,
and no wxWidgets. What we *can* do is reproduce its **shape** with the fixture
generator and assert that the auditor handles it, so that the first real far2l
build finds compile errors rather than design errors.

Construct an in-memory tree that mirrors `04-REFERENCE-far2l.md §9`:

| Fixture | Stands in for | Assert |
|---|---|---|
| hybrid executable, `DT_RUNPATH=$ORIGIN/../lib/far2l`, populated `.dynsym` | `far2l` | passes at `--level 1`; `OB0041` warn for the runpath; the exported symbols draw **no** finding |
| module, no soname, needs only `libc.so.6` | a `.far-plug-wide` plugin | passes as Profile M |
| module needing `libGL.so.1` as a *string*, not `DT_NEEDED` | `far2l_sdl.so` | `OB0070` info, no error |
| module with `DT_NEEDED libgtk-3.so.0` | `far2l_gui.so` | `OB0010` error — the expected, documented failure |
| hybrid executable needing `libX11.so.6` | `far2l_ttyx.broker` | `OB0010` error without `--allow`, clean with `--allow libX11.so.6` |
| all six audited in one invocation | the real command line | exit code is the maximum over files; each file gets its own report block; JSON is one document per file in input order |

The last row is the one that will break first: v0.1 accepts `FILE...` and most
implementations quietly assume one file.

---

## 5. Robustness
## 4.10 GUI Artifact Runtime Gate (Level 1)

As discovered in `05-REFERENCE-f4-qt.md §7.4`, a static Qt or SDL application can pass every `readelf` or `onebin audit` check and still fail to start (e.g., due to missing QML modules or platform plugins).

**Gate:** For Level 1 conformance, any GUI artifact MUST pass an automated offscreen smoke test.
1. Run the artifact with `QT_QPA_PLATFORM=offscreen`, SDL's `dummy` driver, or the equivalent headless backend for the toolkit.
2. Assert that the application starts, reaches a checkpoint (or exits gracefully/disconnects as expected by the architecture), and produces no missing-plugin or component-loading errors in its output.
3. This must be an automated script in the CI pipeline evaluating standard error and exit codes.

---

### 5.1 `t_buf.c` — mandatory cases

1. `len == 0`: every reader fails.
2. Read at `off == len`: fails for `n > 0`, succeeds for `n == 0`.
3. Read at `off == len - 1` of 2 bytes: fails.
4. `off = SIZE_MAX`, `n = 1`: fails, no wraparound.
5. `off = 0`, `n = SIZE_MAX`: fails, no wraparound.
6. `off = SIZE_MAX - 2`, `n = 4`: fails (the classic `off + n` overflow).
7. `ob_rd16/32/64` produce correct values for LE and for BE on the same bytes.
8. `ob_rdaddr` reads 4 bytes when `c64 == 0` and 8 when `c64 == 1`.
9. `ob_rdstr` on a NUL-terminated string returns the right length.
10. `ob_rdstr` on a string that runs to the buffer end without NUL: fails.
11. `ob_rdstr` with `dstsz` smaller than the string: fails or truncates — pick one, document it in `NOTES.md`, and test the chosen behaviour.
12. `ob_rdstr` with `max` smaller than the string: bounded, fails.
13. `ob_rdstr` always NUL-terminates `dst`, including on failure.
14. On every failure, the `*out` parameter is unmodified (prefill it with a sentinel and assert it survives).

### 5.2 `t_str.c`
1. Sanitiser replaces bytes `0x00`–`0x1F` and `0x7F`–`0xFF` with `?`.
2. Sanitiser leaves `0x20`–`0x7E` untouched.
3. Sanitiser appends the `[sanitised]` marker only when something changed.
4. Truncation at 200 bytes appends `...`.
5. A string of exactly 200 bytes is not truncated.
6. UTF-8 input is mangled to `?` — this is intended; assert it rather than being surprised later.
7. Embedded ANSI escape `\x1b[31m` is neutralised.
8. Embedded `\n` is neutralised (a soname with a newline must not forge a report line).

### 5.3 `t_json.c`
1. `"` and `\` are escaped.
2. Since input is sanitised first, control characters never reach the writer — assert the writer *also* handles them defensively if given one directly.
3. Empty string, empty array, empty object all render correctly.
4. `null` renders for absent scalars.
5. Nested arrays of objects indent correctly.
6. Output ends with exactly one `\n`.
7. No trailing commas anywhere.
8. Numbers render without locale-dependent separators (test with `LC_ALL` set to something with a comma decimal separator if `setlocale` succeeds; SKIP if not).

### 5.4 `t_ver.c`
Every row of `01-SPEC-audit.md §6.2`, plus the six comparator cases listed there, plus:
1. Comparison is a total order: for a set of 10 versions, sorting is stable and consistent.
2. `compare(a, b) == -compare(b, a)` for every pair.
3. Parsing a 4096-byte version string does not overflow.

### 5.5 `t_image.c` — malformed headers
Each of these must return a clean error and never crash, hang, or read out of bounds:

1. Empty file.
2. 1, 2, 3 bytes.
3. Correct magic then EOF at 4 bytes.
4. Truncated at 15, 16, 51, 52, 63, 64 bytes (both class values).
5. Bad magic (one byte wrong, each of the four positions).
6. `EI_CLASS` = 0, 3, 255.
7. `EI_DATA` = 0, 3, 255.
8. `EI_VERSION` = 0 → warn, continues.
9. `e_type` = `ET_REL`, `ET_CORE`, 0, 65535.
10. `e_phentsize` = 0, 1, 55, 57, 65535 on ELF64.
11. `e_phentsize` = 31, 33 on ELF32.
12. `e_phnum` = 0.
13. `e_phnum` = 0xFFFF with no section headers.
14. `e_phnum` = 1000 in a 200-byte file.
15. `e_phoff` = file length, = length+1, = `UINT64_MAX`.
16. `e_shoff` beyond EOF (must not affect program-header parsing).
17. `e_shentsize` wrong with `e_shnum` > 0.
18. `e_shstrndx` >= `e_shnum`.
19. `e_ehsize` = 0.

### 5.6 `t_malformed.c` — malformed dynamic and version data
Each must terminate in bounded time with a finding, never a crash or hang:

1. `PT_DYNAMIC` `p_offset` beyond EOF.
2. `PT_DYNAMIC` `p_filesz` = 0.
3. `PT_DYNAMIC` `p_filesz` not a multiple of the entry size.
4. Dynamic array with no `DT_NULL` (runs to the end of the segment).
5. 100000 dynamic entries (bounded by `ONEBIN_MAX_DYNENT`).
6. `DT_STRTAB` address not covered by any `PT_LOAD`.
7. `DT_STRTAB` address inside the `p_memsz`-only (bss) region.
8. `DT_STRSZ` = 0.
9. `DT_STRSZ` = `UINT64_MAX`.
10. String table whose last byte is not NUL, with `DT_NEEDED` pointing at the last string.
11. `DT_NEEDED` index = `DT_STRSZ`, = `DT_STRSZ + 1`, = `UINT64_MAX`.
12. `DT_VERNEED` unmapped.
13. `DT_VERNEEDNUM` = `UINT32_MAX`.
14. `vn_next` = 0 on the first record with `DT_VERNEEDNUM` = 5.
15. **`vn_next` = 0xFFFFFFF0 (wraps past the buffer)** — the cycle guard must catch it.
16. **`vn_next` pointing backwards** (encoded as a large value that wraps) — cycle guard.
17. **`vna_next` = 0 with `vn_cnt` = 100.**
18. **`vna_next` forming a self-loop** — cycle guard; must terminate.
19. `vn_cnt` = 0xFFFF.
20. `vn_aux` = 0 (points at the `Verneed` itself).
21. `vn_aux` beyond EOF.
22. `vn_file` index out of range.
23. `vna_name` index out of range.
24. `vn_version` = 0, 2, 0xFFFF.
25. Two `PT_LOAD` segments claiming the same vaddr → `OB0004`, first wins.
26. `PT_LOAD` with `p_vaddr + p_filesz` overflowing `UINT64_MAX`.
27. `PT_LOAD` with `p_offset` beyond EOF.
28. `PT_LOAD` with `p_filesz` > file length.
29. `PT_LOAD` with `p_memsz` < `p_filesz`.
30. `DT_SYMENT` = 0, = 1, = 1000.
31. `DT_HASH` unmapped; `nchain` = 0; `nchain` = `UINT32_MAX`.
32. `DT_GNU_HASH` with `nbuckets` = 0; `bloom_size` = 0; `symoffset` > any bucket value.
33. `DT_GNU_HASH` chain that never sets the low bit.
34. `PT_INTERP` `p_filesz` = 0.
35. `PT_INTERP` string with no NUL inside `p_filesz`.
36. `PT_INTERP` `p_offset` beyond EOF.
37. `DT_RUNPATH` index out of range.
38. A file that is all zero bytes, 64 KiB long.
39. A file that is all `0xFF`, 64 KiB long.
40. A valid ELF header followed by 1 MiB of random-but-fixed-seed bytes.

For every one of these, assert **two** things: the process exits with the expected code, and the wall time is under 2 seconds.

### 5.7 `t_lint.c` — architecture rules enforced as tests

A test that reads the project's own source files and asserts:

1. No file except `src/util/buf.c` contains the pattern `b->p[` or `buf->p[` (raw indexing).
2. No file contains a cast to `Elf64_` or `Elf32_` struct types.
3. No file contains `#include <elf.h>`.
4. No file contains `mmap(`.
5. No file contains `strcpy(`, `strcat(`, `sprintf(`, `gets(`, or `alloca(`.
6. Every `malloc`/`calloc`/`realloc` call site is followed within 3 lines by a NULL check.
7. No file contains `TODO` or `FIXME` without an owner in parentheses.
8. Every finding ID in `01-SPEC-audit.md §8` appears at least once in `src/`.
9. Every finding ID that appears in `src/` is listed in the spec (catches invented IDs).
10. Every file in `src/` is referenced by the Makefile.

Rule 9 is a genuinely useful guard: it prevents the implementation from drifting away from the spec.

---

## 6. Fuzzing — `tests/fuzz.c`

Deterministic mutation fuzzer, no external dependency.

**PRNG** — use exactly this, so runs are reproducible across machines:

```c
static uint64_t s;                       /* seeded from --seed, default 1 */
static uint64_t next(void) {
    s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s;
}
```

**Corpus**: every fixture the generator can produce — all presets × {ELF32, ELF64} × {LE, BE}, plus the 40 malformed cases from §5.6.

**Mutations**, one per iteration, chosen by `next() % 6`:
1. Flip a random bit.
2. Overwrite a random byte with `0x00`, `0xFF`, or a random value.
3. Truncate at a random offset.
4. Overwrite a random 4- or 8-byte aligned field with `0`, `1`, `0x7FFFFFFF`, `UINT32_MAX`, or `UINT64_MAX` (boundary values find far more bugs than random ones).
5. Splice two corpus entries at a random offset.
6. Duplicate a random 16-byte record (targets the `Elf*_Dyn` and version arrays).

**Requirements**:
- Runs entirely in-process against the audit API, not by spawning the binary — so ASan sees everything.
- Each iteration has a hard timeout via `alarm()`; a timeout is a finding.
- On any crash, hang, or sanitizer report, write the offending input to `build/fuzz-crash-<seed>-<iter>.bin` and fail with the exact reproduction command.
- `make fuzz` defaults to 20000 iterations; CI runs 200000. Both must be clean.
- Add a `#ifdef ONEBIN_LIBFUZZER` `LLVMFuzzerTestOneInput` entry point for people who do have libFuzzer, but **do not depend on it** and do not make the build require it.

**Every crash the fuzzer finds becomes a permanent regression test in `t_malformed.c`.** Add the input as a hex array with a comment naming the seed and iteration that found it.

---

## 7. Coverage

`make coverage` builds with `--coverage`, runs the whole suite, and prints:

```
FILE                        LINES   COVERED   %      BRANCHES  COVERED   %
src/util/buf.c                 84        84  100.0        42       42  100.0
src/util/ver.c                126       126  100.0        68       68  100.0
...
TOTAL                        2140      1993   93.1      1102      967   87.7
```

**Gates — `make coverage` exits non-zero if any is unmet:**

| Scope | Line | Branch |
|---|---|---|
| `src/util/buf.c` | 100% | 100% |
| `src/util/ver.c` | 100% | 100% |
| `src/elf/` | ≥ 95% | ≥ 90% |
| `src/audit/checks/` | ≥ 95% | ≥ 90% |
| `src/` overall | ≥ 90% | ≥ 85% |

If `gcov`/`llvm-cov` is unavailable, print a clear SKIP naming the missing tool and exit 0 — but say so loudly, and do not report a coverage number you did not measure.

**Coverage is a floor, not a goal.** 100% line coverage of `buf.c` with only happy-path inputs proves nothing; the point of §5.1 is the failure paths. If you find yourself adding a test purely to move a percentage, you are doing it backwards — go back to §4 and §5 and find a case that is actually untested.

---

## 8. Anti-patterns — do not do these

- **Do not test the implementation against itself.** `t_mkelf.c` must assert raw bytes, not round-trip through your own parser. A shared endianness bug would otherwise cancel out and both halves would agree, wrongly.
- **Do not use the tool's own output format as the assertion mechanism** for parser tests. Assert on the parsed data structures. Golden-file tests exist separately and serve a different purpose.
- **Do not write one giant test per check file.** One assertion cluster per behaviour, named after the behaviour, so a failure names the bug.
- **Do not `#if 0` a failing test.** Fix it or delete it and say why in `NOTES.md`.
- **Do not add a sleep anywhere.** If a test needs synchronisation, it is testing the wrong thing.
- **Do not let a test depend on the order tests run in**, or on files another test created.
- **Do not skip the big-endian and ELF32 variants** because "nobody uses those". They are how you find the bugs that also affect the common path — a parser that reads `p_flags` from a hardcoded offset passes every x86-64 test and is still wrong.
