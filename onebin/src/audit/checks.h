/* audit/checks.h — shared context and entry points for the check families.
 * 00-AGENT-TASK.md Task 8, one file per check family per
 * 01-SPEC-audit.md §7.
 *
 * Each ob_check_* function only ADDS FINDINGS to `r` — it does not touch
 * `r`'s descriptive fields (file/profile/needed/... ). Populating those is
 * audit/audit.c's job, once, from the same img/dyn/verneed/syms data. This
 * keeps every check a pure "given the facts, what's wrong" function that a
 * test can call directly against a hand-built ctx, exactly like elf/image.c
 * and friends stayed policy-free of findings in Tasks 5-6.
 */
#ifndef AUDIT_CHECKS_H
#define AUDIT_CHECKS_H

#include "elf/image.h"
#include "elf/dynamic.h"
#include "elf/verneed.h"
#include "elf/symbols.h"
#include "audit/report.h"

/* 01-SPEC-audit.md §5.2's default, as a string ob_ver_parse can read. */
#define OB_DEFAULT_GLIBC_MAX "2.28"

typedef struct {
    const ob_image   *img;
    const ob_dynamic *dyn;
    const ob_verneed *verneed;  /* NULL is valid: "no DT_VERNEED" state */
    const ob_symbols *syms;     /* NULL is valid: "count unknown" state */

    /* Resolved by ob_checks_resolve_profile() before any check runs. If the
     * caller wants --profile's effect, set `profile` and `profile_forced =
     * 1` BEFORE calling resolve — it then skips auto-detection entirely,
     * per 01-SPEC-audit.md §7.3: "--profile overrides all of it." */
    ob_profile profile;
    int        profile_forced;
    int        profile_ambiguous; /* OB0039 case; only meaningful when
                                    * profile_forced == 0 */

    const char *glibc_max;        /* e.g. "2.28"; NULL means the default above */
    const char *const *allow;     /* extra --allow sonames */
    size_t      nallow;

    ob_level level;
} ob_check_ctx;

void ob_checks_resolve_profile(ob_check_ctx *ctx);

/* Shared with audit/checks/c_host.c: "the DT_NEEDED allowlist" from
 * 01-SPEC-audit.md §7.1, referenced again verbatim by §7.7's OB0071. One
 * copy, so the two checks cannot silently disagree about what's allowed. */
extern const char *const OB_DEFAULT_ALLOWLIST[];
extern const size_t OB_N_DEFAULT_ALLOWLIST;

void ob_check_needed(const ob_check_ctx *ctx, ob_report *r);
void ob_check_glibc(const ob_check_ctx *ctx, ob_report *r);
/* Pure, no findings — see audit/checks/c_glibc.c for why this exists
 * separately from ob_check_glibc. Returns 1 and fills `out` if any
 * qualifying GLIBC_x.y requirement was found, 0 (out untouched) otherwise. */
int ob_glibc_compute_max(const ob_check_ctx *ctx, char *out, size_t outsz);
void ob_check_profile(const ob_check_ctx *ctx, ob_report *r);
void ob_check_rpath(const ob_check_ctx *ctx, ob_report *r);
void ob_check_harden(const ob_check_ctx *ctx, ob_report *r);
void ob_check_hygiene(const ob_check_ctx *ctx, ob_report *r);
void ob_check_host(const ob_check_ctx *ctx, ob_report *r);
void ob_check_meta(const ob_check_ctx *ctx, ob_report *r, const char *file_path);

#endif /* AUDIT_CHECKS_H */
