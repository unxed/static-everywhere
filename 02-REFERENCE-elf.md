# REFERENCE — ELF, everything you need and nothing you don't

**You have no internet access. This file is your ELF specification.** Every structure layout, every constant value, and every algorithm the tool needs is written out below. Copy the constants into `src/elf/elf_const.h` verbatim.

If something is not in this file, `01-SPEC-audit.md` does not require it. Do not guess at values you half-remember — a wrong constant produces a tool that is confidently wrong, which is worse than one that refuses to run.

**Do not `#include <elf.h>`. Do not cast structs onto file bytes.** Read every field with the offsets in the tables below, through `ob_rd*` from `01-SPEC-audit.md §4`.

---

## 1. File shape

```
+---------------------------+  offset 0
| ELF header                |  64 bytes (ELF64) or 52 bytes (ELF32)
+---------------------------+
| program header table      |  e_phnum entries of e_phentsize bytes, at e_phoff
+---------------------------+
| ... sections / segments ...|
+---------------------------+
| section header table      |  e_shnum entries of e_shentsize bytes, at e_shoff
+---------------------------+  (may be absent in a stripped binary)
```

Two independent views of the same bytes:

- **Program headers (segments)** — what the kernel and the dynamic loader use at runtime. **Always present in an executable or shared object.** This is your primary view.
- **Section headers** — what the linker and debuggers use. **Can be removed entirely** and often is. Treat them as an optional bonus.

**Design consequence:** every check in `01-SPEC-audit.md` that can be answered from program headers must be. Only `hygiene.debuginfo`, `hygiene.debuglink`, and the fallback symbol count in §6.4 of the spec are permitted to require section headers.

---

## 2. `e_ident` — the first 16 bytes

| Offset | Name | Meaning |
|---|---|---|
| 0 | `EI_MAG0` | must be `0x7F` |
| 1 | `EI_MAG1` | must be `'E'` (0x45) |
| 2 | `EI_MAG2` | must be `'L'` (0x4C) |
| 3 | `EI_MAG3` | must be `'F'` (0x46) |
| 4 | `EI_CLASS` | 1 = `ELFCLASS32`, 2 = `ELFCLASS64`. 0 and anything else are invalid. |
| 5 | `EI_DATA` | 1 = `ELFDATA2LSB` (little endian), 2 = `ELFDATA2MSB` (big endian). 0 and anything else are invalid. |
| 6 | `EI_VERSION` | 1 = `EV_CURRENT`. Anything else: warn, keep going. |
| 7 | `EI_OSABI` | 0 = SysV/None, 3 = GNU/Linux, 9 = FreeBSD, 255 = Standalone. Informational only. |
| 8 | `EI_ABIVERSION` | informational |
| 9–15 | padding | should be zero; do not enforce |

**`EI_CLASS` and `EI_DATA` determine how you read every subsequent byte.** Read them first, set `ob_buf.c64` and `ob_buf.be`, then read everything else.

---

## 3. ELF header

### ELF64 — 64 bytes total

| Offset | Size | Field |
|---|---|---|
| 0 | 16 | `e_ident` |
| 16 | 2 | `e_type` |
| 18 | 2 | `e_machine` |
| 20 | 4 | `e_version` |
| 24 | 8 | `e_entry` |
| 32 | 8 | `e_phoff` |
| 40 | 8 | `e_shoff` |
| 48 | 4 | `e_flags` |
| 52 | 2 | `e_ehsize` |
| 54 | 2 | `e_phentsize` |
| 56 | 2 | `e_phnum` |
| 58 | 2 | `e_shentsize` |
| 60 | 2 | `e_shnum` |
| 62 | 2 | `e_shstrndx` |

### ELF32 — 52 bytes total

| Offset | Size | Field |
|---|---|---|
| 0 | 16 | `e_ident` |
| 16 | 2 | `e_type` |
| 18 | 2 | `e_machine` |
| 20 | 4 | `e_version` |
| 24 | 4 | `e_entry` |
| 28 | 4 | `e_phoff` |
| 32 | 4 | `e_shoff` |
| 36 | 4 | `e_flags` |
| 40 | 2 | `e_ehsize` |
| 42 | 2 | `e_phentsize` |
| 44 | 2 | `e_phnum` |
| 46 | 2 | `e_shentsize` |
| 48 | 2 | `e_shnum` |
| 50 | 2 | `e_shstrndx` |

