/* audit/report_json.c — 01-SPEC-audit.md §9.2. 00-AGENT-TASK.md Task 7.
 *
 * Key order, indentation and the array-layout rule are all hard
 * requirements: golden tests compare bytes. See NOTES.md for the two
 * decisions §9.2 leaves to the implementer (the array-inlining threshold,
 * and where "suppressed" goes).
 */
#include "audit/report.h"

#include <string.h>

static void indent(ob_jbuf *b, int depth) {
    ob_jbuf_indent(b, depth);
}

static void put_i64(ob_jbuf *b, long long v) {
    if (v < 0) {
        ob_jbuf_putc(b, '-');
        v = -v;
    }
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

/* 01-SPEC-audit.md §9.2 formatting rules: "Pick one and apply it
 * mechanically... always use one element per line for arrays of length >= 4
 * and inline otherwise" — this is that documented choice (NOTES.md). */
#define OB_JSON_ARRAY_INLINE_MAX 3

static void put_string_array(ob_jbuf *b, char *const *items, size_t n, int depth) {
    if (n == 0) {
        ob_jbuf_puts(b, "[]");
        return;
    }
    if (n <= OB_JSON_ARRAY_INLINE_MAX) {
        ob_jbuf_putc(b, '[');
        for (size_t i = 0; i < n; i++) {
            if (i > 0) {
                ob_jbuf_puts(b, ", ");
            }
            ob_jbuf_string(b, items[i]);
        }
        ob_jbuf_putc(b, ']');
        return;
    }
    ob_jbuf_puts(b, "[\n");
    for (size_t i = 0; i < n; i++) {
        indent(b, depth + 1);
        ob_jbuf_string(b, items[i]);
        if (i + 1 < n) {
            ob_jbuf_putc(b, ',');
        }
        ob_jbuf_putc(b, '\n');
    }
    indent(b, depth);
    ob_jbuf_putc(b, ']');
}

static void put_key(ob_jbuf *b, int depth, const char *key) {
    indent(b, depth);
    ob_jbuf_string(b, key);
    ob_jbuf_puts(b, ": ");
}

static void put_kv_str(ob_jbuf *b, int depth, const char *key, const char *val, int comma) {
    put_key(b, depth, key);
    if (val) {
        ob_jbuf_string(b, val);
    } else {
        ob_jbuf_puts(b, "null");
    }
    ob_jbuf_puts(b, comma ? ",\n" : "\n");
}

static void put_kv_int(ob_jbuf *b, int depth, const char *key, long long val, int comma) {
    put_key(b, depth, key);
    put_i64(b, val);
    ob_jbuf_puts(b, comma ? ",\n" : "\n");
}

static void put_findings(ob_jbuf *b, const ob_report *r, int depth) {
    size_t n = ob_finding_list_count(&r->findings);
    if (n == 0) {
        ob_jbuf_puts(b, "[]");
        return;
    }
    ob_jbuf_puts(b, "[\n");
    for (size_t i = 0; i < n; i++) {
        const ob_finding *f = ob_finding_list_at(&r->findings, i);
        indent(b, depth + 1);
        ob_jbuf_puts(b, "{\n");
        put_kv_str(b, depth + 2, "id", f->id, 1);
        put_kv_str(b, depth + 2, "check", f->check, 1);
        put_kv_str(b, depth + 2, "severity", ob_severity_name(f->severity), 1);
        put_kv_str(b, depth + 2, "subject", f->subject, 1);
        put_kv_str(b, depth + 2, "message", f->message, 1);
        put_kv_str(b, depth + 2, "fingerprint", f->fingerprint, 0);
        indent(b, depth + 1);
        ob_jbuf_puts(b, (i + 1 < n) ? "},\n" : "}\n");
    }
    indent(b, depth);
    ob_jbuf_putc(b, ']');
}

static void put_verreqs(ob_jbuf *b, const ob_report *r, int depth) {
    if (r->nverreqs == 0) {
        ob_jbuf_puts(b, "[]");
        return;
    }
    ob_jbuf_puts(b, "[\n");
    for (size_t i = 0; i < r->nverreqs; i++) {
        const ob_verreq *g = &r->verreqs[i];
        indent(b, depth + 1);
        ob_jbuf_puts(b, "{\n");
        put_kv_str(b, depth + 2, "file", g->file, 1);
        put_key(b, depth + 2, "versions");
        put_string_array(b, g->versions, g->nversions, depth + 2);
        ob_jbuf_putc(b, '\n');
        indent(b, depth + 1);
        ob_jbuf_puts(b, (i + 1 < r->nverreqs) ? "},\n" : "}\n");
    }
    indent(b, depth);
    ob_jbuf_putc(b, ']');
}

void ob_report_render_json(const ob_report *r, ob_jbuf *b, int depth) {
    indent(b, depth);
    ob_jbuf_puts(b, "{\n");
    int d = depth + 1;

    put_kv_int(b, d, "schema", 1, 1);
    put_kv_str(b, d, "file", r->file, 1);
    put_kv_str(b, d, "format", r->format, 1);
    put_kv_int(b, d, "class", r->klass, 1);
    put_kv_str(b, d, "endian", r->endian, 1);
    put_kv_str(b, d, "machine", r->machine, 1);
    put_kv_str(b, d, "type", r->type, 1);
    put_kv_str(b, d, "profile", r->profile, 1);
    put_kv_str(b, d, "profile_source", r->profile_source, 1);
    put_kv_str(b, d, "interp", r->interp, 1);
    put_kv_str(b, d, "soname", r->soname, 1);

    put_key(b, d, "needed");
    put_string_array(b, r->needed, r->nneeded, d);
    ob_jbuf_puts(b, ",\n");

    put_key(b, d, "runpath");
    put_string_array(b, r->runpath, r->nrunpath, d);
    ob_jbuf_puts(b, ",\n");

    put_key(b, d, "rpath");
    put_string_array(b, r->rpath, r->nrpath, d);
    ob_jbuf_puts(b, ",\n");

    put_kv_str(b, d, "glibc_required", r->glibc_required, 1);
    put_kv_str(b, d, "glibc_baseline", r->glibc_baseline, 1);

    put_key(b, d, "version_requirements");
    put_verreqs(b, r, d);
    ob_jbuf_puts(b, ",\n");

    put_kv_int(b, d, "level", (long long)r->level, 1);
    put_kv_str(b, d, "result", r->passed ? "pass" : "fail", 1);

    put_key(b, d, "counts");
    ob_jbuf_puts(b, "{ ");
    ob_jbuf_string(b, "error"); ob_jbuf_puts(b, ": "); put_i64(b, (long long)r->n_error);
    ob_jbuf_puts(b, ", ");
    ob_jbuf_string(b, "warn"); ob_jbuf_puts(b, ": "); put_i64(b, (long long)r->n_warn);
    ob_jbuf_puts(b, ", ");
    ob_jbuf_string(b, "info"); ob_jbuf_puts(b, ": "); put_i64(b, (long long)r->n_info);
    ob_jbuf_puts(b, " },\n");

    /* "suppressed" is this project's addition to §9.2's example (which
     * predates the baseline discussion in §9.4): always present, per the
     * "never omit a key" rule applied consistently, so a consumer never has
     * to branch on whether a baseline was used. NOTES.md. */
    put_kv_int(b, d, "suppressed", (long long)r->suppressed, 1);

    put_key(b, d, "findings");
    put_findings(b, r, d);
    ob_jbuf_putc(b, '\n');

    indent(b, depth);
    ob_jbuf_putc(b, '}');
}
