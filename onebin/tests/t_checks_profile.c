/* t_checks_profile.c — audit/checks/c_profile.c. 03-TESTPLAN.md §4.3.
 * Not every one of the 28 cases yet — the highest-value ones for this
 * chunk; more follow alongside the remaining check families.
 */
#include "test.h"
#include "mkelf.h"
#include "elf/image.h"
#include "elf/dynamic.h"
#include "elf/elf_const.h"
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

static void run(loaded *l, int forced_profile, ob_profile forced_value, ob_report *r) {
    ob_check_ctx ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.img = &l->img;
    ctx.dyn = &l->dyn;
    if (forced_profile) {
        ctx.profile = forced_value;
        ctx.profile_forced = 1;
    }
    ob_checks_resolve_profile(&ctx);
    ob_report_init(r);
    ob_check_profile(&ctx, r);
    ob_report_finalize(r, NULL, 0);
}

static int has_id(const ob_report *r, const char *id) {
    size_t n = ob_finding_list_count(&r->findings);
    for (size_t i = 0; i < n; i++) {
        if (strcmp(ob_finding_list_at(&r->findings, i)->id, id) == 0) return 1;
    }
    return 0;
}

/* --------------------------------------------------------------------- #1 */

TEST(profile_static_ok_no_findings_at_all) {
    eg *o = eg_preset_static_ok();
    loaded l; load(o, &l);
    ob_report r;
    run(&l, 0, OB_PROFILE_S, &r);

    ASSERT_EQ_INT(ob_finding_list_count(&r.findings), 0);

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* --------------------------------------------------------------------- #2 */

TEST(profile_static_nopie_warns_no_pie) {
    eg *o = eg_preset_static_nopie();
    loaded l; load(o, &l);
    ob_report r;
    run(&l, 0, OB_PROFILE_S, &r);

    ASSERT_TRUE(has_id(&r, "OB0032"));
    ASSERT_FALSE(has_id(&r, "OB0050"));
    ASSERT_FALSE(has_id(&r, "OB0051"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* --------------------------------------------------------------------- #3 */

TEST(profile_static_ok_plus_interp_is_error) {
    eg *o = eg_preset_static_ok();
    eg_set_interp(o, "/lib64/ld-linux-x86-64.so.2");
    loaded l; load(o, &l);
    /* now has PT_INTERP: auto-detects as Profile H, not S — force S to
     * exercise the Profile S check path directly, matching the fixture's
     * intent (03-TESTPLAN.md §4.3 #3 forces the scenario the same way). */
    ob_report r;
    run(&l, 1, OB_PROFILE_S, &r);

    ASSERT_TRUE(has_id(&r, "OB0030"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* --------------------------------------------------------------------- #6 */

TEST(profile_forced_hybrid_on_static_ok_is_ob0036) {
    eg *o = eg_preset_static_ok();
    loaded l; load(o, &l);
    ob_report r;
    run(&l, 1, OB_PROFILE_H, &r);

    ASSERT_TRUE(has_id(&r, "OB0036"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* --------------------------------------------------------------------- #13,14 */

TEST(profile_known_interp_no_warning) {
    eg *o = eg_preset_hybrid_ok(); /* already uses the x86_64 ld.so path */
    loaded l; load(o, &l);
    ob_report r;
    run(&l, 0, OB_PROFILE_S, &r);

    ASSERT_FALSE(has_id(&r, "OB0037"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

TEST(profile_unknown_interp_warns) {
    eg *o = eg_preset_hybrid_ok();
    eg_set_interp(o, "/opt/weird/loader");
    loaded l; load(o, &l);
    ob_report r;
    run(&l, 0, OB_PROFILE_S, &r);

    ASSERT_TRUE(has_id(&r, "OB0037"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* --------------------------------------------------------------------- #16 */

TEST(profile_shared_lib_gets_ob0038_no_executable_checks) {
    eg *o = eg_preset_shared_lib();
    loaded l; load(o, &l);
    ob_report r;
    run(&l, 0, OB_PROFILE_S, &r);

    ASSERT_TRUE(has_id(&r, "OB0038"));
    ASSERT_FALSE(has_id(&r, "OB0030"));
    ASSERT_FALSE(has_id(&r, "OB0031"));
    ASSERT_FALSE(has_id(&r, "OB0032"));
    ASSERT_FALSE(has_id(&r, "OB0036"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* --------------------------------------------------------------------- #17 */

TEST(profile_module_preset_autodetects_module_not_hybrid) {
    eg *o = eg_preset_module(); /* ET_DYN, no DT_SONAME, has DT_NEEDED, no PT_INTERP */
    loaded l; load(o, &l);
    ob_report r;
    run(&l, 0, OB_PROFILE_S, &r);

    ASSERT_TRUE(has_id(&r, "OB0038"));
    ASSERT_FALSE(has_id(&r, "OB0036"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* --------------------------------------------------------------------- #21 */

TEST(profile_module_plus_interp_is_not_a_module) {
    eg *o = eg_preset_module();
    eg_set_interp(o, "/lib64/ld-linux-x86-64.so.2");
    loaded l; load(o, &l);
    /* now auto-detects Profile H (rule 1 wins); force M as the fixture asks */
    ob_report r;
    run(&l, 1, OB_PROFILE_M, &r);

    ASSERT_TRUE(has_id(&r, "OB0030"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* --------------------------------------------------------------------- #23 */

TEST(profile_forced_hybrid_on_module_preset_is_ob0036) {
    eg *o = eg_preset_module();
    loaded l; load(o, &l);
    ob_report r;
    run(&l, 1, OB_PROFILE_H, &r);

    ASSERT_TRUE(has_id(&r, "OB0036"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* ------------------------------------------------------------------ #24,25 */

TEST(profile_ambiguous_case_is_ob0039_not_ob0038) {
    /* ET_DYN, no PT_INTERP, no DT_NEEDED, no DT_SONAME, no DF_1_PIE. */
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    loaded l; load(o, &l);
    ob_report r;
    run(&l, 0, OB_PROFILE_S, &r);

    ASSERT_TRUE(has_id(&r, "OB0039"));
    ASSERT_FALSE(has_id(&r, "OB0038"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

TEST(profile_df1_pie_resolves_ambiguity_to_static) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_set_flags(o, 0, DF_1_PIE);
    loaded l; load(o, &l);
    ob_report r;
    run(&l, 0, OB_PROFILE_S, &r);

    ASSERT_FALSE(has_id(&r, "OB0039"));
    ASSERT_FALSE(has_id(&r, "OB0038"));

    ob_report_free(&r); unload(&l); eg_free(o);
}