Total 52 bytes. The offsets sum correctly: `50 + 2 == 52`. **Use that arithmetic as your check whenever you transcribe one of these tables** — if the last field's offset plus its size does not equal the stated total, you have dropped a field.

> **Common bug:** the six 2-byte fields at the tail are easy to transcribe with one omitted, which silently shifts every field after it. **Write a test asserting your ELF32 parser reads `e_phnum` from offset 44 and `e_shstrndx` from offset 50.**

### `e_type`

| Value | Name | Meaning |
|---|---|---|
| 0 | `ET_NONE` | invalid |
| 1 | `ET_REL` | relocatable object (`.o`) — reject per spec §12 |
| 2 | `ET_EXEC` | non-PIE executable |
| 3 | `ET_DYN` | shared object **or** PIE executable |
| 4 | `ET_CORE` | core dump — reject |

Distinguishing PIE from shared library when `e_type == ET_DYN`, in order:
1. `PT_INTERP` present → PIE executable.
2. `DT_FLAGS_1 & DF_1_PIE (0x08000000)` → PIE executable.
3. `DT_SONAME` present → shared library.
4. No `PT_INTERP`, no `DT_NEEDED` → static-PIE executable.
5. Otherwise → assume shared library.

### `e_machine` — only the ones you need to name

| Value | Name |
|---|---|
| 3 | `EM_386` |
| 8 | `EM_MIPS` |
| 20 | `EM_PPC` |
| 21 | `EM_PPC64` |
| 22 | `EM_S390` |
| 40 | `EM_ARM` |
| 62 | `EM_X86_64` |
| 183 | `EM_AARCH64` |
| 243 | `EM_RISCV` |
| 258 | `EM_LOONGARCH` |

Anything else: print as `"0x%04X"` and continue. Never fail on an unknown machine.

### Sanity checks on the header

- `e_ehsize` should be 64 (ELF64) or 52 (ELF32). If not, warn but continue using the fixed sizes above.
- `e_phentsize` must be exactly 56 (ELF64) or 32 (ELF32). If not, **do not parse program headers** — emit `OB0003` fatal. A mismatched entry size means every subsequent read is misaligned garbage.
- `e_shentsize` must be exactly 64 (ELF64) or 40 (ELF32), if section headers are present at all.
- `e_phoff + e_phnum * e_phentsize` must fit in the file. Compute with overflow checks.
- `e_phnum == 0xFFFF` means the real count is in `sh_info` of section header 0 (`PN_XNUM`). See spec §12.
- `e_shnum == 0` with `e_shoff != 0` means the real count is in `sh_size` of section header 0. Handle or refuse explicitly.
- `e_shstrndx == 0xFFFF` (`SHN_XINDEX`) means the real index is in `sh_link` of section header 0.

---

## 4. Program headers

### ELF64 `Elf64_Phdr` — 56 bytes

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | `p_type` |
| 4 | 4 | `p_flags` |
| 8 | 8 | `p_offset` |
| 16 | 8 | `p_vaddr` |
| 24 | 8 | `p_paddr` |
| 32 | 8 | `p_filesz` |
| 40 | 8 | `p_memsz` |
| 48 | 8 | `p_align` |

### ELF32 `Elf32_Phdr` — 32 bytes

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | `p_type` |
| 4 | 4 | `p_offset` |
| 8 | 4 | `p_vaddr` |
| 12 | 4 | `p_paddr` |
| 16 | 4 | `p_filesz` |
| 20 | 4 | `p_memsz` |
| 24 | 4 | `p_flags` |
| 28 | 4 | `p_align` |

> **`p_flags` is at offset 4 on ELF64 and offset 24 on ELF32.** This is not a typo and it is the most common bug in hand-written ELF parsers. A parser that gets this wrong will report every 32-bit binary as having an executable stack, or none. **Write a test for exactly this.**

### `p_type`

