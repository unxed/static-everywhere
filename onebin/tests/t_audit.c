/* t_audit.c — audit/audit.c: end-to-end path-to-report orchestration. */
#include "test.h"
#include "mkelf.h"
#include "elf/elf_const.h"
#include "audit/audit.h"

#include <stdio.h>
#include <string.h>
#include <unistd.h>

static char *tmp_path(char *buf, size_t n, const char *name) {
    snprintf(buf, n, "/tmp/onebin_t_audit_%s_%d", name, (int)getpid());
    return buf;
}

static int has_id(const ob_report *r, const char *id) {
    size_t n = ob_finding_list_count(&r->findings);
    for (size_t i = 0; i < n; i++) {
        if (strcmp(ob_finding_list_at(&r->findings, i)->id, id) == 0) return 1;
    }
    return 0;
}

TEST(audit_hybrid_ok_end_to_end) {
    char path[128];
    tmp_path(path, sizeof(path), "1");
    eg *o = eg_preset_hybrid_ok();
    ASSERT_EQ_INT(eg_write(o, path), 0);

    ob_audit_options opts;
    ob_audit_options_init(&opts);
    opts.file_path = path;

    ob_report r;
    ob_audit_status st = ob_audit_file(&opts, &r);
    ASSERT_EQ_INT(st, OB_AUDIT_OK);
    ASSERT_EQ_STR(r.profile, "hybrid");
    ASSERT_EQ_STR(r.machine, "x86_64");
    ASSERT_EQ_STR(r.type, "ET_DYN");
    ASSERT_EQ_INT(r.klass, 64);
    ASSERT_TRUE(r.nneeded >= 2);
    ASSERT_NOT_NULL(r.interp);

    ob_report_free(&r);
    eg_free(o); unlink(path);
}

TEST(audit_static_ok_no_findings) {
    char path[128];
    tmp_path(path, sizeof(path), "2");
    eg *o = eg_preset_static_ok();
    ASSERT_EQ_INT(eg_write(o, path), 0);

    ob_audit_options opts;
    ob_audit_options_init(&opts);
    opts.file_path = path;

    ob_report r;
    ob_audit_status st = ob_audit_file(&opts, &r);
    ASSERT_EQ_INT(st, OB_AUDIT_OK);
    ASSERT_EQ_STR(r.profile, "static");
    ASSERT_TRUE(r.passed);
    /* Zero findings from c_profile.c specifically (03-TESTPLAN.md §4.3 #1's
     * "false-positive test that matters most") does not mean zero findings
     * from the full pipeline: OB0011 ("fully static", info) is c_needed.c
     * correctly reporting there is nothing to allowlist, and OB0025
     * ("symbol count unknown", info) is c_glibc.c correctly reporting that
     * this minimal fixture has no DT_HASH/DT_GNU_HASH/section headers to
     * derive one from. Both are info severity, so the file still passes. */
    ASSERT_EQ_INT(ob_finding_list_count(&r.findings), 2);
    ASSERT_EQ_INT(r.n_error, 0);
    ASSERT_EQ_INT(r.n_warn, 0);

    ob_report_free(&r);
    eg_free(o); unlink(path);
}

TEST(audit_nonexistent_file_is_fatal_io_open) {
    ob_audit_options opts;
    ob_audit_options_init(&opts);
    opts.file_path = "/tmp/onebin_this_does_not_exist_xyz_audit_test";

    ob_report r;
    ob_audit_status st = ob_audit_file(&opts, &r);
    ASSERT_EQ_INT(st, OB_AUDIT_FATAL);
    ASSERT_TRUE(has_id(&r, "OB0090"));

    ob_report_free(&r);
}

TEST(audit_directory_is_fatal_io_nottype) {
    ob_audit_options opts;
    ob_audit_options_init(&opts);
    opts.file_path = "/tmp";

    ob_report r;
    ob_audit_status st = ob_audit_file(&opts, &r);
    ASSERT_EQ_INT(st, OB_AUDIT_FATAL);
    ASSERT_TRUE(has_id(&r, "OB0091"));

    ob_report_free(&r);
}

TEST(audit_bad_magic_is_fatal_ob0001) {
    char path[128];
    tmp_path(path, sizeof(path), "3");
    FILE *f = fopen(path, "wb");
    ASSERT_NOT_NULL(f);
    fputs("not an elf file at all", f);
    fclose(f);

    ob_audit_options opts;
    ob_audit_options_init(&opts);
    opts.file_path = path;

    ob_report r;
    ob_audit_status st = ob_audit_file(&opts, &r);
    ASSERT_EQ_INT(st, OB_AUDIT_FATAL);
    ASSERT_TRUE(has_id(&r, "OB0001"));

    ob_report_free(&r);
    unlink(path);
}

TEST(audit_et_rel_is_fatal_ob0001) {
    char path[128];
    tmp_path(path, sizeof(path), "4");
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_REL);
    ASSERT_EQ_INT(eg_write(o, path), 0);

    ob_audit_options opts;
    ob_audit_options_init(&opts);
    opts.file_path = path;

    ob_report r;
    ob_audit_status st = ob_audit_file(&opts, &r);
    ASSERT_EQ_INT(st, OB_AUDIT_FATAL);
    ASSERT_TRUE(has_id(&r, "OB0001"));

    ob_report_free(&r);
    eg_free(o); unlink(path);
}

TEST(audit_forced_profile_overrides_autodetect) {
    char path[128];
    tmp_path(path, sizeof(path), "5");
    eg *o = eg_preset_static_ok();
    ASSERT_EQ_INT(eg_write(o, path), 0);

    ob_audit_options opts;
    ob_audit_options_init(&opts);
    opts.file_path = path;
    opts.profile_forced = 1;
    opts.profile = OB_PROFILE_H;

    ob_report r;
    ob_audit_status st = ob_audit_file(&opts, &r);
    ASSERT_EQ_INT(st, OB_AUDIT_OK);
    ASSERT_EQ_STR(r.profile, "hybrid");
    ASSERT_EQ_STR(r.profile_source, "flag");
    ASSERT_TRUE(has_id(&r, "OB0036")); /* forced hybrid, no PT_INTERP */

    ob_report_free(&r);
    eg_free(o); unlink(path);
}

TEST(audit_json_and_text_render_without_crash) {
    char path[128];
    tmp_path(path, sizeof(path), "6");
    eg *o = eg_preset_hybrid_ok();
    ASSERT_EQ_INT(eg_write(o, path), 0);

    ob_audit_options opts;
    ob_audit_options_init(&opts);
    opts.file_path = path;

    ob_report r;
    ASSERT_EQ_INT(ob_audit_file(&opts, &r), OB_AUDIT_OK);

    ob_jbuf j; ob_jbuf_init(&j);
    ob_report_render_json(&r, &j, 0);
    ASSERT_TRUE(j.len > 0);
    ob_jbuf_free(&j);

    ob_jbuf t; ob_jbuf_init(&t);
    ob_report_render_text(&r, &t, 0, 0, 0);
    ASSERT_TRUE(t.len > 0);
    ob_jbuf_free(&t);

    ob_report_free(&r);
    eg_free(o); unlink(path);
}
