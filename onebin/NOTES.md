# onebin — Implementation Notes & Decision Log

## Decisions

- **util/buf (`ob_rdstr`)**: If `dstsz` is too small to hold the full string plus its NUL terminator, `ob_rdstr` fails with `-1` (instead of truncating) and sets `dst[0] = '\0'`.
- **elf_const.h created in Task 4, not Task 5**: the fixture generator needs ELF
  constants before the parser exists. Duplicating them in `tests/` would have
  meant two copies that can disagree, which is exactly the failure rule 3 is
  meant to prevent. Task 5 extends the file; nothing in it is removed.
- **mkelf reserves symbol index 0**: `eg_add_dynsym` appends after an
  automatically emitted null symbol, so a fixture with N added symbols has N+1
  `.dynsym` entries and N+1 `.gnu.version` entries. Real linkers do this and the
  hash-table walks assume it; making callers remember would produce fixtures
  that are subtly unlike anything the tool will meet.
- **mkelf region alignment**: 03-TESTPLAN.md §3 gives the region order but not
  their alignment. Each region starts 8-byte aligned on ELF64 and 4-byte on
  ELF32, so the parser is never asked to do an unaligned read that a real linker
  would not produce. Tests use `eg_off()`/`eg_size()` rather than hardcoding.
- **`.hash` and `.gnu.hash` placement**: not named in the §3 layout. They go
  directly after `.dynsym`, before `.gnu.version`, since that is where a real
  linker puts them and `eg_set_hash_style` needs somewhere to write.
- **Four API additions to §3**, all needed to reproduce the worked example in
  02-REFERENCE-elf.md §9 (`eg_set_entry`, `eg_set_pad_to`, `eg_set_load_flags`)
  or to build a static-PIE, which has a `PT_DYNAMIC` containing nothing else
  worth naming (`eg_force_dynamic`). Documented in `mkelf.h`.
- **`eg_size()` added** alongside `eg_off()`: tests that check a region's
  contents need its length, and deriving it from the next region's offset breaks
  as soon as alignment padding exists.
- **Allocation failure in mkelf aborts** rather than returning an error. This is
  test-support code; a fixture that comes out silently wrong makes the suite
  pass for the wrong reason, which is worse than a crash.
- **audit.sh profile ladder (Task 13)**: implemented from 01-SPEC-audit.md §7.3,
  with one addition the C tool does not have — binutils >= 2.35 prints "Shared
  object file" vs "Position-Independent Executable file" in the ELF header, so
  the shell script uses that as a rung before falling back to the ambiguous
  case. `readelf` output is not a stable interface, so this is a hint that
  improves the answer when present and is skipped when absent, never a check
  that can fail.
