/* t_baseline.c — audit/baseline.c.  03-TESTPLAN.md §4.8 t_baseline.c,
 * 01-SPEC-audit.md §9.4.
 */
#include "test.h"
#include "audit/report.h"

#include <stdio.h>
#include <string.h>
#include <unistd.h>

static char *tmp_path(char *buf, size_t n, const char *name) {
    snprintf(buf, n, "/tmp/onebin_t_baseline_%s_%d", name, (int)getpid());
    return buf;
}

static void write_file(const char *path, const char *content) {
    FILE *f = fopen(path, "w");
    ASSERT_NOT_NULL(f);
    fputs(content, f);
    fclose(f);
}

/* ------------------------------------------------------------------ item 1 */

TEST(baseline_suppresses_matching_fingerprint) {
    char path[128];
    tmp_path(path, sizeof(path), "1");
    write_file(path, "OB0041:$ORIGIN/../lib\n");

    ob_baseline bl;
    ASSERT_EQ_INT(ob_baseline_load(path, &bl), OB_BASELINE_OK);

    ob_report r;
    ob_report_init(&r);
    ob_report_add_finding(&r, "OB0041", "rpath.origin", OB_SEV_WARN,
                           "$ORIGIN/../lib", "RUNPATH is $ORIGIN-relative");
    ob_report_add_finding(&r, "OB0011", "needed.none", OB_SEV_INFO, "", "fully static");
    ob_report_finalize(&r, &bl, 0);

    ASSERT_EQ_INT(r.suppressed, 1);
    ASSERT_EQ_INT(ob_finding_list_count(&r.findings), 1);
    ASSERT_EQ_STR(ob_finding_list_at(&r.findings, 0)->id, "OB0011");

    ob_report_free(&r);
    ob_baseline_free(&bl);
    unlink(path);
}

/* ------------------------------------------------------------------ item 2 */

TEST(baseline_suppression_flips_fail_to_pass) {
    char path[128];
    tmp_path(path, sizeof(path), "2");
    write_file(path, "OB0051:\n");

    ob_baseline bl;
    ASSERT_EQ_INT(ob_baseline_load(path, &bl), OB_BASELINE_OK);

    ob_report r;
    ob_report_init(&r);
    ob_report_add_finding(&r, "OB0051", "harden.bindnow", OB_SEV_ERROR, "", "no BIND_NOW");
    ob_report_finalize(&r, NULL, 0);
    ASSERT_FALSE(r.passed);
    ob_report_free(&r);

    ob_report r3;
    ob_report_init(&r3);
    ob_report_add_finding(&r3, "OB0051", "harden.bindnow", OB_SEV_ERROR, "", "no BIND_NOW");
    ob_report_finalize(&r3, &bl, 0);
    ASSERT_TRUE(r3.passed);
    ASSERT_EQ_INT(r3.n_error, 0);

    ob_report_free(&r3);
    ob_baseline_free(&bl);
    unlink(path);
}

/* ------------------------------------------------------------------ item 3 */

TEST(baseline_suppressed_count_appears_in_json) {
    char path[128];
    tmp_path(path, sizeof(path), "3");
    write_file(path, "OB0011:\n");

    ob_baseline bl;
    ASSERT_EQ_INT(ob_baseline_load(path, &bl), OB_BASELINE_OK);

    ob_report r;
    ob_report_init(&r);
    ob_report_set_file(&r, "x.elf");
    ob_report_set_format(&r, "elf");
    ob_report_add_finding(&r, "OB0011", "needed.none", OB_SEV_INFO, "", "fully static");
    ob_report_finalize(&r, &bl, 0);

    ob_jbuf out;
    ob_jbuf_init(&out);
    ob_report_render_json(&r, &out, 0);
    ASSERT_TRUE(strstr(out.data, "\"suppressed\": 1") != NULL);

    ob_jbuf_free(&out);
    ob_report_free(&r);
    ob_baseline_free(&bl);
    unlink(path);
}

/* ------------------------------------------------------------------ item 4 */

