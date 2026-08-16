# SPEC — `onebin audit` v0.1

Functional specification. Read `02-REFERENCE-elf.md` first; this document assumes you know the ELF layouts and constants from it.

Where this document and `DESIGN-onebin.md` disagree, **this document wins** — it tightens several things the design doc left loose (notably exit codes, see §5.4).

---

## 1. Purpose

Given a path to an ELF file, decide whether it conforms to a declared Static Everywhere profile and level, and report every reason it does not.

---

## 2. Vocabulary

| Term | Meaning |
|---|---|
| **Profile S** | Fully static. No `PT_INTERP`, no `DT_NEEDED`. `PT_DYNAMIC` **may** be present (static-PIE uses it for self-relocation). |
| **Profile H** | Hybrid. Has `PT_INTERP` and `DT_NEEDED`, all of which must be on the allowlist. |
| **Baseline** | The maximum glibc version the binary is permitted to require, e.g. `2.28`. |
| **Level** | Conformance level 0–3 from the manifesto. v0.1 implements levels 0 and 1 fully, and the one file-existence check that level 3 needs. |
| **Finding** | One reported observation: id, severity, check name, subject, message, fingerprint. |
| **Fingerprint** | A stable string identifying a finding across runs, used by baselines: `"<id>:<subject>"`. |

---

## 3. Input handling

### 3.1 Accepted inputs

One or more file paths. Each is audited independently and produces its own report. With `--format json` and more than one path, the output is a JSON array of report objects; with one path it is a single object. (Rationale: single-file output stays scriptable with the common case.)

### 3.2 Reading the file

**Read the whole file into a heap buffer with `fopen`/`fread`. Do not `mmap`.**

Reasons, all of which have bitten real tools:
- If a file is truncated by another process while mapped, touching the vanished pages raises `SIGBUS` and there is no portable way to recover.
- `mmap` on a character device or a FIFO behaves in ways that vary by platform.
- A read into a heap buffer gives you one known length that every bounds check can rely on.

Rules:
- Before reading, `stat` the path. If it is not a regular file (directory, FIFO, socket, character device, block device), fail with `OB0091` and exit 2. **This check exists specifically so that `onebin audit /dev/zero` and `onebin audit some-fifo` terminate instead of hanging or exhausting memory.**
- If the file is larger than `ONEBIN_MAX_FILE` (default 512 MiB), fail with `OB0092` and exit 2. Make the limit a compile-time constant and a `--max-file` flag.
- A zero-length file fails with `OB0001` and exit 2.
- A short read (fewer bytes than `stat` reported) is not an error; use the number of bytes actually read as the buffer length. Files can shrink.

### 3.3 What "parse" means here

Parsing is **best-effort and non-fatal wherever possible**. A binary with a corrupt `.gnu.version_r` should still get its `DT_NEEDED` list reported, with a finding recording that version parsing failed. Only failures that make the file unidentifiable as ELF are fatal.

Everything that fails to parse produces a finding. Nothing fails silently.

---

## 4. `util/buf` — the bounds-checked reader

This is the only code in the project permitted to index into the file buffer.

```c
typedef struct {
    const uint8_t *p;      /* start of the whole file image */
    size_t         len;    /* bytes actually read */
    int            be;     /* 1 = big endian, 0 = little endian */
    int            c64;    /* 1 = ELFCLASS64, 0 = ELFCLASS32 */
} ob_buf;

/* All readers return 0 on success and -1 if the requested range is not
 * entirely inside [0, len). On failure *out is left unmodified.
 * There is no variant that reads without checking. */
int ob_rd8  (const ob_buf *b, size_t off, uint8_t  *out);
int ob_rd16 (const ob_buf *b, size_t off, uint16_t *out);
int ob_rd32 (const ob_buf *b, size_t off, uint32_t *out);
int ob_rd64 (const ob_buf *b, size_t off, uint64_t *out);

/* Reads 4 bytes on ELF32, 8 on ELF64, zero-extended into a uint64_t.
 * Used for every Elf_Addr / Elf_Off / Elf_Xword field. */
int ob_rdaddr(const ob_buf *b, size_t off, uint64_t *out);

/* Returns 0 if [off, off+n) is fully inside the buffer. */
int ob_range(const ob_buf *b, size_t off, size_t n);

/* NUL-terminated string starting at off, bounded by both the buffer end
 * and by max. Returns the length written, or -1 on failure.
 * The result is ALWAYS NUL-terminated. If the string runs to the end of
 * the buffer without a NUL, this is a failure, not a truncation. */
ssize_t ob_rdstr(const ob_buf *b, size_t off, char *dst, size_t dstsz, size_t max);
```

