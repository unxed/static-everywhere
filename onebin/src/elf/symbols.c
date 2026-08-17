/* elf/symbols.c — see elf/symbols.h. 00-AGENT-TASK.md Task 6,
 * 01-SPEC-audit.md §6.4, 02-REFERENCE-elf.md §8.
 */
#include "elf/symbols.h"
#include "elf/elf_const.h"
#include "util/limits.h"

#include <string.h>

/* ---- tier 1: DT_HASH ----------------------------------------------------
 * "Read nchain at offset 4. That is the whole algorithm." */
static int try_dt_hash(const ob_image *img, const ob_dynamic *dyn, size_t *count_out) {
    if (!dyn->has_hash) {
        return -1;
    }
    uint64_t off64 = ob_image_vaddr_to_offset(img, dyn->hash_vaddr);
    if (off64 == OB_NOT_MAPPED || off64 > (uint64_t)SIZE_MAX) {
        return -1;
    }
    uint32_t nchain = 0;
    if (ob_rd32(&img->buf, (size_t)off64 + 4, &nchain) != 0) {
        return -1;
    }
    *count_out = nchain;
    return 0;
}

/* ---- tier 2: section headers ---------------------------------------------
 * Find the SHT_DYNSYM section and compute sh_size / sh_entsize.  This is the
 * one place this project reads section headers as an array rather than the
 * single PN_XNUM field elf/image.c needs — it is optional by design
 * (02-REFERENCE-elf.md §1) and this whole tier is allowed to fail. */
static int try_section_headers(const ob_image *img, size_t *count_out) {
    if (img->e_shoff == 0 || img->e_shnum == 0 || img->e_shentsize == 0) {
        return -1;
    }
    if (img->e_shoff > (uint64_t)SIZE_MAX) {
        return -1;
    }
    size_t base = (size_t)img->e_shoff;
    size_t entsz = img->e_shentsize;
    size_t shnum = img->e_shnum;
    if (shnum > ONEBIN_MAX_SHNUM) {
        shnum = ONEBIN_MAX_SHNUM;
    }

    for (size_t i = 0; i < shnum; i++) {
        uint64_t at64 = (uint64_t)base + (uint64_t)i * (uint64_t)entsz;
        if (at64 > (uint64_t)SIZE_MAX) {
            break;
        }
        size_t at = (size_t)at64;

        uint32_t sh_type = 0;
        if (ob_rd32(&img->buf, at + 4, &sh_type) != 0) {
            continue;
        }
        if (sh_type != SHT_DYNSYM) {
            continue;
        }

        uint64_t sh_size = 0, sh_entsize = 0;
        if (img->buf.c64) {
            if (ob_rd64(&img->buf, at + 32, &sh_size) != 0) continue;
            if (ob_rd64(&img->buf, at + 56, &sh_entsize) != 0) continue;
        } else {
            uint32_t sz32 = 0, es32 = 0;
            if (ob_rd32(&img->buf, at + 20, &sz32) != 0) continue;
            if (ob_rd32(&img->buf, at + 36, &es32) != 0) continue;
            sh_size = sz32;
            sh_entsize = es32;
        }
        if (sh_entsize == 0) {
            continue;
        }
        uint64_t cnt = sh_size / sh_entsize;
        *count_out = (cnt > (uint64_t)SIZE_MAX) ? (size_t)SIZE_MAX : (size_t)cnt;
        return 0;
    }
    return -1;
}

/* ---- tier 3: DT_GNU_HASH --------------------------------------------------
 * 02-REFERENCE-elf.md §8. Every array access bounds-checked via ob_rd32. */
static int try_gnu_hash(const ob_image *img, const ob_dynamic *dyn, size_t *count_out) {
    if (!dyn->has_gnu_hash) {
        return -1;
    }
    uint64_t base64 = ob_image_vaddr_to_offset(img, dyn->gnu_hash_vaddr);
    if (base64 == OB_NOT_MAPPED || base64 > (uint64_t)SIZE_MAX) {
        return -1;
    }
    size_t base = (size_t)base64;

    uint32_t nbuckets = 0, symoffset = 0, bloom_size = 0, bloom_shift = 0;
    if (ob_rd32(&img->buf, base + 0,  &nbuckets)   != 0) return -1;
    if (ob_rd32(&img->buf, base + 4,  &symoffset)  != 0) return -1;
    if (ob_rd32(&img->buf, base + 8,  &bloom_size) != 0) return -1;
    if (ob_rd32(&img->buf, base + 12, &bloom_shift) != 0) return -1;
    (void)bloom_shift;
    if (nbuckets == 0 || bloom_size == 0) {
        return -1; /* "bloom_size == 0 is malformed — fail rather than divide by it" */
    }

    size_t bloomword = img->buf.c64 ? 8u : 4u;
    uint64_t buckets_base64 = (uint64_t)base + 16u + (uint64_t)bloom_size * (uint64_t)bloomword;
    if (buckets_base64 > (uint64_t)SIZE_MAX) {
        return -1;
    }
    size_t buckets_base = (size_t)buckets_base64;

    uint32_t last = 0;
    for (uint32_t i = 0; i < nbuckets; i++) {
        uint64_t at64 = (uint64_t)buckets_base + (uint64_t)i * 4u;
        if (at64 > (uint64_t)SIZE_MAX) {
            return -1;
        }
        uint32_t v = 0;
        if (ob_rd32(&img->buf, (size_t)at64, &v) != 0) {
            return -1;
        }
        if (v > last) {
            last = v;
        }
    }

    size_t count;
    if (last < symoffset) {
        count = symoffset;
    } else {
        uint32_t k = last - symoffset;
        uint64_t chain_base64 = (uint64_t)buckets_base + (uint64_t)nbuckets * 4u;
        if (chain_base64 > (uint64_t)SIZE_MAX) {
            return -1;
        }
        size_t chain_base = (size_t)chain_base64;
        for (;;) {
            uint64_t at64 = (uint64_t)chain_base + (uint64_t)k * 4u;
            if (at64 > (uint64_t)SIZE_MAX) {
                return -1;
            }
            uint32_t cv = 0;
            if (ob_rd32(&img->buf, (size_t)at64, &cv) != 0) {
                return -1; /* "k exceeds the mapped region... FAIL" */
            }
            if (cv & 1u) {
                break; /* low bit marks the end of the chain */
            }
            k++;
            if ((uint64_t)k > (uint64_t)ONEBIN_MAX_SYMS) {
                return -1;
            }
        }
        count = (size_t)symoffset + (size_t)k + 1;
    }
    *count_out = count;
    return 0;
}

