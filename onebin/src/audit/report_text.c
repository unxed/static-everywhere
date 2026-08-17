/* audit/report_text.c — 01-SPEC-audit.md §9.1. 00-AGENT-TASK.md Task 7. */
#include "audit/report.h"
#include "util/json.h" /* ob_jbuf: a plain growable buffer, not JSON-specific
                         * despite the name — see util/json.h's own note.
                         * Reusing it here rather than writing a second
                         * growable-buffer type is the same "one copy" rule
                         * util/vec.h's header comment states. */

#include <string.h>

/* Exactly 4 characters, per 01-SPEC-audit.md §9.1: "Severity column is
 * fixed width: `ok  `, `info`, `warn`, `FAIL`." OB_SEV_FATAL also renders
 * FAIL — a fatal finding does not normally reach a finalized report (it
 * aborts the whole file before one is built), but if it ever does, treating
 * it as anything other than the worst label would be a silent downgrade. */
static const char *sev_label(ob_severity sev) {
    switch (sev) {
    case OB_SEV_OK:    return "ok  ";
    case OB_SEV_INFO:  return "info";
    case OB_SEV_WARN:  return "warn";
    case OB_SEV_ERROR: return "FAIL";
    case OB_SEV_FATAL: return "FAIL";
    }
    return "?   ";
}

/* ANSI SGR codes for --no-color's opposite: green/yellow/red/default,
 * 01-SPEC-audit.md §9.1's colour rule. */
static const char *sev_color(ob_severity sev) {
    switch (sev) {
    case OB_SEV_OK:    return "\x1b[32m"; /* green */
    case OB_SEV_WARN:  return "\x1b[33m"; /* yellow */
    case OB_SEV_ERROR:
    case OB_SEV_FATAL: return "\x1b[31m"; /* red */
    case OB_SEV_INFO:  return "";          /* default: no colour */
    }
    return "";
}
#define SEV_RESET "\x1b[0m"

static void put_line_findings(ob_jbuf *b, const ob_report *r, int verbose,
                               int quiet, int use_color) {
    size_t n = ob_finding_list_count(&r->findings);
    for (size_t i = 0; i < n; i++) {
        const ob_finding *f = ob_finding_list_at(&r->findings, i);
        int is_fail = (f->severity == OB_SEV_ERROR || f->severity == OB_SEV_FATAL);
        /* OK findings are shown by default — they are positive
         * confirmations, not the "background noise" the --verbose gate is
         * for. Only true INFO severity is hidden by default
         * (01-SPEC-audit.md §9.1: "Info findings are hidden unless
         * --verbose", read literally as scoped to that one severity — the
         * §9.1 worked example shows an "ok" line with no --verbose in
         * sight). Both still count towards the "infos" summary bucket
         * (report.h's note on n_info), so a hidden INFO finding is still
         * visible in the totals even when the line itself is not printed. */
        int is_hidden = (f->severity == OB_SEV_INFO) && !verbose;

        if (quiet && !is_fail) {
            continue;
        }
        if (!quiet && is_hidden) {
            continue;
        }

        ob_jbuf_puts(b, "  ");
        if (use_color && sev_color(f->severity)[0]) {
            ob_jbuf_puts(b, sev_color(f->severity));
            ob_jbuf_puts(b, sev_label(f->severity));
            ob_jbuf_puts(b, SEV_RESET);
        } else {
            ob_jbuf_puts(b, sev_label(f->severity));
        }
        ob_jbuf_puts(b, "  ");
        ob_jbuf_puts(b, f->id);
        ob_jbuf_puts(b, "  ");
        ob_jbuf_puts(b, f->message);
        if (f->subject[0]) {
            ob_jbuf_puts(b, ": ");
            ob_jbuf_puts(b, f->subject);
        }
        ob_jbuf_putc(b, '\n');
    }
}

static const char *level_num(ob_level level) {
    switch (level) {
    case OB_LEVEL_0: return "0";
    case OB_LEVEL_1: return "1";
    case OB_LEVEL_2: return "2";
    case OB_LEVEL_3: return "3";
    }
    return "?";
}