Required behaviour, all of which must be tested:

- **All arithmetic must be overflow-safe.** `off + n` can wrap. Compute `if (off > b->len || n > b->len - off) return -1;` — never `if (off + n > b->len)`.
- `ob_rd16/32/64` assemble bytes one at a time according to `b->be`. No `memcpy` into an integer, no pointer casts, no `htole32`.
- `ob_rdaddr` reads exactly 4 or 8 bytes according to `b->c64`.
- A read of length 0 at `off == b->len` succeeds (empty range at the end is valid). A read of length 0 at `off > b->len` fails.
- `b->len == 0` makes every read fail.

---

## 5. Command-line interface

### 5.1 Grammar

```
onebin audit [OPTIONS] FILE...
onebin --version
onebin --help
onebin audit --help
```

`--` terminates option parsing; everything after it is a path, even if it starts with `-`. A path of exactly `-` is a path named `-`, not stdin (v0.1 does not read stdin).

### 5.2 Options

| Option | Argument | Default | Meaning |
|---|---|---|---|
| `--profile` | `auto\|static\|hybrid` | `auto` | Which profile to check against. `auto` detects per §7.3. |
| `--glibc-max` | version | `2.28` | Highest permitted `GLIBC_x.y` requirement. Ignored in Profile S. |
| `--level` | `0\|1\|2\|3` | `1` | Conformance level. Higher levels enable more checks. |
| `--allow` | soname | — | Add one soname to the `DT_NEEDED` allowlist. Repeatable. |
| `--baseline` | path | — | Suppress findings whose fingerprint appears in this file. |
| `--write-baseline` | path | — | Write current findings to a baseline file and exit 0. |
| `--format` | `text\|json` | `text` | Output format. |
| `--strict` | — | off | Warnings count as errors. |
| `--quiet` | — | off | Text mode: print only the final verdict line and errors. |
| `--verbose` | — | off | Text mode: also print info findings and parse diagnostics. |
| `--no-color` | — | auto | Never emit ANSI colour. Also implied by `NO_COLOR` in the environment, or by stdout not being a TTY. |
| `--max-file` | bytes | 536870912 | Refuse files larger than this. |

Unknown options are a usage error: message to stderr, exit 2. Missing required argument to an option: same.

### 5.3 Colour

Colour is emitted only if **all** of: `--no-color` absent, `NO_COLOR` unset in the environment, `TERM` is not `dumb`, and `isatty(STDOUT_FILENO)` is true. Golden tests always run with output redirected, so colour never appears in them — but add `--no-color` explicitly in tests anyway, because relying on redirection to disable colour is how golden suites become flaky.

### 5.4 Exit codes

This **supersedes** the exit codes in `DESIGN-onebin.md §2`, which were ambiguous about the warnings-only case.

| Code | Meaning |
|---|---|
| `0` | All files audited; no findings of severity `error`. Warnings and infos may be present. |
| `1` | At least one file produced a finding of severity `error`. With `--strict`, at least one `warn` also produces 1. |
| `2` | Usage error, or a file could not be read or identified as ELF. **No audit result is meaningful.** |

With multiple files, the exit code is the maximum over all files.

Record in `onebin/NOTES.md` that this supersedes the design doc, and note that `DESIGN-onebin.md §2` should be updated in a later pass. Do not edit that document yourself.