int ob_symbols_count(const ob_image *img, const ob_dynamic *dyn, ob_symbols *out) {
    if (!out) {
        return -1;
    }
    memset(out, 0, sizeof(*out));
    if (!img || !dyn) {
        return -1;
    }

    size_t count = 0;
    int found = 0;

    if (!found && try_dt_hash(img, dyn, &count) == 0) {
        found = 1;
        out->source = OB_SYMCOUNT_DT_HASH;
    }
    if (!found && try_section_headers(img, &count) == 0) {
        found = 1;
        out->source = OB_SYMCOUNT_SECTION_HEADERS;
    }
    if (!found && try_gnu_hash(img, dyn, &count) == 0) {
        found = 1;
        out->source = OB_SYMCOUNT_DT_GNU_HASH;
    }
    if (!found) {
        out->count_known = 0;
        out->count = 0;
        out->source = OB_SYMCOUNT_UNKNOWN;
        return 0; /* "give up" is a normal outcome, per the module contract */
    }

    if (count > ONEBIN_MAX_SYMS) {
        count = ONEBIN_MAX_SYMS;
    }

    /* Clamp so that count * syment fits the mapped DT_SYMTAB region — a
     * crafted nchain/GNU-hash count must not let a later reader walk past
     * the file. */
    size_t canon = img->buf.c64 ? SYM64_SIZE : SYM32_SIZE;
    if (!dyn->has_symtab) {
        count = 0;
    } else {
        uint64_t symtab_off64 = ob_image_vaddr_to_offset(img, dyn->symtab_vaddr);
        if (symtab_off64 == OB_NOT_MAPPED || symtab_off64 > (uint64_t)SIZE_MAX) {
            count = 0;
        } else {
            size_t off = (size_t)symtab_off64;
            size_t avail = (off <= img->buf.len) ? (img->buf.len - off) : 0;
            size_t max_by_region = avail / canon;
            if (count > max_by_region) {
                count = max_by_region;
            }
        }
    }

    out->count_known = 1;
    out->count = count;
    return 0;
}

int ob_symbols_at(const ob_image *img, const ob_dynamic *dyn,
                   const ob_symbols *syms, size_t index, ob_sym_entry *out) {
    if (!img || !dyn || !syms || !out) {
        return -1;
    }
    memset(out, 0, sizeof(*out));
    if (!syms->count_known || index >= syms->count || !dyn->has_symtab) {
        return -1;
    }

    uint64_t symtab_off64 = ob_image_vaddr_to_offset(img, dyn->symtab_vaddr);
    if (symtab_off64 == OB_NOT_MAPPED || symtab_off64 > (uint64_t)SIZE_MAX) {
        return -1;
    }

    size_t canon = img->buf.c64 ? SYM64_SIZE : SYM32_SIZE;
    uint64_t entry_off64 = symtab_off64 + (uint64_t)index * (uint64_t)canon;
    if (entry_off64 < symtab_off64 || entry_off64 > (uint64_t)SIZE_MAX) {
        return -1; /* overflow guard; unreachable in practice since count is
                     * already clamped to fit, kept for defence in depth */
    }
    size_t off = (size_t)entry_off64;

    uint32_t st_name = 0;
    uint8_t  st_info = 0, st_other = 0;
    uint16_t st_shndx = 0;
    uint64_t st_value = 0, st_size = 0;

    if (img->buf.c64) {
        if (ob_rd32(&img->buf, off + 0, &st_name)  != 0) return -1;
        if (ob_rd8 (&img->buf, off + 4, &st_info)  != 0) return -1;
        if (ob_rd8 (&img->buf, off + 5, &st_other) != 0) return -1;
        if (ob_rd16(&img->buf, off + 6, &st_shndx) != 0) return -1;
        if (ob_rd64(&img->buf, off + 8, &st_value) != 0) return -1;
        if (ob_rd64(&img->buf, off + 16, &st_size) != 0) return -1;
    } else {
        uint32_t val32 = 0, size32 = 0;
        if (ob_rd32(&img->buf, off + 0,  &st_name)  != 0) return -1;
        if (ob_rd32(&img->buf, off + 4,  &val32)    != 0) return -1;
        if (ob_rd32(&img->buf, off + 8,  &size32)   != 0) return -1;
        if (ob_rd8 (&img->buf, off + 12, &st_info)  != 0) return -1;
        if (ob_rd8 (&img->buf, off + 13, &st_other) != 0) return -1;
        if (ob_rd16(&img->buf, off + 14, &st_shndx) != 0) return -1;
        st_value = val32;
        st_size = size32;
    }

    out->st_name = st_name;
    out->st_value = st_value;
    out->st_size = st_size;
    out->st_info = st_info;
    out->st_other = st_other;
    out->st_shndx = st_shndx;
    return 0;
}
