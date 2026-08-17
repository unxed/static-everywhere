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