---

## 6. Core algorithms

### 6.1 Address to file offset

The dynamic section stores virtual addresses (`DT_STRTAB`, `DT_SYMTAB`, `DT_VERNEED`, …). You need file offsets.

```
for each PT_LOAD segment L, in program-header order:
    if vaddr >= L.p_vaddr and vaddr - L.p_vaddr < L.p_filesz:
        return L.p_offset + (vaddr - L.p_vaddr)
return NOT_MAPPED
```

Notes that matter:
- Use `p_filesz`, not `p_memsz`. The region between `p_filesz` and `p_memsz` is `.bss` and has no file bytes.
- Test `vaddr - L.p_vaddr < L.p_filesz` after checking `vaddr >= L.p_vaddr`. Never compute `L.p_vaddr + L.p_filesz` first — it can overflow, and a crafted binary will make it overflow.
- If two `PT_LOAD`s claim the same address, the **first** wins. Emit `OB0004` (info) noting the overlap.
- If the result is outside the file buffer, that is `NOT_MAPPED`, not a valid offset.

### 6.2 Symbol-version strings

A version string from `.gnu.version_r` looks like `FAMILY_REST`. Split at the **first** `_`.

Parsing rules:

1. If there is no `_`, family is the whole string and there is no numeric version.
2. `REST` is numeric if and only if it consists of decimal digit groups separated by single `.`, with no leading `.`, no trailing `.`, no empty group, and each group ≤ 9 digits.
3. If `REST` is not numeric, the requirement is **non-numeric**: record it, do not compare it, and handle it per the table below.

Comparison of two numeric versions: compare component by component as integers; a missing component counts as 0. So `2` == `2.0` == `2.0.0`, and `2.9 < 2.10`.

**This exact table must appear as test cases** (`t_ver.c`):

| Input | Family | Numeric? | Components | Note |
|---|---|---|---|---|
| `GLIBC_2.2.5` | `GLIBC` | yes | 2,2,5 | the common baseline symbol |
| `GLIBC_2.9` | `GLIBC` | yes | 2,9 | must compare **less than** `GLIBC_2.10` |
| `GLIBC_2.10` | `GLIBC` | yes | 2,10 | the lexical-sort trap |
| `GLIBC_2.28` | `GLIBC` | yes | 2,28 | |
| `GLIBC_2.34` | `GLIBC` | yes | 2,34 | |
| `GLIBC_PRIVATE` | `GLIBC` | no | — | ignore for the max computation; emit `OB0024` info |
| `GLIBC_ABI_DT_RELR` | `GLIBC` | no | — | **not** a version. Emit `OB0022` warn: it implies glibc ≥ 2.36 regardless of baseline |
| `GLIBCXX_3.4.29` | `GLIBCXX` | yes | 3,4,29 | libstdc++ was linked dynamically; emit `OB0023` |
| `CXXABI_1.3.9` | `CXXABI` | yes | 1,3,9 | same |
| `GCC_3.0` | `GCC` | yes | 3,0 | libgcc_s dynamic; emit `OB0023` |
| `GCC_4.2.0` | `GCC` | yes | 4,2,0 | |
| `LIBXML2_2.6.0` | `LIBXML2` | yes | 2,6,0 | third-party versioned lib |
| `_2.0` | `` (empty) | yes | 2,0 | degenerate but legal input; must not crash |
| `GLIBC_` | `GLIBC` | no | — | empty REST |
| `GLIBC_2.` | `GLIBC` | no | — | trailing dot |
| `GLIBC_.2` | `GLIBC` | no | — | leading dot |
| `GLIBC_2..3` | `GLIBC` | no | — | empty group |
| `GLIBC_2.1a` | `GLIBC` | no | — | non-digit |
| `GLIBC_9999999999.1` | `GLIBC` | no | — | group longer than 9 digits; reject rather than overflow |
| `` (empty string) | `` | no | — | must not crash |