| Value | Name | You need it for |
|---|---|---|
| 0 | `PT_NULL` | skip |
| 1 | `PT_LOAD` | address→offset translation |
| 2 | `PT_DYNAMIC` | the dynamic section |
| 3 | `PT_INTERP` | profile detection |
| 4 | `PT_NOTE` | — |
| 5 | `PT_SHLIB` | reserved, unused |
| 6 | `PT_PHDR` | — |
| 7 | `PT_TLS` | — |
| `0x6474E550` | `PT_GNU_EH_FRAME` | — |
| `0x6474E551` | `PT_GNU_STACK` | NX check |
| `0x6474E552` | `PT_GNU_RELRO` | RELRO check |
| `0x6474E553` | `PT_GNU_PROPERTY` | — |
| `0x6474E553` | — | (same value; `PT_GNU_PROPERTY`) |

### `p_flags` bits

| Bit | Name |
|---|---|
| `0x1` | `PF_X` execute |
| `0x2` | `PF_W` write |
| `0x4` | `PF_R` read |

`PT_GNU_STACK` with `PF_X` set means an executable stack. Absent `PT_GNU_STACK` means the kernel falls back to a per-architecture default, which historically is executable — hence the warning in the spec rather than silence.

### `PT_INTERP`

The interpreter path is the NUL-terminated string at file offset `p_offset`, at most `p_filesz` bytes. Known interpreters:

```
x86_64   /lib64/ld-linux-x86-64.so.2
i386     /lib/ld-linux.so.2
aarch64  /lib/ld-linux-aarch64.so.1
armhf    /lib/ld-linux-armhf.so.3
riscv64  /lib/ld-linux-riscv64-lp64d.so.1
musl     /lib/ld-musl-x86_64.so.1  (and ld-musl-<arch>.so.1)
```

---

## 5. Section headers (optional view)

### ELF64 `Elf64_Shdr` — 64 bytes

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | `sh_name` (offset into the section-name string table) |
| 4 | 4 | `sh_type` |
| 8 | 8 | `sh_flags` |
| 16 | 8 | `sh_addr` |
| 24 | 8 | `sh_offset` |
| 32 | 8 | `sh_size` |
| 40 | 4 | `sh_link` |
| 44 | 4 | `sh_info` |
| 48 | 8 | `sh_addralign` |
| 56 | 8 | `sh_entsize` |

### ELF32 `Elf32_Shdr` — 40 bytes

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | `sh_name` |
| 4 | 4 | `sh_type` |
| 8 | 4 | `sh_flags` |
| 12 | 4 | `sh_addr` |
| 16 | 4 | `sh_offset` |
| 20 | 4 | `sh_size` |
| 24 | 4 | `sh_link` |
| 28 | 4 | `sh_info` |
| 32 | 4 | `sh_addralign` |
| 36 | 4 | `sh_entsize` |

Field order is identical between the two; only widths differ. (Contrast with `Elf*_Phdr` and `Elf*_Sym`, where the order differs.)

### `sh_type` values you need

| Value | Name |
|---|---|
| 0 | `SHT_NULL` |
| 1 | `SHT_PROGBITS` |
| 2 | `SHT_SYMTAB` |
| 3 | `SHT_STRTAB` |
| 4 | `SHT_RELA` |
| 5 | `SHT_HASH` |
| 6 | `SHT_DYNAMIC` |
| 7 | `SHT_NOTE` |
| 8 | `SHT_NOBITS` |
| 9 | `SHT_REL` |
| 11 | `SHT_DYNSYM` |
| `0x6FFFFFF6` | `SHT_GNU_HASH` |
| `0x6FFFFFFD` | `SHT_GNU_verdef` |
| `0x6FFFFFFE` | `SHT_GNU_verneed` |
| `0x6FFFFFFF` | `SHT_GNU_versym` |

Section names are read from the section header at index `e_shstrndx`: its `sh_offset` is the base, and each section's `sh_name` is a byte offset into it.

---

## 6. The dynamic section

Found via the `PT_DYNAMIC` program header: entries live at file offset `p_offset`, total `p_filesz` bytes. The array terminates at the first entry with `d_tag == DT_NULL (0)`, or at the end of the segment, whichever comes first. **Do not assume `DT_NULL` exists.**

### Entry layout

| Class | Entry size | `d_tag` offset/size | `d_un` offset/size |
|---|---|---|---|
| ELF64 | 16 | 0 / 8 | 8 / 8 |
| ELF32 | 8 | 0 / 4 | 4 / 4 |

`d_tag` is signed in the ABI but every tag you need is representable as an unsigned 32-bit value. Read it with `ob_rdaddr` and compare against the constants below as `uint64_t`. On ELF32, sign-extend nothing — the GNU tags like `0x6FFFFFFE` fit in 32 bits unsigned.

