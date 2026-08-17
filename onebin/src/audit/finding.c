/* audit/finding.c — see audit/finding.h. */
#include "audit/finding.h"
#include "util/limits.h"
#include "util/str.h"

#include <stdio.h>
#include <string.h>

void ob_finding_list_init(ob_finding_list *fl) {
    ob_vec_init(&fl->v, sizeof(ob_finding));
}

void ob_finding_list_free(ob_finding_list *fl) {
    ob_vec_free(&fl->v);
}

int ob_finding_list_full(const ob_finding_list *fl) {
    return ob_vec_count(&fl->v) >= ONEBIN_MAX_FINDINGS;
}

int ob_finding_list_add(ob_finding_list *fl, const char *id, const char *check,
                         ob_severity severity, const char *subject_raw,
                         const char *message_raw) {
    if (ob_finding_list_full(fl)) {
        return 0;
    }
    ob_finding *f = ob_vec_push(&fl->v);
    if (!f) {
        return 0;
    }

    snprintf(f->id, sizeof(f->id), "%s", id ? id : "");
    snprintf(f->check, sizeof(f->check), "%s", check ? check : "");
    f->severity = severity;
    ob_str_sanitize(subject_raw, f->subject, sizeof(f->subject));
    ob_str_sanitize(message_raw, f->message, sizeof(f->message));
    snprintf(f->fingerprint, sizeof(f->fingerprint), "%s:%s", f->id, f->subject);

    return 1;
}

static int finding_cmp(const void *pa, const void *pb) {
    const ob_finding *a = (const ob_finding *)pa;
    const ob_finding *b = (const ob_finding *)pb;
    int c = strcmp(a->id, b->id);
    if (c != 0) {
        return c;
    }
    c = strcmp(a->subject, b->subject);
    if (c != 0) {
        return c;
    }
    return strcmp(a->message, b->message);
}

void ob_finding_list_sort_and_dedup(ob_finding_list *fl) {
    ob_vec_sort(&fl->v, finding_cmp);

    size_t i = 0;
    while (i + 1 < fl->v.count) {
        const ob_finding *cur = (const ob_finding *)ob_vec_at(&fl->v, i);
        const ob_finding *next = (const ob_finding *)ob_vec_at(&fl->v, i + 1);
        if (strcmp(cur->fingerprint, next->fingerprint) == 0) {
            ob_vec_remove_at(&fl->v, i + 1);
        } else {
            i++;
        }
    }
}

size_t ob_finding_list_count(const ob_finding_list *fl) {
    return ob_vec_count(&fl->v);
}

const ob_finding *ob_finding_list_at(const ob_finding_list *fl, size_t i) {
    return (const ob_finding *)ob_vec_at_const(&fl->v, i);
}

void ob_finding_list_counts(const ob_finding_list *fl, size_t *n_error,
                             size_t *n_warn, size_t *n_info, size_t *n_ok) {
    size_t e = 0, w = 0, in = 0, ok = 0;
    size_t n = ob_finding_list_count(fl);
    for (size_t i = 0; i < n; i++) {
        const ob_finding *f = ob_finding_list_at(fl, i);
        switch (f->severity) {
        case OB_SEV_ERROR:
        case OB_SEV_FATAL: e++; break;
        case OB_SEV_WARN:  w++; break;
        case OB_SEV_INFO:  in++; break;
        case OB_SEV_OK:    ok++; break;
        }
    }
    if (n_error) *n_error = e;
    if (n_warn)  *n_warn  = w;
    if (n_info)  *n_info  = in;
    if (n_ok)    *n_ok    = ok;
}

const char *ob_severity_name(ob_severity sev) {
    switch (sev) {
    case OB_SEV_OK:    return "ok";
    case OB_SEV_INFO:  return "info";
    case OB_SEV_WARN:  return "warn";
    case OB_SEV_ERROR: return "error";
    case OB_SEV_FATAL: return "fatal";
    }
    return "unknown";
}
