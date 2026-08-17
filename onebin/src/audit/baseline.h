/* audit/baseline.h — load/apply/write baseline files.
 * 01-SPEC-audit.md §9.4. 00-AGENT-TASK.md Task 7.
 */
#ifndef AUDIT_BASELINE_H
#define AUDIT_BASELINE_H

#include "audit/finding.h"

typedef enum {
    OB_BASELINE_OK = 0,
    OB_BASELINE_ERR_OPEN,
    OB_BASELINE_ERR_LINE_TOO_LONG
} ob_baseline_err;

typedef struct {
    ob_vec fingerprints; /* elements are char[OB_FINGERPRINT_LEN] */
    ob_vec matched;      /* parallel to fingerprints: elements are int,
                           * 1 once ob_baseline_apply() has matched it */
} ob_baseline;

/* Parses `path`: "# comments" and blank lines ignored, one fingerprint per
 * remaining line (01-SPEC-audit.md §9.4). A line longer than
 * OB_FINGERPRINT_LEN - 1 is a format error, not silently truncated — a
 * baseline is a security-relevant allowlist, and silently truncating an
 * entry could make it match something it was never meant to. */
ob_baseline_err ob_baseline_load(const char *path, ob_baseline *out);
void            ob_baseline_free(ob_baseline *bl);

int ob_baseline_contains(const ob_baseline *bl, const char *fingerprint);

/* Removes every finding from `fl` whose fingerprint is in `bl`, marking the
 * matching baseline entries as used. Returns the number of findings
 * suppressed. Safe to call at most once per loaded baseline — a second call
 * would report entries as "matched" from the first call's bookkeeping. */
size_t ob_baseline_apply(ob_baseline *bl, ob_finding_list *fl);

/* Entries that ob_baseline_apply() did not match anything — "stale"
 * baseline entries, §9.4's OB0100. Valid only after ob_baseline_apply(). */
size_t      ob_baseline_stale_count(const ob_baseline *bl);
const char *ob_baseline_stale_at(const ob_baseline *bl, size_t i);

/* Writes every finding's fingerprint in `fl` to `path`, one per line, plus
 * the two header comment lines from §9.4's example. `fl` should already be
 * sorted (ob_finding_list_sort_and_dedup) — this function does not sort.
 * Returns 0 on success, -1 on any I/O failure. */
int ob_baseline_write(const char *path, const ob_finding_list *fl);

#endif /* AUDIT_BASELINE_H */