`d_un` is either `d_val` (a number) or `d_ptr` (a virtual address). Which one it is depends on the tag; the table says.

### `d_tag` values

| Value | Name | `d_un` is | Meaning |
|---|---|---|---|
| 0 | `DT_NULL` | — | end of array |
| 1 | `DT_NEEDED` | val | offset into `DT_STRTAB` of a needed soname |
| 2 | `DT_PLTRELSZ` | val | |
| 3 | `DT_PLTGOT` | ptr | |
| 4 | `DT_HASH` | ptr | SysV hash table — gives symbol count |
| 5 | `DT_STRTAB` | ptr | **address** of the dynamic string table |
| 6 | `DT_SYMTAB` | ptr | **address** of the dynamic symbol table |
| 7 | `DT_RELA` | ptr | |
| 8 | `DT_RELASZ` | val | |
| 9 | `DT_RELAENT` | val | |
| 10 | `DT_STRSZ` | val | **size in bytes** of the dynamic string table |
| 11 | `DT_SYMENT` | val | size of one symbol entry (24 on ELF64, 16 on ELF32) |
| 12 | `DT_INIT` | ptr | |
| 13 | `DT_FINI` | ptr | |
| 14 | `DT_SONAME` | val | offset into `DT_STRTAB` |
| 15 | `DT_RPATH` | val | offset into `DT_STRTAB`; `:`-separated |
| 16 | `DT_SYMBOLIC` | — | |
| 17 | `DT_REL` | ptr | |
| 18 | `DT_RELSZ` | val | |
| 19 | `DT_RELENT` | val | |
| 20 | `DT_PLTREL` | val | |
| 21 | `DT_DEBUG` | ptr | |
| 22 | `DT_TEXTREL` | — | presence means writable text relocations |
| 23 | `DT_JMPREL` | ptr | |
| 24 | `DT_BIND_NOW` | — | presence means immediate binding |
| 25 | `DT_INIT_ARRAY` | ptr | |
| 26 | `DT_FINI_ARRAY` | ptr | |
| 27 | `DT_INIT_ARRAYSZ` | val | |
| 28 | `DT_FINI_ARRAYSZ` | val | |
| 29 | `DT_RUNPATH` | val | offset into `DT_STRTAB`; `:`-separated |
| 30 | `DT_FLAGS` | val | bit flags, see below |
| 32 | `DT_PREINIT_ARRAY` | ptr | |
| 33 | `DT_PREINIT_ARRAYSZ` | val | |
| 35 | `DT_RELRSZ` | val | glibc ≥ 2.36 relative relocs |
| 36 | `DT_RELR` | ptr | |
| 37 | `DT_RELRENT` | val | |
| `0x6FFFFEF5` | `DT_GNU_HASH` | ptr | GNU hash table |
| `0x6FFFFFF0` | `DT_VERSYM` | ptr | `.gnu.version` array |
| `0x6FFFFFF9` | `DT_RELACOUNT` | val | |
| `0x6FFFFFFA` | `DT_RELCOUNT` | val | |
| `0x6FFFFFFB` | `DT_FLAGS_1` | val | bit flags, see below |
| `0x6FFFFFFC` | `DT_VERDEF` | ptr | `.gnu.version_d` |
| `0x6FFFFFFD` | `DT_VERDEFNUM` | val | |
| `0x6FFFFFFE` | `DT_VERNEED` | ptr | **address of `.gnu.version_r`** |
| `0x6FFFFFFF` | `DT_VERNEEDNUM` | val | number of `Verneed` entries |

### `DT_FLAGS` bits

| Bit | Name |
|---|---|
| `0x1` | `DF_ORIGIN` |
| `0x2` | `DF_SYMBOLIC` |
| `0x4` | `DF_TEXTREL` |
| `0x8` | `DF_BIND_NOW` |
| `0x10` | `DF_STATIC_TLS` |

### `DT_FLAGS_1` bits you need

| Bit | Name |
|---|---|
| `0x00000001` | `DF_1_NOW` |
| `0x00000008` | `DF_1_NODELETE` |
| `0x00000080` | `DF_1_ORIGIN` |
| `0x00000800` | `DF_1_NODEFLIB` |
| `0x08000000` | `DF_1_PIE` |

