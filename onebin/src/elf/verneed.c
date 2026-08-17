/* elf/verneed.c — see elf/verneed.h. 00-AGENT-TASK.md Task 6.
 *
 * Field offsets are 02-REFERENCE-elf.md §7 — identical on ELF32 and ELF64.
 */
#include "elf/verneed.h"
#include "elf/elf_const.h"
#include "util/limits.h"

#include <stdlib.h>
#include <string.h>

enum {
    VN_VERSION = 0, VN_CNT = 2, VN_FILE = 4, VN_AUX = 8, VN_NEXT = 12,
    VNA_FLAGS = 4, VNA_OTHER = 6, VNA_NAME = 8, VNA_NEXT = 12
};

static void vn_zero(ob_verneed *v) {
    memset(v, 0, sizeof(*v));
}

static int reqs_push(ob_verneed *v, uint64_t file, uint64_t name,
                      uint16_t other, uint16_t flags) {
    if (v->nreqs == v->cap) {
        size_t newcap = v->cap ? v->cap * 2 : 64;
        ob_verneed_req *p = realloc(v->reqs, newcap * sizeof(*p));
        if (!p) {
            return -1; /* allocation failure: caller stops the walk */
        }
        v->reqs = p;
        v->cap = newcap;
    }
    v->reqs[v->nreqs].vn_file_stroff = file;
    v->reqs[v->nreqs].vna_name_stroff = name;
    v->reqs[v->nreqs].vna_other = other;
    v->reqs[v->nreqs].vna_flags = flags;
    v->nreqs++;
    return 0;
}

/* Advance `cur` by a `next` byte delta, both cycle-guarded and overflow-safe
 * even where size_t is narrower than 64 bits — 02-REFERENCE-elf.md §7's
 * "the two cycle guards are mandatory". Returns the new offset, or
 * OB_NOT_MAPPED (reused here purely as a sentinel; it is never a real
 * offset a NUL-based scan would land on inside this module) on failure. */
static uint64_t advance(size_t cur, uint32_t next) {
    uint64_t n64 = (uint64_t)cur + (uint64_t)next;
    if (n64 > (uint64_t)SIZE_MAX) {
        return OB_NOT_MAPPED;
    }
    size_t n = (size_t)n64;
    if (n <= cur) { /* 0 handled by the caller before calling; this is the
                      * cycle guard for a non-zero delta that still fails to
                      * advance, e.g. because it wrapped size_t */
        return OB_NOT_MAPPED;
    }
    return (uint64_t)n;
}

int ob_verneed_load(const ob_image *img, const ob_dynamic *dyn, ob_verneed *out) {
    if (!out) {
        return -1;
    }
    vn_zero(out);
    if (!img || !dyn) {
        return -1;
    }
    if (!dyn->has_verneed) {
        return 0; /* nothing to walk: not an error */
    }

    uint64_t base64 = ob_image_vaddr_to_offset(img, dyn->verneed_vaddr);
    if (base64 == OB_NOT_MAPPED || base64 > (uint64_t)SIZE_MAX) {
        out->truncated = 1;
        return 0;
    }
    size_t cur = (size_t)base64;

    uint64_t limit64 = dyn->verneednum;
    size_t limit = (limit64 < (uint64_t)ONEBIN_MAX_VERNEED)
                       ? (size_t)limit64
                       : (size_t)ONEBIN_MAX_VERNEED;

    size_t seen = 0;
    while (seen < limit) {
        uint16_t vn_version = 0, vn_cnt = 0;
        uint32_t vn_file = 0, vn_aux = 0, vn_next = 0;

        if (ob_rd16(&img->buf, cur + VN_VERSION, &vn_version) != 0) { out->truncated = 1; break; }
        if (ob_rd16(&img->buf, cur + VN_CNT,     &vn_cnt)     != 0) { out->truncated = 1; break; }
        if (ob_rd32(&img->buf, cur + VN_FILE,    &vn_file)    != 0) { out->truncated = 1; break; }
        if (ob_rd32(&img->buf, cur + VN_AUX,     &vn_aux)     != 0) { out->truncated = 1; break; }
        if (ob_rd32(&img->buf, cur + VN_NEXT,    &vn_next)    != 0) { out->truncated = 1; break; }

        if (vn_version != 1) {
            out->truncated = 1;
            break;
        }

        uint64_t aux64 = advance(cur, vn_aux);
        if (vn_aux == 0) {
            aux64 = (uint64_t)cur; /* vn_aux == 0 is degenerate but not a
                                     * cycle by itself: it just means the
                                     * first Vernaux sits at this Verneed's
                                     * own offset. Reads below will fail
                                     * cleanly if that overlaps badly. */
        } else if (aux64 == OB_NOT_MAPPED) {
            out->truncated = 1;
            break;
        }
        size_t aux = (size_t)aux64;

        /* vn_cnt is a 16-bit field (max 65535), strictly less than
         * ONEBIN_MAX_VERNAUX (65536): the cap can never actually trigger,
         * so there is nothing to compare — but the constant stays, as
         * documentation of the bound this loop honours. */
        size_t auxlimit = vn_cnt;
        size_t naux = 0;
        int aux_failed = 0;
        while (naux < auxlimit) {
            uint32_t vna_hash = 0, vna_next = 0, vna_name = 0;
            uint16_t vna_flags = 0, vna_other = 0;
            (void)vna_hash; /* read to advance validation only; ignored per spec */

            if (ob_rd32(&img->buf, aux + 0,         &vna_hash)  != 0) { aux_failed = 1; break; }
            if (ob_rd16(&img->buf, aux + VNA_FLAGS, &vna_flags) != 0) { aux_failed = 1; break; }
            if (ob_rd16(&img->buf, aux + VNA_OTHER, &vna_other) != 0) { aux_failed = 1; break; }
            if (ob_rd32(&img->buf, aux + VNA_NAME,  &vna_name)  != 0) { aux_failed = 1; break; }
            if (ob_rd32(&img->buf, aux + VNA_NEXT,  &vna_next)  != 0) { aux_failed = 1; break; }

            if (reqs_push(out, vn_file, vna_name, vna_other, vna_flags) != 0) {
                aux_failed = 1;
                break;
            }
            naux++;

            if (vna_next == 0) {
                break;
            }
            uint64_t next_aux64 = advance(aux, vna_next);
            if (next_aux64 == OB_NOT_MAPPED) {
                aux_failed = 1;
                break;
            }
            aux = (size_t)next_aux64;
        }
        if (aux_failed) {
            out->truncated = 1;
            break;
        }

        seen++;

        if (vn_next == 0) {
            break;
        }
        uint64_t next_cur64 = advance(cur, vn_next);
        if (next_cur64 == OB_NOT_MAPPED) {
            out->truncated = 1;
            break;
        }
        cur = (size_t)next_cur64;
    }

    out->nverneed_seen = seen;
    return 0;
}

void ob_verneed_free(ob_verneed *v) {
    if (!v) {
        return;
    }
    free(v->reqs);
    vn_zero(v);
}
