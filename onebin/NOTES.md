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