### Reading a string from the dynamic string table

```
strtab_vaddr = value of DT_STRTAB
strtab_size  = value of DT_STRSZ
strtab_off   = vaddr_to_offset(strtab_vaddr)          # §6.1 of the spec
if strtab_off == NOT_MAPPED: no strings are readable

string_at(idx):
    if idx >= strtab_size: FAIL
    read a NUL-terminated string at (strtab_off + idx),
      bounded by min(strtab_size - idx, ONEBIN_MAX_STRING)
    if no NUL was found within the bound: FAIL
```

`DT_NEEDED`, `DT_SONAME`, `DT_RPATH` and `DT_RUNPATH` all hold **indices into this table**, not addresses.

---

## 7. Version requirements — `.gnu.version_r`

This is where the highest required glibc version comes from, and it is the only part of ELF parsing in this project that is genuinely intricate.

Located at `vaddr_to_offset(DT_VERNEED)`. There are `DT_VERNEEDNUM` top-level entries, but **you must also honour the `vn_next` chain** — trust whichever gives the smaller count.

### `Verneed` — 16 bytes, identical on ELF32 and ELF64

| Offset | Size | Field | Meaning |
|---|---|---|---|
| 0 | 2 | `vn_version` | must be 1 |
| 2 | 2 | `vn_cnt` | number of `Vernaux` entries that follow |
| 4 | 4 | `vn_file` | **offset into `DT_STRTAB`** of the soname, e.g. `libc.so.6` |
| 8 | 4 | `vn_aux` | **byte offset from the start of THIS `Verneed`** to the first `Vernaux` |
| 12 | 4 | `vn_next` | **byte offset from the start of THIS `Verneed`** to the next `Verneed`; 0 means last |

### `Vernaux` — 16 bytes, identical on ELF32 and ELF64

| Offset | Size | Field | Meaning |
|---|---|---|---|
| 0 | 4 | `vna_hash` | ignore |
| 4 | 2 | `vna_flags` | `0x2` = `VER_FLG_WEAK` |
| 6 | 2 | `vna_other` | version index; matches entries in `.gnu.version` |
| 8 | 4 | `vna_name` | **offset into `DT_STRTAB`** of the version string, e.g. `GLIBC_2.28` |
| 12 | 4 | `vna_next` | **byte offset from the start of THIS `Vernaux`** to the next; 0 means last |

### Walk algorithm

```
base = vaddr_to_offset(DT_VERNEED)
cur  = base
seen = 0
while seen < min(DT_VERNEEDNUM, ONEBIN_MAX_VERNEED):
    read Verneed at cur
    if vn_version != 1: emit OB0003, stop
    file = string_at(vn_file)

    aux    = cur + vn_aux
    naux   = 0
    while naux < min(vn_cnt, ONEBIN_MAX_VERNAUX):
        read Vernaux at aux
        version = string_at(vna_name)
        record (file, version, vna_other)
        naux += 1
        if vna_next == 0: break
        next_aux = aux + vna_next
        if next_aux <= aux: emit OB0003, stop        # cycle guard
        aux = next_aux

    seen += 1
    if vn_next == 0: break
    next_cur = cur + vn_next
    if next_cur <= cur: emit OB0003, stop            # cycle guard
    cur = next_cur
```

**The two cycle guards are mandatory.** `vn_next` and `vna_next` are attacker-controlled unsigned offsets. A value of 0 terminates; any value that does not strictly advance the cursor is malformed and must stop the walk. Without these guards a crafted file loops forever. `03-TESTPLAN.md §5.6` requires a test for each.

Every read inside the loop goes through `ob_rd*` and can fail; a failure ends the walk with `OB0003` and does not abort the audit.

### `.gnu.version` (`DT_VERSYM`)

An array of `uint16_t`, one per dynamic symbol, in the same order as `DT_SYMTAB`. Entry meanings:

| Value | Meaning |
|---|---|
| 0 | `VER_NDX_LOCAL` — local symbol |
| 1 | `VER_NDX_GLOBAL` — global, unversioned |
| ≥ 2 | index matching a `vna_other` from `.gnu.version_r` or a `vd_ndx` from `.gnu.version_d` |

Bit `0x8000` is a "hidden" flag; mask it off before comparing (`ndx & 0x7FFF`).

