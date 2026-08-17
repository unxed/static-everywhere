/* audit/report.c — see audit/report.h. */
#include "audit/report.h"
#include "util/str.h"
#include "util/limits.h"

#include <stdlib.h>
#include <string.h>

/* Owned-copy helper: sanitises (if `sanitise` is set) then duplicates.
 * Returns NULL for a NULL input (meaning "absent"), never for an empty
 * string (meaning "present, empty"). Aborts on allocation failure, same
 * policy as tests/mkelf.c and util/json.c: a report silently missing a
 * field is worse than a crash. */
static char *own(const char *raw, int sanitise) {
    if (!raw) {
        return NULL;
    }
    char buf[OB_STR_MAXLEN + 1];
    const char *src = raw;
    if (sanitise) {
        ob_str_sanitize(raw, buf, sizeof(buf));
        src = buf;
    }
    size_t n = strlen(src);
    char *p = malloc(n + 1);
    if (!p) {
        abort();
    }
    memcpy(p, src, n + 1);
    return p;
}

static char **strvec_push(char **arr, size_t n, char *owned_str) {
    char **p = realloc(arr, (n + 1) * sizeof(char *));
    if (!p) {
        abort();
    }
    p[n] = owned_str;
    return p;
}

void ob_report_init(ob_report *r) {
    memset(r, 0, sizeof(*r));
    ob_finding_list_init(&r->findings);
}

void ob_report_free(ob_report *r) {
    free(r->file); free(r->format); free(r->endian); free(r->machine); free(r->type);
    free(r->profile); free(r->profile_source);
    free(r->interp); free(r->soname);
    for (size_t i = 0; i < r->nneeded; i++)  free(r->needed[i]);
    for (size_t i = 0; i < r->nrunpath; i++) free(r->runpath[i]);
    for (size_t i = 0; i < r->nrpath; i++)   free(r->rpath[i]);
    free(r->needed); free(r->runpath); free(r->rpath);
    for (size_t i = 0; i < r->nverreqs; i++) {
        free(r->verreqs[i].file);
        for (size_t j = 0; j < r->verreqs[i].nversions; j++) {
            free(r->verreqs[i].versions[j]);
        }
        free(r->verreqs[i].versions);
    }
    free(r->verreqs);
    free(r->glibc_required); free(r->glibc_baseline);
    ob_finding_list_free(&r->findings);
    memset(r, 0, sizeof(*r));
}

void ob_report_set_file(ob_report *r, const char *v)    { free(r->file);    r->file    = own(v, 0); }
void ob_report_set_format(ob_report *r, const char *v)  { free(r->format);  r->format  = own(v, 0); }
void ob_report_set_class(ob_report *r, int klass)       { r->klass = klass; }
void ob_report_set_endian(ob_report *r, const char *v)  { free(r->endian);  r->endian  = own(v, 0); }
void ob_report_set_machine(ob_report *r, const char *v) { free(r->machine); r->machine = own(v, 0); }
void ob_report_set_type(ob_report *r, const char *v)    { free(r->type);    r->type    = own(v, 0); }

void ob_report_set_profile(ob_report *r, const char *profile, const char *source) {
    free(r->profile);        r->profile        = own(profile, 0);
    free(r->profile_source); r->profile_source = own(source, 0);
}

void ob_report_set_interp(ob_report *r, const char *v) { free(r->interp); r->interp = own(v, 1); }
void ob_report_set_soname(ob_report *r, const char *v) { free(r->soname); r->soname = own(v, 1); }

void ob_report_set_glibc(ob_report *r, const char *required, const char *baseline) {
    free(r->glibc_required); r->glibc_required = own(required, 0);
    free(r->glibc_baseline); r->glibc_baseline = own(baseline, 0);
}

void ob_report_set_level(ob_report *r, ob_level level) { r->level = level; }

void ob_report_add_needed(ob_report *r, const char *v) {
    r->needed = strvec_push(r->needed, r->nneeded, own(v, 1));
    r->nneeded++;
}
void ob_report_add_runpath(ob_report *r, const char *v) {
    r->runpath = strvec_push(r->runpath, r->nrunpath, own(v, 1));
    r->nrunpath++;
}
void ob_report_add_rpath(ob_report *r, const char *v) {
    r->rpath = strvec_push(r->rpath, r->nrpath, own(v, 1));
    r->nrpath++;
}