static void put_u64(ob_jbuf *b, size_t v) {
    char digits[24];
    int n = 0;
    if (v == 0) {
        ob_jbuf_putc(b, '0');
        return;
    }
    while (v > 0 && n < (int)sizeof(digits)) {
        digits[n++] = (char)('0' + (v % 10));
        v /= 10;
    }
    while (n > 0) {
        ob_jbuf_putc(b, digits[--n]);
    }
}

void ob_report_render_text(const ob_report *r, ob_jbuf *out,
                            int verbose, int quiet, int use_color) {
    if (!quiet) {
        ob_jbuf_puts(out, "== ");
        ob_jbuf_puts(out, r->file ? r->file : "");
        ob_jbuf_puts(out, " ==\n");

        ob_jbuf_puts(out, "  profile: ");
        ob_jbuf_puts(out, r->profile ? r->profile : "?");
        ob_jbuf_puts(out, " (");
        if (r->profile_source && strcmp(r->profile_source, "flag") == 0) {
            ob_jbuf_puts(out, "--profile");
        } else {
            ob_jbuf_puts(out, "auto-detected");
        }
        ob_jbuf_puts(out, ")   class: ELF");
        ob_jbuf_puts(out, r->klass == 32 ? "32" : "64");
        ob_jbuf_putc(out, ' ');
        ob_jbuf_puts(out, (r->endian && strcmp(r->endian, "big") == 0) ? "BE" : "LE");
        ob_jbuf_putc(out, ' ');
        ob_jbuf_puts(out, r->machine ? r->machine : "?");
        ob_jbuf_putc(out, ' ');
        ob_jbuf_puts(out, r->type ? r->type : "?");
        ob_jbuf_putc(out, '\n');

        if (r->interp) {
            ob_jbuf_puts(out, "  interp:  ");
            ob_jbuf_puts(out, r->interp);
            ob_jbuf_putc(out, '\n');
        }
        if (r->soname) {
            ob_jbuf_puts(out, "  soname:  ");
            ob_jbuf_puts(out, r->soname);
            ob_jbuf_putc(out, '\n');
        }
        if (r->nneeded > 0) {
            ob_jbuf_puts(out, "  needed:  ");
            for (size_t i = 0; i < r->nneeded; i++) {
                if (i > 0) ob_jbuf_putc(out, ' ');
                ob_jbuf_puts(out, r->needed[i]);
            }
            ob_jbuf_putc(out, '\n');
        }
        if (r->glibc_baseline) {
            ob_jbuf_puts(out, "  glibc:   requires ");
            ob_jbuf_puts(out, r->glibc_required ? r->glibc_required : "none");
            ob_jbuf_puts(out, ", baseline ");
            ob_jbuf_puts(out, r->glibc_baseline);
            ob_jbuf_putc(out, '\n');
        }
        ob_jbuf_putc(out, '\n');
    }

    put_line_findings(out, r, verbose, quiet, use_color);
    if (!quiet) {
        ob_jbuf_putc(out, '\n');
    }

    ob_jbuf_puts(out, r->passed ? "PASS" : "FAIL");
    ob_jbuf_puts(out, "  Level ");
    ob_jbuf_puts(out, level_num(r->level));
    ob_jbuf_puts(out, "  (");
    put_u64(out, r->n_error);
    ob_jbuf_puts(out, r->n_error == 1 ? " error, " : " errors, ");
    put_u64(out, r->n_warn);
    ob_jbuf_puts(out, r->n_warn == 1 ? " warning, " : " warnings, ");
    put_u64(out, r->n_info);
    ob_jbuf_puts(out, r->n_info == 1 ? " info" : " infos");
    if (r->suppressed > 0) {
        ob_jbuf_puts(out, ", ");
        put_u64(out, r->suppressed);
        ob_jbuf_puts(out, r->suppressed == 1 ? " suppressed" : " suppressed");
    }
    ob_jbuf_puts(out, ")\n");
}