To attribute a version requirement to a symbol name (finding `OB0021`): for symbol index `i`, look up `versym[i] & 0x7FFF`, find the `Vernaux` with that `vna_other`, and read the symbol's name from `DT_SYMTAB[i].st_name` via `DT_STRTAB`. Best-effort: if any part is missing, emit `OB0025` and skip.

---

## 8. Symbol tables and hash tables

### `Elf64_Sym` — 24 bytes

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | `st_name` (offset into `DT_STRTAB`) |
| 4 | 1 | `st_info` |
| 5 | 1 | `st_other` |
| 6 | 2 | `st_shndx` |
| 8 | 8 | `st_value` |
| 16 | 8 | `st_size` |

### `Elf32_Sym` — 16 bytes

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | `st_name` |
| 4 | 4 | `st_value` |
| 8 | 4 | `st_size` |
| 12 | 1 | `st_info` |
| 13 | 1 | `st_other` |
| 14 | 2 | `st_shndx` |

> **The field order differs between ELF32 and ELF64.** Same trap as `Elf*_Phdr`. Test it.

`st_info` packs two fields: bind = `st_info >> 4`, type = `st_info & 0x0F`.

| Bind | Name |
|---|---|
| 0 | `STB_LOCAL` |
| 1 | `STB_GLOBAL` |
| 2 | `STB_WEAK` |

| Type | Name |
|---|---|
| 0 | `STT_NOTYPE` |
| 1 | `STT_OBJECT` |
| 2 | `STT_FUNC` |
| 3 | `STT_SECTION` |
| 4 | `STT_FILE` |
| 6 | `STT_TLS` |
| 10 | `STT_GNU_IFUNC` |

`st_shndx` special values: `SHN_UNDEF = 0` (undefined — imported), `SHN_ABS = 0xFFF1`, `SHN_COMMON = 0xFFF2`.

### `DT_HASH` layout

At `vaddr_to_offset(DT_HASH)`:

```
uint32 nbucket
uint32 nchain          <-- this IS the number of dynamic symbols
uint32 bucket[nbucket]
uint32 chain[nchain]
```

Read `nchain` at offset 4. That is the whole algorithm. Clamp it per spec §6.4.

### `DT_GNU_HASH` layout

At `vaddr_to_offset(DT_GNU_HASH)`:

```
uint32   nbuckets
uint32   symoffset       index of the first symbol present in the hash table
uint32   bloom_size      number of bloom words
uint32   bloom_shift
ElfWord  bloom[bloom_size]        8 bytes each on ELF64, 4 on ELF32
uint32   buckets[nbuckets]
uint32   chain[]                  indexed by (symbol_index - symoffset)
```

Deriving the symbol count:

```
if nbuckets == 0: FAIL
last = 0
for i in 0 .. nbuckets-1:
    if buckets[i] > last: last = buckets[i]
if last < symoffset:
    count = symoffset
else:
    k = last - symoffset
    loop:
        if chain[k] & 1: break            # low bit marks end of chain
        k += 1
        if k exceeds the mapped region or ONEBIN_MAX_SYMS: FAIL
    count = symoffset + k + 1
```

`bloom_size == 0` is malformed — fail rather than divide by it. Every array access must be bounds-checked against the mapped region.

This path is a fallback used only when `DT_HASH` and section headers are both absent. If it fails, emit `OB0025` and continue; it is never fatal.

---

## 9. Worked byte-level example

A minimal ELF64 little-endian header for a PIE executable. Use this in a test as a hand-checked constant, so that a bug in the fixture generator cannot hide a bug in the parser.

```
offset  bytes                                            field
000000  7F 45 4C 46                                      magic
000004  02                                               ELFCLASS64
000005  01                                               ELFDATA2LSB
000006  01                                               EV_CURRENT
000007  00                                               ELFOSABI_NONE
000008  00 00 00 00 00 00 00 00                          ABI ver + padding
000010  03 00                                            e_type    = ET_DYN
000012  3E 00                                            e_machine = 62 (x86_64)
000014  01 00 00 00                                      e_version = 1
000018  00 10 00 00 00 00 00 00                          e_entry   = 0x1000
000020  40 00 00 00 00 00 00 00                          e_phoff   = 64
000028  00 00 00 00 00 00 00 00                          e_shoff   = 0
000030  00 00 00 00                                      e_flags   = 0
000034  40 00                                            e_ehsize  = 64
000036  38 00                                            e_phentsize = 56
000038  02 00                                            e_phnum   = 2
00003A  40 00                                            e_shentsize = 64
00003C  00 00                                            e_shnum   = 0
00003E  00 00                                            e_shstrndx = 0
```

