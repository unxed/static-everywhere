/* mkelf.h — ELF fixture generator.
 *
 * You cannot download ELF binaries and must not depend on the host compiler, so
 * the test suite builds them byte by byte.  Contract: 03-TESTPLAN.md §3.
 *
 * LAYOUT.  Every generated file has this shape, each region aligned to 8 bytes
 * (4 on ELF32).  Regions that are not needed are absent and take no space.
 *
 *     ELF header
 *     program headers
 *     .interp          (optional, NUL-terminated)
 *     .dynstr          (starts with a NUL byte)
 *     .dynsym          (optional; index 0 is the reserved null symbol)
 *     .hash            (optional, DT_HASH)
 *     .gnu.hash        (optional, DT_GNU_HASH)
 *     .gnu.version     (optional, uint16 per .dynsym entry)
 *     .gnu.version_r   (optional)
 *     .dynamic         (optional, DT_NULL terminated)
 *     .rodata          (optional, NUL-separated strings)
 *     section data     (only when section headers are emitted)
 *     section headers  (optional)
 *
 * One PT_LOAD covers the whole file with p_offset == 0 and p_vaddr == BASE,
 * where BASE is 0x400000 for ET_EXEC and 0 for ET_DYN.  So
 * vaddr_to_offset(v) == v - BASE everywhere, and a bug in address translation
 * shows up immediately instead of being masked.
 *
 * PROGRAM HEADER ORDER is fixed and tests may rely on it:
 *     PT_INTERP (if any), PT_LOAD (main), extra PT_LOADs,
 *     PT_DYNAMIC (if any), PT_GNU_RELRO (if any), PT_GNU_STACK (if any)
 */
#ifndef ONEBIN_TESTS_MKELF_H
#define ONEBIN_TESTS_MKELF_H

#include <stddef.h>
#include <stdint.h>

#define EG_LE 0
#define EG_BE 1

#define EG_BASE_EXEC 0x400000u
#define EG_BASE_DYN  0u

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

/* Additions beyond 03-TESTPLAN.md §3, recorded in NOTES.md:
 *   eg_set_entry  — needed to reproduce the worked example in
 *                   02-REFERENCE-elf.md §9, which has e_entry == 0x1000.
 *   eg_set_pad_to — same reason: that example's PT_LOAD has p_filesz == 512.
 *   eg_set_load_flags — same reason: its PT_LOAD is PF_R|PF_X.
 *   eg_force_dynamic — a static-PIE has a PT_DYNAMIC with nothing in it worth
 *                   naming; without this there is no way to ask for one.
 */
void eg_set_entry     (eg *, uint64_t entry);
void eg_set_pad_to    (eg *, size_t total_bytes);
void eg_set_load_flags(eg *, uint32_t p_flags);
void eg_force_dynamic (eg *, int on);

/* Emit.  Returns malloc'd buffer; caller frees. */
uint8_t *eg_emit(eg *, size_t *out_len);
int      eg_write(eg *, const char *path);

/* Post-emit mutation, for the malformed corpus.  Offsets come from eg_off(),
 * which is valid only after eg_emit() and describes the most recent emit.
 * A part that the file does not contain reports offset 0. */
typedef enum { EG_OFF_EHDR, EG_OFF_PHDR, EG_OFF_DYNAMIC, EG_OFF_DYNSTR,
               EG_OFF_VERNEED, EG_OFF_DYNSYM, EG_OFF_SHDR, EG_OFF_RODATA } eg_part;
size_t eg_off(const eg *, eg_part);

/* Sizes of the same parts, for tests that compute expected offsets by hand. */
size_t eg_size(const eg *, eg_part);

/* eg_poke* bounds-check and abort on an out-of-range offset: a mutation helper
 * that silently writes nothing produces tests that pass for the wrong reason. */
void   eg_poke8 (uint8_t *buf, size_t len, size_t off, uint8_t  v);
void   eg_poke16(uint8_t *buf, size_t len, size_t off, uint16_t v, int be);
void   eg_poke32(uint8_t *buf, size_t len, size_t off, uint32_t v, int be);
void   eg_poke64(uint8_t *buf, size_t len, size_t off, uint64_t v, int be);

/* Convenience builders.  hybrid_ok, static_ok and module must audit clean. */
eg *eg_preset_hybrid_ok(void);
eg *eg_preset_static_ok(void);
eg *eg_preset_static_nopie(void);
eg *eg_preset_shared_lib(void);
eg *eg_preset_module(void);

#endif /* ONEBIN_TESTS_MKELF_H */