- **Task 7 report/reporter design**, several ambiguities `01-SPEC-audit.md`
  leaves to the implementer, resolved here:
  - **`OB_SEV_OK` findings are always shown in text output**, not hidden by
    `--verbose` the way `OB_SEV_INFO` is. §9.1's own worked example shows an
    `ok  OB0011  ...` line with no `--verbose` in sight, which only makes
    sense if "info findings are hidden unless verbose" is read as scoped
    literally to `OB_SEV_INFO` and not to `OB_SEV_OK`. Both severities still
    fold into the single "info" bucket for the summary counts and JSON
    `counts.info` — there is no separate "oks" count anywhere in the
    schema, and §9.1's example totals only work out (1 visible `ok` line,
    "3 infos" in the summary) if `ok` counts alongside true `info`.
  - **`"suppressed"` is always a top-level JSON key**, defaulting to 0,
    placed right after `"counts"`. §9.2's own example predates §9.4's
    baseline discussion and doesn't show it; `t_baseline.c`'s "`\"suppressed\":
    N` appears in JSON" requirement does need it somewhere, and "never omit
    a key" (§9.2's own formatting rule) argues for always-present over
    conditionally-present.
  - **Array inline-vs-multiline threshold**: §9.2 explicitly permits
    picking the simpler deterministic fallback it describes rather than the
    100-column rule. This project uses exactly that fallback — inline for
    length ≤ 3, one element per line for length ≥ 4 — implemented as
    `OB_JSON_ARRAY_INLINE_MAX` in `audit/report_json.c`.
  - **Baseline line trimming** (`audit/baseline.c`) strips trailing spaces
    and tabs in addition to `\r`/`\n`, beyond what §9.4's text literally
    says, because `03-TESTPLAN.md §4.8`'s "trailing whitespace" test case
    for baseline files only makes sense as a positive match, not a
    documented near-miss.
  - **`util/json.h`'s `ob_jbuf` is a plain growable buffer**, not a
    JSON-specific stateful builder — `audit/report_json.c` hand-assembles
    the fixed, known §9.2 schema directly (the array-inlining rule needs to
    see a whole array before deciding its layout anyway, which a generic
    streaming builder can't do without buffering the same way). The only
    genuinely reusable, easy-to-get-wrong pieces are string escaping and
    buffer growth, so those are what `util/json.c` owns — and
    `audit/report_text.c` reuses the same buffer type for plain text, since
    "one copy" applies to growable-buffer code as much as anywhere else.
- **Task 8, `c_profile.c`'s OB0035 is deliberately not implemented as an
  unconditional fallback.** 01-SPEC-audit.md §7.3's dlopen-evidence tier 4
  ("Otherwise: OB0035 info, binary is stripped") needs a parsed
  `SHT_SYMTAB` (the *static* symbol table — unrelated to `DT_SYMTAB`, which
  Profile S binaries don't have at all) to tell "confirmed no dlopen" apart
  from "stripped, can't tell". v0.1's elf/ layer doesn't parse `SHT_SYMTAB`
  (section headers are an optional bonus view, 02-REFERENCE-elf.md §1), so
  this check cannot honestly make that distinction yet, and
  03-TESTPLAN.md §4.3 #1 is explicit that a clean static fixture must
  produce zero findings — "the false-positive test that matters most".
  Emitting OB0035 unconditionally would fail that on every clean fixture
  this project's own generator can build. Deferred rather than faked;
  §4.3 #10 needs this to become fully meaningful.
- **`OB_STR_MAXLEN` (200, the *sanitised display* cap) is not
  `ONEBIN_MAX_STRING` (4096, the *raw read* cap), and a check that sizes its
  scratch buffer for `ob_dynamic_string`/`ob_rdstr` by the former instead of
  the latter fails silently on any real string longer than 200 bytes** —
  `ob_dynamic_string` returns `OB_STR_NO_NUL` because it can't fit the NUL
  inside the too-small `dstsz`, and a check that only acts on `OB_STR_OK`
  just produces no finding, not a crash, which makes the bug easy to miss
  in ordinary testing. Caught by `tests/t_checks_rpath.c`'s 500-component
  case (03-TESTPLAN.md §4.4 #11) silently producing zero findings.
  Every raw-string scratch buffer in `src/audit/checks/*.c` now sizes
  itself `ONEBIN_MAX_STRING + 1`; `OB_STR_MAXLEN` is reserved for buffers
  that hold an already-sanitised value (there are none of those left in
  this codebase — sanitisation happens inside `ob_report_add_finding`
  itself, so a check never needs to size for it directly).
- **Task 8: `c_hygiene.c` and `c_host.c` are the second place (besides
  `elf/symbols.c`'s `SHT_DYNSYM` lookup) this project reads the
  section-header array.** Still "optional bonus" (02-REFERENCE-elf.md §1):
  absent section headers just mean OB0062/OB0063 don't fire, never a crash
  (03-TESTPLAN.md §4.6 #12).
- **`c_host.c`'s hand-written matcher for
  `^lib[A-Za-z0-9_+.-]+\.so(\.[0-9]+)*$`** strips trailing `.<digits>`
  groups from the end, greedily, stopping at the first group that isn't
  all-digits, then requires exactly `.so` with at least one class-valid
  byte before it. This never needs backtracking: a numeric group's content
  is pure digits, so it can never itself contain the `.so` boundary the
  match needs, meaning the greedy strip from the end always lands on the
  same split a backtracking regex engine would find.
- **`audit/audit.c` is the only layer that touches the filesystem** (reads
  the file, never mmaps it, per `01-SPEC-audit.md §3.2`) and the only one
  that can produce the fatal `elf.*`/`io.*` findings (`OB0001-0003`,
  `OB0090-0093`). Everything below it — `elf/*`, `audit/checks/*` — only
  ever sees an already-loaded in-memory buffer, which is what let every
  earlier task's tests build fixtures with `mkelf` directly instead of
  writing temp files.
- **`ob_glibc_compute_max()` is exported from `c_glibc.c` as a pure,
  findings-free function** so `audit.c` can populate
  `ob_report.glibc_required` without a second copy of the verneed
  classification walk. It duplicates the "is this a qualifying GLIBC_x.y
  requirement" *test* (a few lines) but not the finding-emission logic —
  an accepted, narrow, read-only duplication, documented at its
  definition.
- **`--write-baseline` aggregates findings across every file given on the
  command line into one baseline**, sorted and deduped, then exits 0
  without printing a normal report — 01-SPEC-audit.md §5.2 describes the
  option per-invocation, not per-file, and a single baseline file is the
  only reading that lets `--baseline` (loaded once, applied per file)
  round-trip against it.
- **`--max-file` is accepted and validated but not yet wired to
  `ob_audit_options`** — `ob_audit_file` still enforces the fixed
  `ONEBIN_MAX_FILE` (512 MiB) regardless of this flag. Flagged rather than
  silently dropped: the option parses and rejects negative values, so
  scripts using it don't get a usage error, but the value has no effect
  yet. Needs a `max_file` field on `ob_audit_options` plumbed through to
  the `OB0092` size check in `audit/audit.c`.
- **`tests/t_cli.c` spawns the plain (non-sanitizer) `build/onebin`**
  regardless of which `make test*` target is running — `make test-asan`/
  `test-ubsan` still exercise every check function directly through the
  other test files, `t_cli.c` only spot-checks argument parsing and exit
  codes via subprocess, which is not meaningfully improved by sanitizing
  the child process for that purpose.
- **`t_malformed.c` was not written as a separate consolidated file.** All
  35 numbered cases from `03-TESTPLAN.md §5.6` already live as individual,
  named tests across `t_dynamic.c`, `t_verneed.c` and `t_symbols.c`
  (written during Task 6, before Task 10 existed) — each with a comment
  explaining what it exercises and why, which a single enumerated corpus
  file would have had to reconstruct anyway. Duplicating them into a
  second file would drift from the originals rather than protect anything
  further; the fuzzer (`tests/fuzz.c`) is where new coverage of this kind
  now belongs, per its own gate ("every crash becomes a permanent
  regression test").
- **`tests/fuzz.c`'s corpus is not literally "every preset × {32,64} ×
  {LE,BE}"** as `03-TESTPLAN.md §6` describes, because `mkelf`'s preset
  functions (`eg_preset_hybrid_ok` etc.) are not class/endian-parameterised
  — extending them to be would be a `tests/mkelf.c` change, out of this
  task's scope. The corpus instead combines the five presets as-is with
  four manually built ELF32/64 × LE/BE variants covering the same
  structural shape (`DT_NEEDED`, `DT_VERNEED` with two versions, one
  versioned dynsym entry, both hash styles, RELRO, `DF_1_NOW|DF_1_PIE`,
  `PT_GNU_STACK`). Nine seed entries total; every mutation still explores
  all four class/endian combinations because they're present in the seed
  corpus, just not crossed with every preset individually.