Then, at offset 64, a `PT_LOAD`:

```
000040  01 00 00 00                                      p_type  = PT_LOAD
000044  05 00 00 00                                      p_flags = PF_R|PF_X
000048  00 00 00 00 00 00 00 00                          p_offset = 0
000050  00 00 00 00 00 00 00 00                          p_vaddr  = 0
000058  00 00 00 00 00 00 00 00                          p_paddr  = 0
000060  00 02 00 00 00 00 00 00                          p_filesz = 512
000068  00 02 00 00 00 00 00 00                          p_memsz  = 512
000070  00 10 00 00 00 00 00 00                          p_align  = 0x1000
```

Note where `p_flags` sits: **offset 4 within the phdr**, i.e. file offset `0x44`. On ELF32 the same field would be at offset 24 within the phdr.

Assertions a test should make against these bytes:
- header parses as ELF64, little endian, `ET_DYN`, machine 62
- `e_phoff == 64`, `e_phnum == 2`, `e_phentsize == 56`
- phdr[0] is `PT_LOAD` with flags `PF_R|PF_X` and `p_filesz == 512`
- `vaddr_to_offset(0x100) == 0x100` (because `p_vaddr == p_offset == 0`)
- `vaddr_to_offset(0x300)` is `NOT_MAPPED` (beyond `p_filesz`)

---

## 10. Things that are true and surprising

Collected because each one has produced a wrong tool at least once, and because you cannot look them up.

1. **A `-static-pie` binary has a `PT_DYNAMIC` segment.** It contains relocation entries for self-relocation but **no `DT_NEEDED` and no `PT_INTERP`**. Treating "has PT_DYNAMIC" as "is dynamically linked" is wrong and will make the tool reject correct Profile S binaries.
2. **A fully static, non-PIE binary has no `PT_DYNAMIC` at all**, and therefore no RELRO and no BIND_NOW. Those checks must be skipped, not failed. See `OB0056`.
3. **`DT_NEEDED` holds a string-table index, `DT_STRTAB` holds a virtual address.** Mixing them up produces plausible-looking garbage rather than an obvious crash.
4. **`vn_next` and `vna_next` are relative to the current record**, not absolute, and not relative to the section start.
5. **`.gnu.version_r` strings live in `.dynstr`**, the same table as `DT_NEEDED`, reachable through `DT_STRTAB`. When section headers are present, the same table is `sh_link` of the `.gnu.version_r` section — but you should be using `DT_STRTAB`.
6. **`GLIBC_ABI_DT_RELR` appears in `.gnu.version_r` and is not a version number.** Sorting version strings lexically will place it somewhere absurd and a naive `strtod`-style parse will read `2.36` out of nowhere. It is a marker meaning "this binary needs a loader that understands `DT_RELR`", i.e. glibc ≥ 2.36.
7. **`GLIBC_PRIVATE` is a real requirement string** that pins the exact glibc build. It has no version number.
8. **`libgcc_s.so.1` can appear in `DT_NEEDED` even with `-static-libgcc`**, because glibc `dlopen`s it for stack unwinding and `pthread_cancel`. Its presence is not automatically a bug.
9. **The dynamic symbol table has no size field.** Every method of determining its length is indirect. This is not an oversight in this document.
10. **Section headers are frequently absent.** `strip` removes symbol tables; `--strip-all` plus a linker script or `objcopy -R` can remove the section header table entirely. A binary with `e_shoff == 0` is perfectly valid and must audit correctly.
11. **`p_memsz` may exceed `p_filesz`.** The difference is `.bss`. Never translate an address into that range to a file offset.
12. **`e_phnum == 0xFFFF` is a sentinel**, not a count.
13. **Big-endian ELF exists** (s390x, some PowerPC, some MIPS). Every multi-byte read must respect `EI_DATA`.
14. **On ELF32, `Elf32_Phdr.p_flags` is the second-to-last field, not the second.** Repeated here because it is the single most likely thing for you to get wrong.
