/* t_report.c — audit/report_text.c, audit/report_json.c.
 * 03-TESTPLAN.md §4.8 t_report.c, 01-SPEC-audit.md §9.
 */
#include "test.h"
#include "audit/report.h"
#include "report_fixtures.h"

#include <stdio.h>
#include <string.h>
#include <unistd.h>

static char *read_whole_file(const char *path, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        return NULL;
    }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = malloc((size_t)n + 1);
    if (!buf) {
        fclose(f);
        return NULL;
    }
    size_t rd = fread(buf, 1, (size_t)n, f);
    buf[rd] = '\0';
    fclose(f);
    if (out_len) {
        *out_len = rd;
    }
    return buf;
}

/* ------------------------------------------------------------------ item 1 */

TEST(report_same_render_twice_identical) {
    ob_report r;
    ob_report_init(&r);
    fixture_hybrid_ok(&r);
    ob_report_finalize(&r, NULL, 0);

    ob_jbuf a, b;
    ob_jbuf_init(&a);
    ob_jbuf_init(&b);
    ob_report_render_json(&r, &a, 0);
    ob_report_render_json(&r, &b, 0);
    ASSERT_EQ_STR(a.data, b.data);

    ob_jbuf ta, tb;
    ob_jbuf_init(&ta);
    ob_jbuf_init(&tb);
    ob_report_render_text(&r, &ta, 0, 0, 0);
    ob_report_render_text(&r, &tb, 0, 0, 0);
    ASSERT_EQ_STR(ta.data, tb.data);

    ob_jbuf_free(&a); ob_jbuf_free(&b); ob_jbuf_free(&ta); ob_jbuf_free(&tb);
    ob_report_free(&r);
}

/* ------------------------------------------------------------------ item 2 */

TEST(report_findings_sorted_regardless_of_add_order) {
    ob_report r1, r2;
    ob_report_init(&r1);
    ob_report_init(&r2);

    ob_report_add_finding(&r1, "OB0051", "harden.bindnow", OB_SEV_ERROR, "", "no BIND_NOW");
    ob_report_add_finding(&r1, "OB0011", "needed.none", OB_SEV_INFO, "", "fully static");
    ob_report_add_finding(&r1, "OB0041", "rpath.origin", OB_SEV_WARN, "x", "y");

    ob_report_add_finding(&r2, "OB0041", "rpath.origin", OB_SEV_WARN, "x", "y");
    ob_report_add_finding(&r2, "OB0051", "harden.bindnow", OB_SEV_ERROR, "", "no BIND_NOW");
    ob_report_add_finding(&r2, "OB0011", "needed.none", OB_SEV_INFO, "", "fully static");

    ob_report_finalize(&r1, NULL, 0);
    ob_report_finalize(&r2, NULL, 0);

    ASSERT_EQ_INT(ob_finding_list_count(&r1.findings), ob_finding_list_count(&r2.findings));
    size_t n = ob_finding_list_count(&r1.findings);
    for (size_t i = 0; i < n; i++) {
        ASSERT_EQ_STR(ob_finding_list_at(&r1.findings, i)->id,
                      ob_finding_list_at(&r2.findings, i)->id);
    }
    /* And sorted: OB0011 < OB0041 < OB0051, byte-wise. */
    ASSERT_EQ_STR(ob_finding_list_at(&r1.findings, 0)->id, "OB0011");
    ASSERT_EQ_STR(ob_finding_list_at(&r1.findings, 1)->id, "OB0041");
    ASSERT_EQ_STR(ob_finding_list_at(&r1.findings, 2)->id, "OB0051");

    ob_report_free(&r1);
    ob_report_free(&r2);
}

/* ------------------------------------------------------------------ item 3 */

