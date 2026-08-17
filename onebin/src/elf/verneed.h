/* elf/verneed.h — walk .gnu.version_r.  00-AGENT-TASK.md Task 6.
 *
 * 02-REFERENCE-elf.md §7's walk algorithm, verbatim, including both cycle
 * guards.  This is, per that document, "the only part of ELF parsing in
 * this project that is genuinely intricate" — read it before touching this
 * file.
 *
 * Like elf/dynamic, this produces no findings: `truncated` says the walk
 * stopped early (a bad vn_version, a failed read, or a cycle guard firing),
 * and it is a future check's job to decide that means OB0003.
 */
#ifndef ELF_VERNEED_H
#define ELF_VERNEED_H

#include "elf/dynamic.h"

/* One (file, version) requirement, i.e. one Vernaux, with enough context
 * (vna_other) to be matched against .gnu.version later. */
typedef struct {
    uint64_t vn_file_stroff;  /* Verneed.vn_file: which .so this came from */
    uint64_t vna_name_stroff; /* Vernaux.vna_name: the version string */
    uint16_t vna_other;       /* matches entries in .gnu.version */
    uint16_t vna_flags;       /* VER_FLG_WEAK, etc. */
} ob_verneed_req;

typedef struct {
    ob_verneed_req *reqs;
    size_t          nreqs;
    size_t          cap;       /* internal, harmless to read, not to poke */

    int    truncated;          /* walk stopped before exhausting DT_VERNEEDNUM:
                                 * a failed read, vn_version != 1, or a cycle
                                 * guard.  Also set if DT_VERNEED is present
                                 * but unmapped. */
    size_t nverneed_seen;      /* top-level Verneed records processed */
} ob_verneed;

/* Returns 0 always, except -1 for a NULL argument.  A missing DT_VERNEED, an
 * unmapped one, and a merely-empty one (DT_VERNEEDNUM == 0) are all normal,
 * not errors — see `truncated` and `nreqs` to tell them apart if it matters. */
int  ob_verneed_load(const ob_image *img, const ob_dynamic *dyn, ob_verneed *out);
void ob_verneed_free(ob_verneed *v);

#endif /* ELF_VERNEED_H */
