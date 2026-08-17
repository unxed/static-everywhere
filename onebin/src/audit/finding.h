/* audit/finding.h — one reported observation. 00-AGENT-TASK.md Task 7,
 * 01-SPEC-audit.md §2 (vocabulary), §8 (the catalog), §9.3 (sanitisation),
 * §12 (dedup and the finding-count cap).
 */
#ifndef AUDIT_FINDING_H
#define AUDIT_FINDING_H

#include "onebin/audit.h"
#include "util/vec.h"

#define OB_ID_LEN          8   /* "OB0080" + NUL, with room to spare */
#define OB_CHECK_LEN       64
#define OB_SUBJECT_LEN     256 /* >= OB_STR_MAXLEN (util/str.h) + slack */
#define OB_MESSAGE_LEN     256
#define OB_FINGERPRINT_LEN (OB_ID_LEN + OB_SUBJECT_LEN)

typedef struct {
    char id[OB_ID_LEN];             /* "OB0051" */
    char check[OB_CHECK_LEN];       /* "harden.bindnow" */
    ob_severity severity;
    char subject[OB_SUBJECT_LEN];   /* already sanitised; "" means absent */
    char message[OB_MESSAGE_LEN];   /* already sanitised */
    char fingerprint[OB_FINGERPRINT_LEN]; /* "<id>:<subject>", §2 */
} ob_finding;

typedef struct {
    ob_vec v; /* elements are ob_finding */
} ob_finding_list;

void ob_finding_list_init(ob_finding_list *fl);
void ob_finding_list_free(ob_finding_list *fl);

/* Sanitises subject_raw and message_raw (util/str.h, §9.3) before storing
 * them, then computes the fingerprint from the SANITISED subject — the raw
 * subject is never persisted anywhere. `subject_raw` and `message_raw` may
 * be NULL, meaning "absent" (stored as "").
 *
 * Per §12's finding-count cap: once the list already holds
 * ONEBIN_MAX_FINDINGS entries, returns 0 without adding anything. The
 * caller (not this module — this module stays policy-free, like elf modules) is
 * responsible for then adding a single OB0101 warning; see
 * ob_finding_list_full().
 *
 * Returns 1 if added, 0 if not (cap reached or allocation failure). */
int ob_finding_list_add(ob_finding_list *fl, const char *id, const char *check,
                         ob_severity severity, const char *subject_raw,
                         const char *message_raw);

int ob_finding_list_full(const ob_finding_list *fl);

/* Sorts by (id, subject, message), byte-wise (memcmp), per §9.2's
 * "findings is sorted by (id, subject, message), byte-wise, LC_ALL=C". Then
 * removes exact fingerprint duplicates, keeping the first survivor in the
 * new sorted order (§12: "deduplicate; keep the first; do not increment
 * counts twice"). */
void ob_finding_list_sort_and_dedup(ob_finding_list *fl);

size_t            ob_finding_list_count(const ob_finding_list *fl);
const ob_finding *ob_finding_list_at(const ob_finding_list *fl, size_t i);

/* Counts by severity, for the report's "counts" object and the text
 * format's summary line. OB_SEV_FATAL is folded into the error count: a
 * fatal finding means no audit result exists for the file at all, so it
 * never reaches a finding list a report is built from, but counting it as
 * an error rather than silently dropping it is the safer default if one
 * ever does. */
void ob_finding_list_counts(const ob_finding_list *fl, size_t *n_error,
                             size_t *n_warn, size_t *n_info, size_t *n_ok);

/* Lowercase severity name: "ok" | "info" | "warn" | "error" | "fatal". Used
 * by both reporters so the mapping exists in exactly one place. */
const char *ob_severity_name(ob_severity sev);

#endif /* AUDIT_FINDING_H */