Also test the comparator directly on: `(2.2.5, 2.3) → -1`, `(2.9, 2.10) → -1`, `(2.28, 2.28) → 0`, `(2.28.1, 2.28) → +1`, `(2, 2.0) → 0`, `(3, 2.99) → +1`.

### 6.3 Highest required glibc version

Walk `.gnu.version_r` (see `02-REFERENCE-elf.md §7`). For every `Verneed` whose `vn_file` string is in `{libc.so.6, libm.so.6, libpthread.so.0, libdl.so.2, librt.so.1, libresolv.so.2, libutil.so.1, libcrypt.so.1, libanl.so.1, ld-linux-x86-64.so.2, ld-linux-aarch64.so.1, ld-linux.so.2}`, take every `Vernaux` name, parse it per §6.2, and keep the maximum numeric `GLIBC_*` version.

Requirements from other files, and non-`GLIBC` families from glibc files, are collected separately and reported as `OB0023`/`OB0024` rather than folded into the maximum.

If there is no `.gnu.version_r` at all, the highest required version is *unknown*, not zero. Report it as `null` in JSON and as `none` in text, and do not fail `OB0020` on it.

### 6.4 Dynamic symbol count

Needed only for listing which symbols caused a version requirement (`OB0021`). There is no `DT_SYMSZ`, so derive the count in this order and stop at the first that works:

1. **`DT_HASH`** — at its address: `nbucket` (u32), `nchain` (u32). `nchain` **is** the symbol count. Cheapest and exact.
2. **Section headers**, if present and not stripped: find the section whose type is `SHT_DYNSYM` and compute `sh_size / sh_entsize`.
3. **`DT_GNU_HASH`** — algorithm in `02-REFERENCE-elf.md §8`. Fiddly; implement it, but treat a failure as non-fatal.
4. **Give up.** Emit `OB0025` (info): "symbol table size unknown; per-symbol attribution unavailable". Everything else still works.

Whatever the source, clamp the count so that `count * syment` fits in the mapped region, and cap it at `ONEBIN_MAX_SYMS` (1,000,000). A crafted `nchain` of `0xFFFFFFFF` must not cause a billion-iteration loop.

### 6.5 String scan

Several checks need "does this byte sequence appear as a printable string in the file". Implement one scanner used by all of them:

- Walk the whole buffer once. A *string* is a maximal run of bytes in `0x20..0x7E` of length ≥ 4, terminated by a byte outside that range or by end of buffer.
- Cap individual strings at 4096 bytes; longer runs are split.
- Do **not** try to restrict the scan to `.rodata`. Section headers may be absent, and the point is to catch things wherever they are.
- The scanner takes a callback so no list of all strings is ever materialised. A 400 MiB binary must not produce a 400 MiB allocation.

---

## 7. The checks

Every check emits zero or more findings. No check may abort the audit.

### 7.1 `needed` — DT_NEEDED allowlist

Default allowlist (exact soname match, case-sensitive):

```
ld-linux-x86-64.so.2   ld-linux-aarch64.so.1   ld-linux-armhf.so.3
ld-linux.so.2          ld-linux-riscv64-lp64d.so.1
libc.so.6              libm.so.6
libdl.so.2             libpthread.so.0        librt.so.1
```

- Each `DT_NEEDED` not on the allowlist and not added by `--allow`: `OB0010` **error**, subject = the soname.
- `libgcc_s.so.1`: special-cased to `OB0012` **warn**, not `OB0010`, with the message that glibc `dlopen`s it for unwinding and `pthread_cancel` even under `-static-libgcc`, so its presence is common but should be understood.
- `libstdc++.so.6`: `OB0013` **error** with a message pointing at `-static-libstdc++`. This deserves its own message because it is the single most common mistake.
- No `DT_NEEDED` at all: `OB0011` **info**, "fully static".
- A duplicate soname appearing twice: report once, note the count in the message.

### 7.2 `glibc` — baseline

