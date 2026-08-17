/* elf/symbols.h — dynamic symbol count, and reading one entry at a time.
 * 00-AGENT-TASK.md Task 6, 01-SPEC-audit.md §6.4, 02-REFERENCE-elf.md §8.
 *
 * There is no DT_SYMSZ.  01-SPEC-audit.md §6.4 gives a fallback chain — try
 * DT_HASH, then section headers, then DT_GNU_HASH, then give up — and this
 * implements exactly that chain and nothing more.
 *
 * Deliberately does NOT materialise an array of every symbol: `count` can be
 * up to ONEBIN_MAX_SYMS (1,000,000), and the only real use for this data
 * (attributing a version requirement to a symbol name, OB0021) needs at
 * most one symbol at a time. ob_symbols_at() reads on demand.
 */
#ifndef ELF_SYMBOLS_H
#define ELF_SYMBOLS_H

#include "elf/dynamic.h"

typedef enum {
    OB_SYMCOUNT_UNKNOWN = 0,
    OB_SYMCOUNT_DT_HASH,
    OB_SYMCOUNT_SECTION_HEADERS,
    OB_SYMCOUNT_DT_GNU_HASH
} ob_symcount_src;

typedef struct {
    int             count_known;
    size_t          count;   /* 0 if !count_known; otherwise already clamped
                               * to ONEBIN_MAX_SYMS and to what actually fits
                               * the mapped DT_SYMTAB region */
    ob_symcount_src source;
} ob_symbols;

/* Never fails outright — an unknown count is a normal, reportable outcome
 * (OB0025), not an error. Returns -1 only for a NULL argument. */
int ob_symbols_count(const ob_image *img, const ob_dynamic *dyn, ob_symbols *out);

/* One Elf*_Sym entry, 02-REFERENCE-elf.md §8 (field order differs by class;
 * this struct does not — it is already normalised). */
typedef struct {
    uint64_t st_name;  /* DT_STRTAB-relative offset */
    uint64_t st_value;
    uint64_t st_size;
    uint8_t  st_info;
    uint8_t  st_other;
    uint16_t st_shndx;
} ob_sym_entry;

#define OB_ST_BIND(info) ((uint8_t)((info) >> 4))
#define OB_ST_TYPE(info) ((uint8_t)((info) & 0x0F))

/* Reads dynsym[index]. `syms` must be a `count_known` result from
 * ob_symbols_count(); index must be < syms->count. Returns 0 on success,
 * -1 on any out-of-range or malformed condition — never a crash. */
int ob_symbols_at(const ob_image *img, const ob_dynamic *dyn,
                   const ob_symbols *syms, size_t index, ob_sym_entry *out);

#endif /* ELF_SYMBOLS_H */
