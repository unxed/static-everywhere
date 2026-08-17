/* audit/report.h — one file's audit result. 00-AGENT-TASK.md Task 7,
 * 01-SPEC-audit.md §9.1/§9.2's schema.
 *
 * This module owns nothing about HOW a value was determined — a caller
 * (Task 8's checks, or a test building a fixture by hand) sets every field
 * directly. Every setter that takes a string sanitises it (§9.3) and takes
 * its own copy, so callers are free to pass stack buffers.
 */
#ifndef AUDIT_REPORT_H
#define AUDIT_REPORT_H

#include "onebin/audit.h"
#include "audit/finding.h"
#include "audit/baseline.h"
#include "util/json.h"

/* One Verneed group for the JSON "version_requirements" array: a file and
 * the (sanitised) version strings required from it. */
typedef struct {
    char   *file;
    char  **versions;
    size_t  nversions;
} ob_verreq;

typedef struct {
    /* identity, §9.2 keys "file".."type" */
    char *file;
    char *format;   /* "elf" */
    int   klass;     /* 32 | 64; 0 means "not set" */
    char *endian;    /* "little" | "big" | NULL */
    char *machine;   /* e.g. "x86_64", or "0x1234"; NULL if not set */
    char *type;      /* "ET_EXEC" | "ET_DYN" | ...; NULL if not set */

    /* §9.2 "profile"/"profile_source" */
    char *profile;         /* "static" | "hybrid" | "module" */
    char *profile_source;  /* "auto" | "flag" */

    char *interp;  /* NULL if absent; sanitised */
    char *soname;  /* NULL if absent; sanitised */

    char **needed;    size_t nneeded;    /* sanitised, owned strings */
    char **runpath;   size_t nrunpath;
    char **rpath;     size_t nrpath;

    char *glibc_required;  /* NULL if unknown (01-SPEC-audit.md §6.3) */
    char *glibc_baseline;  /* NULL if not checked for this file */

    ob_verreq *verreqs; size_t nverreqs;

    ob_level level;

    ob_finding_list findings;
    size_t suppressed; /* set by ob_report_finalize when baseline != NULL */

    /* computed by ob_report_finalize(): "info" here already folds in "ok"
     * findings, per this project's reading of 01-SPEC-audit.md §9.1's
     * example (see NOTES.md) — the per-finding severity string is not
     * affected, only this summary total. */
    size_t n_error, n_warn, n_info;
    int    passed; /* 1 = PASS, 0 = FAIL */
} ob_report;

void ob_report_init(ob_report *r);
void ob_report_free(ob_report *r);

void ob_report_set_file(ob_report *r, const char *v);
void ob_report_set_format(ob_report *r, const char *v);
void ob_report_set_class(ob_report *r, int klass);
void ob_report_set_endian(ob_report *r, const char *v);
void ob_report_set_machine(ob_report *r, const char *v);
void ob_report_set_type(ob_report *r, const char *v);
void ob_report_set_profile(ob_report *r, const char *profile, const char *source);
void ob_report_set_interp(ob_report *r, const char *v); /* raw; sanitised internally; NULL clears */
void ob_report_set_soname(ob_report *r, const char *v);
void ob_report_set_glibc(ob_report *r, const char *required, const char *baseline);
void ob_report_set_level(ob_report *r, ob_level level);

void ob_report_add_needed(ob_report *r, const char *v);  /* raw; sanitised internally */
void ob_report_add_runpath(ob_report *r, const char *v);
void ob_report_add_rpath(ob_report *r, const char *v);
void ob_report_add_verreq(ob_report *r, const char *file,
                           const char *const *versions, size_t n);

void ob_report_add_finding(ob_report *r, const char *id, const char *check,
                            ob_severity sev, const char *subject, const char *message);

/* Sorts+dedups findings; if `baseline` is non-NULL, suppresses matching
 * findings (dropping them from the list — the same finding is never both
 * "suppressed" and "counted"), adds one OB0100 info finding per stale
 * baseline entry, and re-sorts. Computes n_error/n_warn/n_info and the
 * PASS/FAIL verdict: FAIL iff n_error > 0, or (strict && n_warn > 0). Must
 * be called exactly once, after every finding has been added. */
void ob_report_finalize(ob_report *r, ob_baseline *baseline, int strict);

/* audit/report_text.c. `out` is appended to (not reset), so callers can
 * concatenate several files' reports the way the CLI does for multiple
 * inputs. */
void ob_report_render_text(const ob_report *r, ob_jbuf *out,
                            int verbose, int quiet, int use_color);

/* audit/report_json.c. Writes exactly one JSON object (no trailing comma,
 * no enclosing array — the CLI wraps multiple files in `[...]` itself,
 * 01-SPEC-audit.md §9.2 / 03-TESTPLAN.md §4.8 t_cli.c #20-21). Does NOT
 * append a trailing newline; the caller decides that once per whole
 * document, per §9.2's "exactly one \n at end of file". */
void ob_report_render_json(const ob_report *r, ob_jbuf *out, int depth);

#endif /* AUDIT_REPORT_H */
