/* t_checks_rpath.c — audit/checks/c_rpath.c. 03-TESTPLAN.md §4.4. */
#include "test.h"
#include "mkelf.h"
#include "elf/image.h"
#include "elf/dynamic.h"
#include "elf/elf_const.h"
#include "audit/checks.h"

#include <stdio.h>
#include <string.h>

typedef struct {
    ob_image   img;
    ob_dynamic dyn;
    uint8_t   *raw;
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

static void run(loaded *l, ob_report *r) {
    ob_check_ctx ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.img = &l->img;
    ctx.dyn = &l->dyn;
    ob_report_init(r);
    ob_check_rpath(&ctx, r);
    ob_report_finalize(r, NULL, 0);
}

static int has_id(const ob_report *r, const char *id) {
    size_t n = ob_finding_list_count(&r->findings);
    for (size_t i = 0; i < n; i++) {
        if (strcmp(ob_finding_list_at(&r->findings, i)->id, id) == 0) return 1;
    }
    return 0;
}
static int count_id(const ob_report *r, const char *id) {
    int c = 0;
    size_t n = ob_finding_list_count(&r->findings);
    for (size_t i = 0; i < n; i++) {
        if (strcmp(ob_finding_list_at(&r->findings, i)->id, id) == 0) c++;
    }
    return c;
}

/* ----------------------------------------------------------------- #1 */

TEST(rpath_none_no_findings) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    loaded l; load(o, &l);
    ob_report r; run(&l, &r);

    ASSERT_EQ_INT(ob_finding_list_count(&r.findings), 0);

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* ----------------------------------------------------------------- #2 */

TEST(rpath_origin_dollar_form_warns) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_set_runpath(o, "$ORIGIN/../lib");
    loaded l; load(o, &l);
    ob_report r; run(&l, &r);

    ASSERT_TRUE(has_id(&r, "OB0041"));
    ASSERT_FALSE(has_id(&r, "OB0040"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* ----------------------------------------------------------------- #3 */

TEST(rpath_origin_brace_form_warns) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_set_runpath(o, "${ORIGIN}/lib");
    loaded l; load(o, &l);
    ob_report r; run(&l, &r);

    ASSERT_TRUE(has_id(&r, "OB0041"));
    ASSERT_FALSE(has_id(&r, "OB0040"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* ----------------------------------------------------------------- #4 */

TEST(rpath_absolute_path_errors) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_set_runpath(o, "/opt/app/lib");
    loaded l; load(o, &l);
    ob_report r; run(&l, &r);

    ASSERT_TRUE(has_id(&r, "OB0040"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* ----------------------------------------------------------------- #5 */

TEST(rpath_mixed_components_both_findings) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_set_runpath(o, "$ORIGIN/lib:/opt/x");
    loaded l; load(o, &l);
    ob_report r; run(&l, &r);

    ASSERT_TRUE(has_id(&r, "OB0041"));
    ASSERT_TRUE(has_id(&r, "OB0040"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* ----------------------------------------------------------------- #6 */

TEST(rpath_only_dt_rpath_warns_ob0042) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_set_rpath(o, "$ORIGIN/lib");
    loaded l; load(o, &l);
    ob_report r; run(&l, &r);

    ASSERT_TRUE(has_id(&r, "OB0042"));
    ASSERT_TRUE(has_id(&r, "OB0041"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* ----------------------------------------------------------------- #7 */

TEST(rpath_both_rpath_and_runpath_checked) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_set_rpath(o, "$ORIGIN/old");
    eg_set_runpath(o, "$ORIGIN/new");
    loaded l; load(o, &l);
    ob_report r; run(&l, &r);

    ASSERT_TRUE(has_id(&r, "OB0042"));
    ASSERT_EQ_INT(count_id(&r, "OB0041"), 2);

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* ----------------------------------------------------------------- #8 */

TEST(rpath_empty_string_errors) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_set_runpath(o, "");
    loaded l; load(o, &l);
    ob_report r; run(&l, &r);

    ASSERT_TRUE(has_id(&r, "OB0043"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* ----------------------------------------------------------------- #9 */

TEST(rpath_double_colon_errors) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_set_runpath(o, "a::b");
    loaded l; load(o, &l);
    ob_report r; run(&l, &r);

    ASSERT_TRUE(has_id(&r, "OB0043"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* ---------------------------------------------------------------- #10 */

TEST(rpath_leading_colon_both_findings) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_set_runpath(o, ":$ORIGIN");
    loaded l; load(o, &l);
    ob_report r; run(&l, &r);

    ASSERT_TRUE(has_id(&r, "OB0043"));
    ASSERT_TRUE(has_id(&r, "OB0041"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* ---------------------------------------------------------------- #11 */

TEST(rpath_500_components_bounded) {
    char buf[4090];
    size_t off = 0;
    for (int i = 0; i < 500 && off + 10 < sizeof(buf); i++) {
        int n = snprintf(buf + off, sizeof(buf) - off, "%s/p%d", i ? ":" : "", i);
        off += (size_t)n;
    }
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_set_runpath(o, buf);
    loaded l; load(o, &l);
    ob_report r; run(&l, &r);

    ASSERT_TRUE(ob_finding_list_count(&r.findings) > 0);

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* ---------------------------------------------------------------- #12 */

TEST(rpath_originall_is_not_origin_prefix) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_set_runpath(o, "$ORIGINAL/lib");
    loaded l; load(o, &l);
    ob_report r; run(&l, &r);

    ASSERT_TRUE(has_id(&r, "OB0040"));
    ASSERT_FALSE(has_id(&r, "OB0041"));

    ob_report_free(&r); unload(&l); eg_free(o);
}