TEST(baseline_stale_entry_produces_ob0100) {
    char path[128];
    tmp_path(path, sizeof(path), "4");
    write_file(path, "OB9999:nothing-matches-this\n");

    ob_baseline bl;
    ASSERT_EQ_INT(ob_baseline_load(path, &bl), OB_BASELINE_OK);

    ob_report r;
    ob_report_init(&r);
    ob_report_add_finding(&r, "OB0011", "needed.none", OB_SEV_INFO, "", "fully static");
    ob_report_finalize(&r, &bl, 0);

    int found = 0;
    size_t n = ob_finding_list_count(&r.findings);
    for (size_t i = 0; i < n; i++) {
        const ob_finding *f = ob_finding_list_at(&r.findings, i);
        if (strcmp(f->id, "OB0100") == 0) {
            found = 1;
            ASSERT_EQ_INT(f->severity, OB_SEV_INFO);
            ASSERT_EQ_STR(f->subject, "nothing-matches-this");
        }
    }
    ASSERT_TRUE(found);

    ob_report_free(&r);
    ob_baseline_free(&bl);
    unlink(path);
}

/* ------------------------------------------------------------------ item 5 */

TEST(baseline_write_then_load_suppresses_everything) {
    char path[128];
    tmp_path(path, sizeof(path), "5");

    ob_report r;
    ob_report_init(&r);
    ob_report_add_finding(&r, "OB0041", "rpath.origin", OB_SEV_WARN, "$ORIGIN/../lib", "msg");
    ob_report_add_finding(&r, "OB0060", "hygiene.buildpath", OB_SEV_WARN, "/home/x", "msg");
    ob_finding_list_sort_and_dedup(&r.findings);
    ASSERT_EQ_INT(ob_baseline_write(path, &r.findings), 0);
    ob_report_free(&r);

    ob_baseline bl;
    ASSERT_EQ_INT(ob_baseline_load(path, &bl), OB_BASELINE_OK);

    ob_report r2;
    ob_report_init(&r2);
    ob_report_add_finding(&r2, "OB0041", "rpath.origin", OB_SEV_WARN, "$ORIGIN/../lib", "msg");
    ob_report_add_finding(&r2, "OB0060", "hygiene.buildpath", OB_SEV_WARN, "/home/x", "msg");
    ob_report_finalize(&r2, &bl, 0);

    ASSERT_EQ_INT(ob_finding_list_count(&r2.findings), 0);
    ASSERT_EQ_INT(r2.suppressed, 2);
    ASSERT_TRUE(r2.passed);

    ob_report_free(&r2);
    ob_baseline_free(&bl);
    unlink(path);
}

/* ------------------------------------------------------------------ item 6 */

TEST(baseline_parses_comments_blank_crlf_trailing_ws) {
    char path[128];
    tmp_path(path, sizeof(path), "6");
    write_file(path,
        "# onebin baseline v1\r\n"
        "# generated by: onebin audit --write-baseline\r\n"
        "\r\n"
        "   \r\n"
        "OB0041:$ORIGIN/../lib  \r\n"
        "\n"
        "# a comment in the middle\n"
        "OB0060:/home/builder/src/main.c\t\n");

    ob_baseline bl;
    ASSERT_EQ_INT(ob_baseline_load(path, &bl), OB_BASELINE_OK);
    ASSERT_TRUE(ob_baseline_contains(&bl, "OB0041:$ORIGIN/../lib"));
    ASSERT_TRUE(ob_baseline_contains(&bl, "OB0060:/home/builder/src/main.c"));

    ob_baseline_free(&bl);
    unlink(path);
}

/* ------------------------------------------------------------------ item 7 */

TEST(baseline_nonexistent_file_is_open_error) {
    ob_baseline bl;
    ob_baseline_err e = ob_baseline_load("/tmp/onebin_this_file_does_not_exist_xyz", &bl);
    ASSERT_EQ_INT(e, OB_BASELINE_ERR_OPEN);
}

/* ------------------------------------------------------------------ item 8 */

TEST(baseline_10000_entries_bounded) {
    char path[128];
    tmp_path(path, sizeof(path), "8");

    FILE *f = fopen(path, "w");
    ASSERT_NOT_NULL(f);
    for (int i = 0; i < 10000; i++) {
        fprintf(f, "OB0041:entry-%d\n", i);
    }
    fclose(f);

    ob_baseline bl;
    ASSERT_EQ_INT(ob_baseline_load(path, &bl), OB_BASELINE_OK);
    ASSERT_TRUE(ob_baseline_contains(&bl, "OB0041:entry-9999"));

    ob_baseline_free(&bl);
    unlink(path);
}