TEST(report_json_has_every_key_in_order) {
    static const char *const expected_keys[] = {
        "\"schema\"", "\"file\"", "\"format\"", "\"class\"", "\"endian\"",
        "\"machine\"", "\"type\"", "\"profile\"", "\"profile_source\"",
        "\"interp\"", "\"soname\"", "\"needed\"", "\"runpath\"", "\"rpath\"",
        "\"glibc_required\"", "\"glibc_baseline\"", "\"version_requirements\"",
        "\"level\"", "\"result\"", "\"counts\"", "\"suppressed\"", "\"findings\""
    };
    ob_report r;
    ob_report_init(&r);
    fixture_static_clean(&r); /* every optional field NULL/empty at once */
    ob_report_finalize(&r, NULL, 0);

    ob_jbuf out;
    ob_jbuf_init(&out);
    ob_report_render_json(&r, &out, 0);

    const char *cursor = out.data;
    for (size_t i = 0; i < sizeof(expected_keys) / sizeof(expected_keys[0]); i++) {
        const char *found = strstr(cursor, expected_keys[i]);
        ASSERT_NOT_NULL(found);
        cursor = found + strlen(expected_keys[i]);
    }
    /* null/empty values present, not omitted */
    ASSERT_TRUE(strstr(out.data, "\"interp\": null") != NULL);
    ASSERT_TRUE(strstr(out.data, "\"needed\": []") != NULL);

    ob_jbuf_free(&out);
    ob_report_free(&r);
}

/* ------------------------------------------------------------------ item 4 */

TEST(report_counts_match_actual_findings) {
    ob_report r;
    ob_report_init(&r);
    ob_report_add_finding(&r, "OB0010", "x", OB_SEV_ERROR, "a", "m");
    ob_report_add_finding(&r, "OB0011", "x", OB_SEV_ERROR, "b", "m");
    ob_report_add_finding(&r, "OB0012", "x", OB_SEV_WARN, "c", "m");
    ob_report_add_finding(&r, "OB0013", "x", OB_SEV_INFO, "d", "m");
    ob_report_add_finding(&r, "OB0014", "x", OB_SEV_OK, "e", "m");
    ob_report_finalize(&r, NULL, 0);

    ASSERT_EQ_INT(r.n_error, 2);
    ASSERT_EQ_INT(r.n_warn, 1);
    ASSERT_EQ_INT(r.n_info, 2); /* 1 true info + 1 ok, per report.h's note */
    ASSERT_FALSE(r.passed);

    ob_report_free(&r);
}

/* ------------------------------------------------------------------ item 5 */

TEST(report_quiet_shows_only_verdict_and_fail_lines) {
    ob_report r;
    ob_report_init(&r);
    fixture_hybrid_ok(&r);
    ob_report_finalize(&r, NULL, 0);

    ob_jbuf out;
    ob_jbuf_init(&out);
    ob_report_render_text(&r, &out, 0, 1 /* quiet */, 0);

    ASSERT_TRUE(strstr(out.data, "OB0051") != NULL);  /* the FAIL line */
    ASSERT_TRUE(strstr(out.data, "OB0011") == NULL);   /* ok, hidden */
    ASSERT_TRUE(strstr(out.data, "OB0041") == NULL);   /* warn, hidden */
    ASSERT_TRUE(strstr(out.data, "==") == NULL);        /* no header block */
    ASSERT_TRUE(strstr(out.data, "FAIL  Level 1") != NULL);

    ob_jbuf_free(&out);
    ob_report_free(&r);
}

/* ------------------------------------------------------------------ item 6 */

TEST(report_verbose_shows_info_findings) {
    ob_report r;
    ob_report_init(&r);
    fixture_static_clean(&r); /* has a true INFO finding, OB0011 */
    ob_report_finalize(&r, NULL, 0);

    ob_jbuf quiet_off_not_verbose;
    ob_jbuf_init(&quiet_off_not_verbose);
    ob_report_render_text(&r, &quiet_off_not_verbose, 0, 0, 0);
    ASSERT_TRUE(strstr(quiet_off_not_verbose.data, "OB0011") == NULL);

    ob_jbuf verbose;
    ob_jbuf_init(&verbose);
    ob_report_render_text(&r, &verbose, 1, 0, 0);
    ASSERT_TRUE(strstr(verbose.data, "OB0011") != NULL);

    ob_jbuf_free(&quiet_off_not_verbose);
    ob_jbuf_free(&verbose);
    ob_report_free(&r);
}

