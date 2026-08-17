/* t_checks_needed.c — audit/checks/c_needed.c.  03-TESTPLAN.md §4.1. */
#include "test.h"
#include "mkelf.h"
#include "elf/image.h"
#include "elf/dynamic.h"
#include "audit/checks.h"

#include <string.h>

typedef struct {
    ob_image   img;
    ob_dynamic dyn;
    uint8_t   *raw; /* kept alive: ob_image aliases it, never copies it */
} loaded;

static void load(eg *o, loaded *l) {
    size_t len;
    l->raw = eg_emit(o, &len);
    ASSERT_EQ_INT(ob_image_load(l->raw, len, &l->img), OB_IMG_OK);
    ASSERT_EQ_INT(ob_dynamic_load(&l->img, &l->dyn), 0);
}
static void unload(loaded *l) {
    ob_dynamic_free(&l->dyn);
    ob_image_free(&l->img);
    free(l->raw);
}

static int has_id(const ob_report *r, const char *id) {
    size_t n = ob_finding_list_count(&r->findings);
    for (size_t i = 0; i < n; i++) {
        if (strcmp(ob_finding_list_at(&r->findings, i)->id, id) == 0) return 1;
    }
    return 0;
}

/* -------------------------------------------------------------------- #1 */

TEST(needed_hybrid_ok_no_bad_findings) {
    eg *o = eg_preset_hybrid_ok();
    loaded l; load(o, &l);

    ob_check_ctx ctx; memset(&ctx, 0, sizeof(ctx));
    ctx.img = &l.img; ctx.dyn = &l.dyn;
    ob_report r; ob_report_init(&r);
    ob_check_needed(&ctx, &r);

    ASSERT_FALSE(has_id(&r, "OB0010"));
    ASSERT_FALSE(has_id(&r, "OB0013"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* -------------------------------------------------------------------- #2 */

TEST(needed_unlisted_soname_is_error) {
    eg *o = eg_preset_hybrid_ok();
    eg_add_needed(o, "libfoo.so.1");
    loaded l; load(o, &l);

    ob_check_ctx ctx; memset(&ctx, 0, sizeof(ctx));
    ctx.img = &l.img; ctx.dyn = &l.dyn;
    ob_report r; ob_report_init(&r);
    ob_check_needed(&ctx, &r);
    ob_report_finalize(&r, NULL, 0);

    int found = 0;
    size_t n = ob_finding_list_count(&r.findings);
    for (size_t i = 0; i < n; i++) {
        const ob_finding *f = ob_finding_list_at(&r.findings, i);
        if (strcmp(f->id, "OB0010") == 0 && strcmp(f->subject, "libfoo.so.1") == 0) {
            found = 1;
            ASSERT_EQ_INT(f->severity, OB_SEV_ERROR);
        }
    }
    ASSERT_TRUE(found);

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* -------------------------------------------------------------------- #3 */

TEST(needed_libstdcxx_is_ob0013_not_ob0010) {
    eg *o = eg_preset_hybrid_ok();
    eg_add_needed(o, "libstdc++.so.6");
    loaded l; load(o, &l);

    ob_check_ctx ctx; memset(&ctx, 0, sizeof(ctx));
    ctx.img = &l.img; ctx.dyn = &l.dyn;
    ob_report r; ob_report_init(&r);
    ob_check_needed(&ctx, &r);
    ob_report_finalize(&r, NULL, 0);

    int has_13 = 0, has_10_for_it = 0;
    size_t n = ob_finding_list_count(&r.findings);
    for (size_t i = 0; i < n; i++) {
        const ob_finding *f = ob_finding_list_at(&r.findings, i);
        if (strcmp(f->id, "OB0013") == 0) { has_13 = 1; ASSERT_EQ_INT(f->severity, OB_SEV_ERROR); }
        if (strcmp(f->id, "OB0010") == 0 && strcmp(f->subject, "libstdc++.so.6") == 0) has_10_for_it = 1;
    }
    ASSERT_TRUE(has_13);
    ASSERT_FALSE(has_10_for_it);

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* -------------------------------------------------------------------- #4 */

TEST(needed_libgcc_s_is_ob0012_warn_not_ob0010) {
    eg *o = eg_preset_hybrid_ok();
    eg_add_needed(o, "libgcc_s.so.1");
    loaded l; load(o, &l);

    ob_check_ctx ctx; memset(&ctx, 0, sizeof(ctx));
    ctx.img = &l.img; ctx.dyn = &l.dyn;
    ob_report r; ob_report_init(&r);
    ob_check_needed(&ctx, &r);
    ob_report_finalize(&r, NULL, 0);

    int has_12 = 0, has_10_for_it = 0;
    size_t n = ob_finding_list_count(&r.findings);
    for (size_t i = 0; i < n; i++) {
        const ob_finding *f = ob_finding_list_at(&r.findings, i);
        if (strcmp(f->id, "OB0012") == 0) { has_12 = 1; ASSERT_EQ_INT(f->severity, OB_SEV_WARN); }
        if (strcmp(f->id, "OB0010") == 0 && strcmp(f->subject, "libgcc_s.so.1") == 0) has_10_for_it = 1;
    }
    ASSERT_TRUE(has_12);
    ASSERT_FALSE(has_10_for_it);

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* -------------------------------------------------------------------- #5 */

TEST(needed_allow_flag_suppresses_finding) {
    eg *o = eg_preset_hybrid_ok();
    eg_add_needed(o, "libfoo.so.1");
    loaded l; load(o, &l);

    const char *allow[] = { "libfoo.so.1" };
    ob_check_ctx ctx; memset(&ctx, 0, sizeof(ctx));
    ctx.img = &l.img; ctx.dyn = &l.dyn;
    ctx.allow = allow; ctx.nallow = 1;
    ob_report r; ob_report_init(&r);
    ob_check_needed(&ctx, &r);
    ob_report_finalize(&r, NULL, 0);

    size_t n = ob_finding_list_count(&r.findings);
    for (size_t i = 0; i < n; i++) {
        ASSERT_FALSE(strcmp(ob_finding_list_at(&r.findings, i)->subject, "libfoo.so.1") == 0);
    }

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* -------------------------------------------------------------------- #6 */

TEST(needed_static_ok_is_ob0011_info) {
    eg *o = eg_preset_static_ok();
    loaded l; load(o, &l);

    ob_check_ctx ctx; memset(&ctx, 0, sizeof(ctx));
    ctx.img = &l.img; ctx.dyn = &l.dyn;
    ob_report r; ob_report_init(&r);
    ob_check_needed(&ctx, &r);
    ob_report_finalize(&r, NULL, 0);

    int found = 0;
    size_t n = ob_finding_list_count(&r.findings);
    for (size_t i = 0; i < n; i++) {
        const ob_finding *f = ob_finding_list_at(&r.findings, i);
        if (strcmp(f->id, "OB0011") == 0) { found = 1; ASSERT_EQ_INT(f->severity, OB_SEV_INFO); }
    }
    ASSERT_TRUE(found);

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* -------------------------------------------------------------------- #7 */

TEST(needed_duplicate_soname_reports_once) {
    eg *o = eg_preset_hybrid_ok(); /* has libc.so.6 already */
    eg_add_needed(o, "libc.so.6"); /* duplicate */
    loaded l; load(o, &l);

    ob_check_ctx ctx; memset(&ctx, 0, sizeof(ctx));
    ctx.img = &l.img; ctx.dyn = &l.dyn;
    ob_report r; ob_report_init(&r);
    ob_check_needed(&ctx, &r); /* libc.so.6 is allowed, expect no findings for it */
    ob_report_finalize(&r, NULL, 0);

    size_t n = ob_finding_list_count(&r.findings);
    for (size_t i = 0; i < n; i++) {
        ASSERT_FALSE(strcmp(ob_finding_list_at(&r.findings, i)->subject, "libc.so.6") == 0);
    }

    ob_report_free(&r); unload(&l); eg_free(o);
}

TEST(needed_duplicate_bad_soname_reports_once_with_count) {
    eg *o = eg_preset_hybrid_ok();
    eg_add_needed(o, "libfoo.so.1");
    eg_add_needed(o, "libfoo.so.1");
    loaded l; load(o, &l);

    ob_check_ctx ctx; memset(&ctx, 0, sizeof(ctx));
    ctx.img = &l.img; ctx.dyn = &l.dyn;
    ob_report r; ob_report_init(&r);
    ob_check_needed(&ctx, &r);
    ob_report_finalize(&r, NULL, 0);

    int count_for_libfoo = 0;
    size_t n = ob_finding_list_count(&r.findings);
    for (size_t i = 0; i < n; i++) {
        const ob_finding *f = ob_finding_list_at(&r.findings, i);
        if (strcmp(f->id, "OB0010") == 0 && strcmp(f->subject, "libfoo.so.1") == 0) {
            count_for_libfoo++;
            ASSERT_TRUE(strstr(f->message, "2") != NULL);
        }
    }
    ASSERT_EQ_INT(count_for_libfoo, 1);

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* ------------------------------------------------------------------- #12 */

TEST(needed_matching_is_case_sensitive) {
    eg *o = eg_preset_hybrid_ok();
    eg_add_needed(o, "LIBC.SO.6");
    loaded l; load(o, &l);

    ob_check_ctx ctx; memset(&ctx, 0, sizeof(ctx));
    ctx.img = &l.img; ctx.dyn = &l.dyn;
    ob_report r; ob_report_init(&r);
    ob_check_needed(&ctx, &r);
    ob_report_finalize(&r, NULL, 0);

    int found = 0;
    size_t n = ob_finding_list_count(&r.findings);
    for (size_t i = 0; i < n; i++) {
        const ob_finding *f = ob_finding_list_at(&r.findings, i);
        if (strcmp(f->id, "OB0010") == 0 && strcmp(f->subject, "LIBC.SO.6") == 0) found = 1;
    }
    ASSERT_TRUE(found);

    ob_report_free(&r); unload(&l); eg_free(o);
}
