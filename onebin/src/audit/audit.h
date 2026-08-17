/* audit/audit.h — orchestration: read a file, run every check, produce one
 * finalized ob_report. 00-AGENT-TASK.md Task 8, tree comment
 * "audit.c/.h — orchestration: run all checks, collect findings".
 *
 * This is the ONLY layer in the whole project that reads a file from disk
 * (01-SPEC-audit.md §3.2: never mmap; read fully into memory, capped at
 * ONEBIN_MAX_FILE) and the only one that can produce the io.* fatal
 * findings (OB0090-93) and the elf.* structural fatal findings
 * (OB0001-0003) — everything below this layer (the elf modules, checks)
 * only ever sees an already-validated in-memory buffer.
 */
#ifndef AUDIT_AUDIT_H
#define AUDIT_AUDIT_H

#include "audit/report.h"
#include "audit/checks.h"

typedef struct {
    const char *file_path;       /* required */

    int         profile_forced;  /* 1 if the caller passed --profile */
    ob_profile  profile;         /* meaningful only if profile_forced */

    const char *glibc_max;       /* NULL -> OB_DEFAULT_GLIBC_MAX */
    const char *const *allow;    /* extra --allow sonames */
    size_t      nallow;

    ob_level    level;           /* default OB_LEVEL_1 */
    int         strict;          /* warnings also fail, for ob_report_finalize */

    ob_baseline *baseline;       /* NULL: no baseline applied */
} ob_audit_options;

/* Fills `opts` with this module's defaults. Caller still must set
 * file_path (and level, if not OB_LEVEL_1). */
void ob_audit_options_init(ob_audit_options *opts);

typedef enum {
    OB_AUDIT_OK = 0,   /* a normal, finalized report — check r->passed for
                         * the verdict, this status only says "no fatal
                         * condition stopped the audit before it started" */
    OB_AUDIT_FATAL     /* `out` contains exactly one fatal finding and
                         * whatever identity fields were known before the
                         * fatal condition was hit (at minimum, file_path).
                         * Per 01-SPEC-audit.md §8: "produce no audit
                         * result for that file, exit 2." */
} ob_audit_status;

/* Reads opts->file_path, runs every check, and finalizes `out`
 * (ob_report_init'd internally — the caller must not have initialized it,
 * and must call ob_report_free(out) exactly once regardless of the
 * returned status). */
ob_audit_status ob_audit_file(const ob_audit_options *opts, ob_report *out);

#endif /* AUDIT_AUDIT_H */