void ob_report_add_verreq(ob_report *r, const char *file,
                           const char *const *versions, size_t n) {
    ob_verreq *p = realloc(r->verreqs, (r->nverreqs + 1) * sizeof(*p));
    if (!p) {
        abort();
    }
    r->verreqs = p;
    ob_verreq *g = &r->verreqs[r->nverreqs++];
    g->file = own(file, 1);
    g->versions = NULL;
    g->nversions = 0;
    if (n > 0) {
        g->versions = malloc(n * sizeof(char *));
        if (!g->versions) {
            abort();
        }
        for (size_t i = 0; i < n; i++) {
            g->versions[i] = own(versions[i], 1);
        }
        g->nversions = n;
    }
}

void ob_report_add_finding(ob_report *r, const char *id, const char *check,
                            ob_severity sev, const char *subject, const char *message) {
    /* Reserve the very last slot for a single OB0101 marker (01-SPEC-audit.md
     * §12) rather than silently dropping findings with no record it
     * happened — ob_finding_list_add's own cap has no headroom to add the
     * marker itself once genuinely full. */
    if (ob_finding_list_count(&r->findings) >= ONEBIN_MAX_FINDINGS - 1) {
        size_t n = ob_finding_list_count(&r->findings);
        for (size_t i = 0; i < n; i++) {
            if (strcmp(ob_finding_list_at(&r->findings, i)->id, "OB0101") == 0) {
                return; /* marker already recorded */
            }
        }
        ob_finding_list_add(&r->findings, "OB0101", "audit.findings_capped",
                             OB_SEV_WARN, "", "finding limit reached");
        return;
    }
    ob_finding_list_add(&r->findings, id, check, sev, subject, message);
}

static int strp_cmp(const void *pa, const void *pb) {
    const char *a = *(const char *const *)pa;
    const char *b = *(const char *const *)pb;
    return strcmp(a, b);
}

void ob_report_finalize(ob_report *r, ob_baseline *baseline, int strict) {
    ob_finding_list_sort_and_dedup(&r->findings);

    r->suppressed = 0;
    if (baseline) {
        r->suppressed = ob_baseline_apply(baseline, &r->findings);

        size_t nstale = ob_baseline_stale_count(baseline);
        for (size_t i = 0; i < nstale; i++) {
            const char *fp = ob_baseline_stale_at(baseline, i);
            /* fp is "<id>:<subject>"; recover just the subject for the
             * finding's own subject field, since add_finding will rebuild
             * the fingerprint from (id, subject) itself. */
            const char *colon = fp ? strchr(fp, ':') : NULL;
            const char *subject = colon ? colon + 1 : "";
            ob_report_add_finding(r, "OB0100", "baseline.stale", OB_SEV_INFO,
                                   subject, "stale baseline entry");
        }
        ob_finding_list_sort_and_dedup(&r->findings);
    }

    if (r->nneeded > 1) {
        qsort(r->needed, r->nneeded, sizeof(char *), strp_cmp);
    }
    if (r->nrunpath > 1) {
        qsort(r->runpath, r->nrunpath, sizeof(char *), strp_cmp);
    }
    if (r->nrpath > 1) {
        qsort(r->rpath, r->nrpath, sizeof(char *), strp_cmp);
    }
    if (r->nverreqs > 1) {
        /* sort groups by file */
        for (size_t i = 1; i < r->nverreqs; i++) {
            ob_verreq key = r->verreqs[i];
            size_t j = i;
            while (j > 0 && strcmp(r->verreqs[j - 1].file, key.file) > 0) {
                r->verreqs[j] = r->verreqs[j - 1];
                j--;
            }
            r->verreqs[j] = key;
        }
    }
    for (size_t i = 0; i < r->nverreqs; i++) {
        if (r->verreqs[i].nversions > 1) {
            qsort(r->verreqs[i].versions, r->verreqs[i].nversions, sizeof(char *), strp_cmp);
        }
    }

    size_t n_error = 0, n_warn = 0, n_info = 0, n_ok = 0;
    ob_finding_list_counts(&r->findings, &n_error, &n_warn, &n_info, &n_ok);
    r->n_error = n_error;
    r->n_warn = n_warn;
    r->n_info = n_info + n_ok; /* see report.h's comment on this field */

    r->passed = (n_error == 0) && !(strict && n_warn > 0);
}
