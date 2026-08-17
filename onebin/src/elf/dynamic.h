/* elf/dynamic.h — walk PT_DYNAMIC.  00-AGENT-TASK.md Task 6.
 *
 * Like elf/image, this module produces no findings and makes no audit-level
 * decisions.  It reports what the bytes said, plus a small set of "this was
 * structurally odd" flags a future check can turn into OB0003 and friends.
 *
 * A missing PT_DYNAMIC segment is not an error — 02-REFERENCE-elf.md's
 * "Things that are true and surprising" #2: a fully static, non-PIE binary
 * has none, and that's Profile S working as intended.  `has_dynamic` is how
 * a caller tells the two cases apart.
 */
#ifndef ELF_DYNAMIC_H
#define ELF_DYNAMIC_H

#include "elf/image.h"

typedef struct {
    int has_dynamic;   /* a PT_DYNAMIC segment exists */

    /* Structural diagnostics.  None of these are fatal — see the module
     * comment.  A future finding layer decides what, if anything, to say. */
    int segment_out_of_range; /* p_offset/p_filesz do not fit in the file */
    int size_not_aligned;     /* p_filesz % entry_size != 0 */
    int no_dt_null;           /* scan ran to the end of the segment (or the
                                * ONEBIN_MAX_DYNENT bound) without DT_NULL */
    size_t nraw;               /* entries actually scanned, bounded */

    /* DT_NEEDED, in file order, as DT_STRTAB-relative string offsets.
     * Bounded at ONEBIN_MAX_NEEDED; further entries are silently dropped
     * from this array but still counted towards nneeded_total. */
    uint64_t *needed;
    size_t    nneeded;
    size_t    nneeded_total;  /* how many DT_NEEDED entries were seen, even
                                * if not all were kept */

    int      has_soname;   uint64_t soname_stroff;
    int      has_rpath;    uint64_t rpath_stroff;
    int      has_runpath;  uint64_t runpath_stroff;

    uint64_t flags;    /* DT_FLAGS, 0 if the tag was absent */
    uint64_t flags_1;  /* DT_FLAGS_1, 0 if the tag was absent */
    int      has_textrel;
    int      has_bind_now;

    int      has_strtab;    uint64_t strtab_vaddr; uint64_t strsz;
    uint64_t strtab_off;    /* cached ob_image_vaddr_to_offset(strtab_vaddr);
                              * OB_NOT_MAPPED if unmapped or absent */

    int      has_symtab;    uint64_t symtab_vaddr; uint64_t syment;
    int      has_hash;      uint64_t hash_vaddr;
    int      has_gnu_hash;  uint64_t gnu_hash_vaddr;
    int      has_versym;    uint64_t versym_vaddr;
    int      has_verneed;   uint64_t verneed_vaddr; uint64_t verneednum;
} ob_dynamic;

/* Returns 0 on success (which includes "no PT_DYNAMIC", "empty segment",
 * and every malformed case above — they are all reported through the flags,
 * not through the return value) or -1 only on a NULL argument or an
 * allocation failure. */
int  ob_dynamic_load(const ob_image *img, ob_dynamic *out);
void ob_dynamic_free(ob_dynamic *dyn);

/* Reading a string from DT_STRTAB, 02-REFERENCE-elf.md §6's string_at().
 * `idx` is the DT_STRTAB-relative offset stored in DT_NEEDED/DT_SONAME/
 * DT_RPATH/DT_RUNPATH/vn_file/vna_name. */
typedef enum {
    OB_STR_OK = 0,
    OB_STR_NOT_MAPPED,   /* no DT_STRTAB, or its vaddr isn't in any PT_LOAD */
    OB_STR_OUT_OF_RANGE, /* idx >= DT_STRSZ, or the arithmetic would overflow */
    OB_STR_NO_NUL        /* no NUL within bounds, or dst too small for it */
} ob_str_err;

ob_str_err ob_dynamic_string(const ob_image *img, const ob_dynamic *dyn,
                              uint64_t idx, char *dst, size_t dstsz);

#endif /* ELF_DYNAMIC_H */