/* ------------------------------------------------------------------ item 7 */

TEST(report_no_color_produces_no_ansi) {
    ob_report r;
    ob_report_init(&r);
    fixture_hybrid_ok(&r);
    ob_report_finalize(&r, NULL, 0);

    ob_jbuf plain;
    ob_jbuf_init(&plain);
    ob_report_render_text(&r, &plain, 0, 0, 0 /* use_color = 0 */);
    ASSERT_TRUE(strchr(plain.data, '\x1b') == NULL);

    ob_jbuf colored;
    ob_jbuf_init(&colored);
    ob_report_render_text(&r, &colored, 0, 0, 1 /* use_color = 1 */);
    ASSERT_TRUE(strchr(colored.data, '\x1b') != NULL);

    ob_jbuf_free(&plain);
    ob_jbuf_free(&colored);
    ob_report_free(&r);
}

/* ------------------------------------------------------------------ item 8 */

static void assert_matches_golden(const char *name, ob_report *r) {
    ob_jbuf j;
    ob_jbuf_init(&j);
    ob_report_render_json(r, &j, 0);
    ob_jbuf_putc(&j, '\n');

    char path[256];
    snprintf(path, sizeof(path), "tests/golden/%s.json", name);
    char *expected = read_whole_file(path, NULL);
    ASSERT_NOT_NULL(expected);
    ASSERT_EQ_STR(j.data, expected);
    free(expected);
    ob_jbuf_free(&j);

    ob_jbuf t;
    ob_jbuf_init(&t);
    ob_report_render_text(r, &t, 0, 0, 0);
    snprintf(path, sizeof(path), "tests/golden/%s.text", name);
    expected = read_whole_file(path, NULL);
    ASSERT_NOT_NULL(expected);
    ASSERT_EQ_STR(t.data, expected);
    free(expected);
    ob_jbuf_free(&t);
}

TEST(golden_hybrid_ok) {
    ob_report r;
    ob_report_init(&r);
    fixture_hybrid_ok(&r);
    ob_report_finalize(&r, NULL, 0);
    assert_matches_golden("hybrid-ok", &r);
    ob_report_free(&r);
}

TEST(golden_static_clean) {
    ob_report r;
    ob_report_init(&r);
    fixture_static_clean(&r);
    ob_report_finalize(&r, NULL, 0);
    assert_matches_golden("static-clean", &r);
    ob_report_free(&r);
}

TEST(golden_module) {
    ob_report r;
    ob_report_init(&r);
    fixture_module(&r);
    ob_report_finalize(&r, NULL, 0);
    assert_matches_golden("module", &r);
    ob_report_free(&r);
}

TEST(golden_baseline_suppressed) {
    char path[128];
    snprintf(path, sizeof(path), "/tmp/onebin_t_report_baseline_%d", (int)getpid());

    ob_report r;
    ob_baseline bl;
    ob_report_init(&r);
    fixture_baseline_suppressed(&r, path, &bl);
    ob_report_finalize(&r, &bl, 0);
    assert_matches_golden("baseline-suppressed", &r);

    ob_baseline_free(&bl);
    ob_report_free(&r);
    unlink(path);
}

TEST(golden_many_needed) {
    ob_report r;
    ob_report_init(&r);
    fixture_many_needed(&r);
    ob_report_finalize(&r, NULL, 0);
    assert_matches_golden("many-needed", &r);
    ob_report_free(&r);
}

TEST(golden_sanitized) {
    ob_report r;
    ob_report_init(&r);
    fixture_sanitized(&r);
    ob_report_finalize(&r, NULL, 0);
    assert_matches_golden("sanitized", &r);
    ob_report_free(&r);
}