- Highest required `GLIBC_x.y` > `--glibc-max`: `OB0020` **error**. The message names both versions.
- For each offending symbol found via §6.4: `OB0021` **info**, subject = `symbolname@GLIBC_x.y`. Cap at 20 findings and note the total.
- `GLIBC_ABI_DT_RELR` required: `OB0022` **warn**.
- Non-glibc versioned requirements (`GLIBCXX`, `CXXABI`, `GCC`, others): `OB0023` **warn** — they mean a library you should have linked statically is dynamic.
- `GLIBC_PRIVATE` required: `OB0024` **error**. This is never legitimate in a redistributable binary; it pins the exact glibc build.
- Symbol count unknown: `OB0025` **info**.

### 7.3 `profile` — profile conformance

Auto-detection: Profile S if there is no `PT_INTERP` **and** no `DT_NEEDED`; otherwise Profile H. `--profile` overrides.

Profile S checks:
- `PT_INTERP` present: `OB0030` **error**.
- Any `DT_NEEDED`: `OB0031` **error**.
- `e_type == ET_EXEC`: `OB0032` **warn** — static but not PIE, so no ASLR; recommend `-static-pie`. (`ET_DYN` with no `PT_INTERP` is a correct static-PIE and must **not** warn. This is the single most likely place for you to produce a false positive — test it explicitly.)
- Evidence of `dlopen`: `OB0033` **error**. Detection, in order:
  1. A `.symtab` is present and contains a symbol named `dlopen` → positive.
  2. The string `Dynamic loading not supported` appears → positive (this is musl's static stub message).
  3. The string `dlopen` appears as a standalone string → **weak** positive; emit `OB0033` at severity **warn** instead of error, with a message saying the evidence is a string match.
  4. Otherwise: `OB0035` **info**, "binary is stripped; dlopen usage could not be determined".
- Evidence of statically linked glibc: `OB0034` **error**. Detection: no `DT_NEEDED`, **and** any of the strings `/etc/nsswitch.conf`, `libnss_`, `__nss_module` appear.

Profile H checks:
- No `PT_INTERP`: `OB0036` **error** (you asked for hybrid and got something else).
- `PT_INTERP` string not in the known-interpreter list for the machine: `OB0037` **warn**.

### 7.4 `rpath` — search paths

Read `DT_RPATH` (tag 15) and `DT_RUNPATH` (tag 29) as `:`-separated lists.

- Any component that does not start with `$ORIGIN` or `${ORIGIN}`: `OB0040` **error**, subject = that component.
- Any component that does start with `$ORIGIN`: `OB0041` **warn**.
- `DT_RPATH` present at all (as opposed to `DT_RUNPATH`): `OB0042` **warn** — it is ignored by the loader when `DT_RUNPATH` is also present, and it cannot be overridden by `LD_LIBRARY_PATH`.
- An empty component (`::`, leading or trailing `:`) means "current directory": `OB0043` **error**.

### 7.5 `harden` — hardening

| Condition | Finding | Severity |
|---|---|---|
| No `PT_GNU_RELRO` segment | `OB0050` | error |
| No BIND_NOW: none of `DT_BIND_NOW` (24), `DT_FLAGS & DF_BIND_NOW (0x8)`, `DT_FLAGS_1 & DF_1_NOW (0x1)` | `OB0051` | error |
| `PT_GNU_STACK` present with `PF_X` set | `OB0052` | error |
| No `PT_GNU_STACK` segment at all | `OB0053` | warn |
| `e_type == ET_EXEC` in Profile H | `OB0054` | warn |
| `DT_TEXTREL` (22) present, or `DT_FLAGS & DF_TEXTREL (0x4)` | `OB0055` | error |

`OB0050` and `OB0051` are skipped entirely when there is no `PT_DYNAMIC` (a fully static non-PIE binary has no dynamic section and RELRO is not applicable). Skipping must be visible: emit `OB0056` **info** saying why.

### 7.6 `hygiene` — leaked build state

Using the §6.5 string scanner:

- A string beginning with `/home/`, `/root/`, `/build/`, `/Users/`, `/tmp/`, or `/var/tmp/`: `OB0060` **warn**, subject = the string, truncated to 120 characters. Cap at 10 findings, note the total. Message recommends `-ffile-prefix-map`.
- A string containing `/usr/lib/x86_64-linux-gnu/`, `/usr/lib/aarch64-linux-gnu/`, `/usr/lib64/`, `/nix/store/`, or `/opt/rh/`: `OB0061` **warn**.
- Section headers present and any section name begins with `.debug_`: `OB0062` **info**, "debug info not stripped", with the total size of those sections.
- `.gnu_debuglink` section present: `OB0063` **info** (this is the good pattern — stripped with a separate symbol file).

### 7.7 `host` — the host contract

Scan for strings matching these, anchored at the start of a string:

```
libGL.so     libGLX.so       libGLESv2.so   libEGL.so      libOpenGL.so
libvulkan.so libcuda.so      libnvidia-ml.so
libOpenCL.so libva.so        libvdpau.so
libasound.so libpulse.so     libpipewire-0.3.so   libjack.so
libudev.so
```

- Match: `OB0070` **info**, subject = the string.
- A string matching `^lib[A-Za-z0-9_+.-]+\.so(\.[0-9]+)*$` that is **not** in the list above, **not** in the `DT_NEEDED` allowlist, and **not** an actual `DT_NEEDED` entry: `OB0071` **warn** — "appears to dlopen a library outside the host contract". Cap at 20.

Implement the pattern check by hand. Do not write a regex engine.

### 7.8 `meta` — level 3 only

- `--level 3` and no file named `sbom.cdx.json` or `sbom.spdx.json` in the same directory as the audited file: `OB0080` **error**.

---

## 8. Finding ID registry

Every ID is permanent. Never reuse one for a different meaning.

| ID | Check | Default severity | Subject |
|---|---|---|---|
| `OB0001` | `elf.notelf` | fatal | — |
| `OB0002` | `elf.class` | fatal | class byte |
| `OB0003` | `elf.truncated` | fatal | structure name |
| `OB0004` | `elf.overlap` | info | vaddr |
| `OB0005` | `elf.shared` | info | soname |
| `OB0010` | `needed.allowlist` | error | soname |
| `OB0011` | `needed.none` | info | — |
| `OB0012` | `needed.libgcc` | warn | — |
| `OB0013` | `needed.libstdcxx` | error | — |
| `OB0020` | `glibc.max` | error | version |
| `OB0021` | `glibc.symbol` | info | `sym@ver` |
| `OB0022` | `glibc.abi_relr` | warn | — |
| `OB0023` | `verreq.other` | warn | `file:VERSION` |
| `OB0024` | `glibc.private` | error | — |
| `OB0025` | `glibc.symcount` | info | — |
| `OB0030` | `profile.interp` | error | interp path |
| `OB0031` | `profile.needed` | error | soname |
| `OB0032` | `profile.nopie` | warn | — |
| `OB0033` | `profile.dlopen` | error / warn | evidence |
| `OB0034` | `profile.staticglibc` | error | evidence |
| `OB0035` | `profile.stripped` | info | — |
| `OB0036` | `profile.nointerp` | error | — |
| `OB0037` | `profile.interp_unknown` | warn | interp path |
| `OB0040` | `rpath.absolute` | error | path component |
| `OB0041` | `rpath.origin` | warn | path component |
| `OB0042` | `rpath.legacy` | warn | — |
| `OB0043` | `rpath.empty` | error | — |
| `OB0050` | `harden.relro` | error | — |
| `OB0051` | `harden.bindnow` | error | — |
| `OB0052` | `harden.execstack` | error | — |
| `OB0053` | `harden.nostack` | warn | — |
| `OB0054` | `harden.nopie` | warn | — |
| `OB0055` | `harden.textrel` | error | — |
| `OB0056` | `harden.na` | info | — |
| `OB0060` | `hygiene.buildpath` | warn | string |
| `OB0061` | `hygiene.distropath` | warn | string |
| `OB0062` | `hygiene.debuginfo` | info | size |
| `OB0063` | `hygiene.debuglink` | info | — |
| `OB0070` | `host.contract` | info | soname |
| `OB0071` | `host.unknown` | warn | soname |
| `OB0080` | `meta.sbom` | error | — |
| `OB0090` | `io.open` | fatal | path |
| `OB0091` | `io.nottype` | fatal | path |
| `OB0092` | `io.toolarge` | fatal | size |
| `OB0093` | `io.read` | fatal | path |

`fatal` means: report it, produce no audit result for that file, exit 2.

---

## 9. Output

### 9.1 Text format

```
== build/fixtures/hybrid-ok.elf ==
  profile: hybrid (auto-detected)   class: ELF64 LE x86_64 ET_DYN
  interp:  /lib64/ld-linux-x86-64.so.2
  needed:  libc.so.6 libm.so.6
  glibc:   requires 2.28, baseline 2.28

  ok    OB0011  all DT_NEEDED entries are on the allowlist
  warn  OB0041  RUNPATH is $ORIGIN-relative: $ORIGIN/../lib
  FAIL  OB0051  no BIND_NOW (add -Wl,-z,now)

PASS  Level 1  (0 errors, 1 warning, 3 infos)
```

Rules:
- One line per finding, `severity  ID  message`.
- Severity column is fixed width: `ok  `, `info`, `warn`, `FAIL`.
- The final line is `PASS`/`FAIL`, the level, and the counts.
- Info findings are hidden unless `--verbose`.
- With `--quiet`, print only the final line and `FAIL` lines.
- Colour, when enabled: green for `ok`, yellow for `warn`, red for `FAIL`, default for `info`. Nothing else is coloured.

### 9.2 JSON format

Keys appear in exactly this order. This is a hard requirement — golden tests compare bytes.

```json
{
  "schema": 1,
  "file": "build/fixtures/hybrid-ok.elf",
  "format": "elf",
  "class": 64,
  "endian": "little",
  "machine": "x86_64",
  "type": "ET_DYN",
  "profile": "hybrid",
  "profile_source": "auto",
  "interp": "/lib64/ld-linux-x86-64.so.2",
  "soname": null,
  "needed": ["libc.so.6", "libm.so.6"],
  "runpath": ["$ORIGIN/../lib"],
  "rpath": [],
  "glibc_required": "2.28",
  "glibc_baseline": "2.28",
  "version_requirements": [
    { "file": "libc.so.6", "versions": ["GLIBC_2.2.5", "GLIBC_2.28"] }
  ],
  "level": 1,
  "result": "fail",
  "counts": { "error": 1, "warn": 1, "info": 3 },
  "findings": [
    {
      "id": "OB0051",
      "check": "harden.bindnow",
      "severity": "error",
      "subject": "",
      "message": "no BIND_NOW (add -Wl,-z,now)",
      "fingerprint": "OB0051:"
    }
  ]
}
```

Formatting rules:
- Two-space indent, `": "` after keys, no trailing whitespace, exactly one `\n` at end of file.
- Arrays of scalars print inline if the total line stays under 100 columns, otherwise one element per line. **Pick one and apply it mechanically** — if that rule is hard to implement deterministically, always use one element per line for arrays of length ≥ 4 and inline otherwise, and write your choice in `NOTES.md`.
- `null` for absent scalars, `[]` for absent arrays. Never omit a key.
- `findings` is sorted by `(id, subject, message)`, byte-wise, `LC_ALL=C`.
- `version_requirements` is sorted by `file`; `versions` within it sorted by version string byte-wise.

### 9.3 String sanitisation

**Every string that came from the audited file must be sanitised before it reaches any output.** A hostile binary can put arbitrary bytes, ANSI escapes, or newlines in a `DT_NEEDED` entry.

Rule: replace every byte outside `0x20..0x7E` with `?`. If any byte was replaced, append ` [sanitised]` to the message. Truncate to 200 bytes, appending `...` if truncated.

Only then apply JSON escaping (`"` → `\"`, `\` → `\\`). Because sanitisation already removed control characters, JSON escaping only ever has to handle those two.

### 9.4 Baseline files

```
# onebin baseline v1
# generated by: onebin audit --write-baseline
OB0041:$ORIGIN/../lib
OB0060:/home/builder/src/main.c
```

- Line-based, one fingerprint per line, `#` comments, blank lines ignored.
- Sorted, byte-wise.
- Loading: any finding whose fingerprint is in the file is dropped before counting and before reporting, and the count of suppressed findings is printed in the final line and included in JSON as `"suppressed": N`.
- A fingerprint in the file that matched nothing is `OB0100` **info** ("stale baseline entry"), so baselines get cleaned up rather than accumulating forever.

---

## 10. Constants you must define yourself

Put these in `src/audit/limits.h`:

```
ONEBIN_MAX_FILE       536870912   /* 512 MiB */
ONEBIN_MAX_PHNUM          65535
ONEBIN_MAX_SHNUM          65535
ONEBIN_MAX_DYNENT         65536
ONEBIN_MAX_NEEDED          4096
ONEBIN_MAX_VERNEED         4096
ONEBIN_MAX_VERNAUX        65536
ONEBIN_MAX_SYMS         1000000
ONEBIN_MAX_STRING          4096
ONEBIN_MAX_FINDINGS       10000
```

Every loop that iterates over file-controlled data must be bounded by one of these **and** by the size of the region it is walking. Two independent bounds, always.

---

## 11. Non-goals for v0.1

Explicitly do not implement: PE, Mach-O, `--fix`, colour themes, config files, `onebin sign`, `onebin release`, `onebin pack`, network anything, parallelism, progress bars, a plugin system, or a library interface for third parties. If you have time left, write more tests.

---

## 12. Ambiguity resolutions

Consult this before deciding anything yourself.

| Situation | Decision |
|---|---|
| File is ET_REL (`.o`) or ET_CORE | `OB0001` fatal, exit 2. v0.1 audits executables and shared objects only. |
| File is a shared library (`ET_DYN` + `DT_SONAME` + no `PT_INTERP`) | Audit it, emit `OB0005` info, skip `profile` checks entirely, keep everything else. |
| `PT_DYNAMIC` present but `DT_STRTAB` missing or unmapped | All string-dependent checks emit nothing; emit `OB0003` non-fatally with subject `DT_STRTAB`, and continue. |
| `e_phnum == 0xFFFF` (PN_XNUM, real count in section header 0) | Support it if section headers exist; otherwise `OB0003` fatal. Test both. |
| Both `DT_RPATH` and `DT_RUNPATH` present | Check both, emit `OB0042`. |
| Multiple `PT_INTERP` segments | Use the first, emit `OB0003` info with subject `PT_INTERP`. |
| `DT_NEEDED` string offset ≥ `DT_STRSZ` | Skip that entry, emit `OB0003` non-fatally with subject `DT_NEEDED`. |
| String table's last byte is not NUL | Treat reads that would run past the end as failures; emit `OB0003` once. |
| Same finding produced twice with identical fingerprint | Deduplicate; keep the first; do not increment counts twice. |
| More than `ONEBIN_MAX_FINDINGS` findings | Stop adding, emit `OB0101` warn ("finding limit reached"), continue the audit so the verdict is still correct. |
| Big-endian ELF | Fully supported. Every parse path must work; tests cover it. |
| ELF32 | Fully supported. |
| Unknown `e_machine` | Report the numeric value as `"machine": "0x1234"`; do not fail. |
| `--level 0` | Run only `needed` and `glibc`. |
| `--level 2` | Same checks as level 1 (level 2 is about runtime behaviour, which a static audit cannot see). Emit `OB0102` info saying so. |
| Audited file is a symlink | Follow it; report the path as given on the command line. |
| Two paths on the command line resolve to the same file | Audit twice; do not deduplicate. |
