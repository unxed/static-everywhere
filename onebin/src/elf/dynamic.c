/* elf/dynamic.c — see elf/dynamic.h for scope. 00-AGENT-TASK.md Task 6. */
#include "elf/dynamic.h"
#include "elf/elf_const.h"
#include "util/limits.h"

#include <stdlib.h>
#include <string.h>

static void dyn_zero(ob_dynamic *d) {
    memset(d, 0, sizeof(*d));
    d->strtab_off = OB_NOT_MAPPED;
}

static void push_needed(ob_dynamic *d, uint64_t stroff) {
    d->nneeded_total++;
    if (d->nneeded >= ONEBIN_MAX_NEEDED) {
        return; /* bounded, per module contract: drop, don't grow forever */
    }
    if (d->nneeded == 0) {
        d->needed = malloc(sizeof(*d->needed) * ONEBIN_MAX_NEEDED);
        if (!d->needed) {
            return; /* allocation failure: silently cap at zero, never crash */
        }
    }
    if (d->needed) {
        d->needed[d->nneeded++] = stroff;
    }
}

static void process_tag(ob_dynamic *d, uint64_t tag, uint64_t val) {
    switch (tag) {
    case DT_NEEDED:     push_needed(d, val); break;
    case DT_SONAME:      if (!d->has_soname)   { d->has_soname = 1;   d->soname_stroff = val; }  break;
    case DT_RPATH:       if (!d->has_rpath)    { d->has_rpath = 1;    d->rpath_stroff = val; }   break;
    case DT_RUNPATH:     if (!d->has_runpath)  { d->has_runpath = 1;  d->runpath_stroff = val; } break;
    case DT_FLAGS:       d->flags = val; break;
    case DT_FLAGS_1:     d->flags_1 = val; break;
    case DT_TEXTREL:     d->has_textrel = 1; break;
    case DT_BIND_NOW:    d->has_bind_now = 1; break;
    case DT_STRTAB:      if (!d->has_strtab)   { d->has_strtab = 1;   d->strtab_vaddr = val; }   break;
    case DT_STRSZ:       d->strsz = val; break;
    case DT_SYMTAB:      if (!d->has_symtab)   { d->has_symtab = 1;   d->symtab_vaddr = val; }   break;
    case DT_SYMENT:      d->syment = val; break;
    case DT_HASH:        if (!d->has_hash)     { d->has_hash = 1;     d->hash_vaddr = val; }     break;
    case DT_GNU_HASH:    if (!d->has_gnu_hash) { d->has_gnu_hash = 1; d->gnu_hash_vaddr = val; } break;
    case DT_VERSYM:       if (!d->has_versym)  { d->has_versym = 1;   d->versym_vaddr = val; }   break;
    case DT_VERNEED:      if (!d->has_verneed) { d->has_verneed = 1;  d->verneed_vaddr = val; }  break;
    case DT_VERNEEDNUM:   d->verneednum = val; break;
    default: break; /* not needed by this project, per 02-REFERENCE-elf.md §6 */
    }
}

int ob_dynamic_load(const ob_image *img, ob_dynamic *out) {
    if (!out) {
        return -1;
    }
    dyn_zero(out);
    if (!img) {
        return -1;
    }

    const ob_phdr *dynp = NULL;
    for (size_t i = 0; i < img->nphdrs; i++) {
        if (img->phdrs[i].p_type == PT_DYNAMIC) {
            dynp = &img->phdrs[i]; /* first wins, per project convention */
            break;
        }
    }
    if (!dynp) {
        return 0; /* no PT_DYNAMIC: a valid, ordinary state (Profile S) */
    }
    out->has_dynamic = 1;

    if (dynp->p_offset > (uint64_t)SIZE_MAX || dynp->p_filesz > (uint64_t)SIZE_MAX) {
        out->segment_out_of_range = 1;
        return 0;
    }
    size_t seg_off = (size_t)dynp->p_offset;
    size_t seg_len = (size_t)dynp->p_filesz;
    if (ob_range(&img->buf, seg_off, seg_len) != 0) {
        out->segment_out_of_range = 1;
        return 0;
    }

    size_t entsz = img->buf.c64 ? DYN64_SIZE : DYN32_SIZE;
    size_t val_off = img->buf.c64 ? 8u : 4u;
    out->size_not_aligned = (entsz == 0) ? 0 : (seg_len % entsz != 0);

    size_t end = seg_off + seg_len; /* safe: ob_range already proved this fits */
    size_t cur = seg_off;
    size_t n = 0;
    int found_null = 0;

    while (cur + entsz <= end && n < ONEBIN_MAX_DYNENT) {
        uint64_t tag = 0, val = 0;
        if (ob_rdaddr(&img->buf, cur, &tag) != 0) {
            break; /* out-of-range read: stop, do not crash */
        }
        if (ob_rdaddr(&img->buf, cur + val_off, &val) != 0) {
            break;
        }
        if (tag == DT_NULL) {
            found_null = 1;
            break;
        }
        process_tag(out, tag, val);
        n++;
        cur += entsz;
    }
    out->nraw = n;
    out->no_dt_null = !found_null;

    if (out->has_strtab) {
        out->strtab_off = ob_image_vaddr_to_offset(img, out->strtab_vaddr);
    }

    return 0;
}

void ob_dynamic_free(ob_dynamic *dyn) {
    if (!dyn) {
        return;
    }
    free(dyn->needed);
    dyn_zero(dyn);
}

ob_str_err ob_dynamic_string(const ob_image *img, const ob_dynamic *dyn,
                              uint64_t idx, char *dst, size_t dstsz) {
    if (dst && dstsz > 0) {
        dst[0] = '\0';
    }
    if (!img || !dyn || !dst || dstsz == 0) {
        return OB_STR_OUT_OF_RANGE;
    }
    if (!dyn->has_strtab || dyn->strtab_off == OB_NOT_MAPPED) {
        return OB_STR_NOT_MAPPED;
    }
    if (idx >= dyn->strsz) {
        return OB_STR_OUT_OF_RANGE;
    }

    uint64_t remaining = dyn->strsz - idx;
    size_t max = (remaining < (uint64_t)ONEBIN_MAX_STRING)
                     ? (size_t)remaining
                     : (size_t)ONEBIN_MAX_STRING;

    uint64_t off64 = dyn->strtab_off + idx;
    if (off64 < dyn->strtab_off) { /* overflow wrap */
        return OB_STR_OUT_OF_RANGE;
    }
    if (off64 > (uint64_t)SIZE_MAX) {
        return OB_STR_OUT_OF_RANGE;
    }

    ssize_t r = ob_rdstr(&img->buf, (size_t)off64, dst, dstsz, max);
    if (r < 0) {
        return OB_STR_NO_NUL;
    }
    return OB_STR_OK;
}
