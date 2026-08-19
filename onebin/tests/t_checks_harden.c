/* t_checks_harden.c — audit/checks/c_harden.c. 03-TESTPLAN.md §4.5.
 * Cases 13-15 exist solely to catch the Elf32_Phdr.p_flags offset bug
 * (02-REFERENCE-elf.md §10.14) — do not skip them.
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

static void run(loaded *l, ob_profile profile, ob_report *r) {
    ob_check_ctx ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.img = &l->img;
    ctx.dyn = &l->dyn;
    ctx.profile = profile;
    ob_report_init(r);
    ob_check_harden(&ctx, r);
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

TEST(harden_hybrid_ok_clean) {
    eg *o = eg_preset_hybrid_ok();
    loaded l; load(o, &l);
    ob_report r; run(&l, OB_PROFILE_H, &r);

    ASSERT_FALSE(has_id(&r, "OB0050"));
    ASSERT_FALSE(has_id(&r, "OB0051"));
    ASSERT_FALSE(has_id(&r, "OB0052"));
    ASSERT_FALSE(has_id(&r, "OB0053"));
    ASSERT_FALSE(has_id(&r, "OB0054"));
    ASSERT_FALSE(has_id(&r, "OB0055"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* --------------------------------------------------------------------- #2 */

TEST(harden_no_relro_ob0050) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_set_flags(o, 0, DF_1_NOW);
    eg_set_gnu_stack(o, 1, 0);
    loaded l; load(o, &l);
    ob_report r; run(&l, OB_PROFILE_S, &r);

    ASSERT_TRUE(has_id(&r, "OB0050"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* --------------------------------------------------------------------- #3 */

TEST(harden_no_bindnow_ob0051) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_force_dynamic(o, 1);
    eg_set_gnu_relro(o, 1);
    eg_set_gnu_stack(o, 1, 0);
    loaded l; load(o, &l);
    ob_report r; run(&l, OB_PROFILE_S, &r);

    ASSERT_TRUE(has_id(&r, "OB0051"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* ------------------------------------------------------------------ #4,5,6 */

TEST(harden_bindnow_via_dt_bind_now) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_add_dyn(o, DT_BIND_NOW, 0);
    eg_set_gnu_relro(o, 1);
    eg_set_gnu_stack(o, 1, 0);
    loaded l; load(o, &l);
    ob_report r; run(&l, OB_PROFILE_S, &r);

    ASSERT_FALSE(has_id(&r, "OB0051"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

TEST(harden_bindnow_via_df_bind_now) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_set_flags(o, DF_BIND_NOW, 0);
    eg_set_gnu_relro(o, 1);
    eg_set_gnu_stack(o, 1, 0);
    loaded l; load(o, &l);
    ob_report r; run(&l, OB_PROFILE_S, &r);

    ASSERT_FALSE(has_id(&r, "OB0051"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

TEST(harden_bindnow_via_df1_now) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_set_flags(o, 0, DF_1_NOW);
    eg_set_gnu_relro(o, 1);
    eg_set_gnu_stack(o, 1, 0);
    loaded l; load(o, &l);
    ob_report r; run(&l, OB_PROFILE_S, &r);

    ASSERT_FALSE(has_id(&r, "OB0051"));

    ob_report_free(&r); unload(&l); eg_free(o);
}
TEST(harden_bindnow_with_nodelete_does_not_interfere) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    /* DF_1_NODELETE is what -z nodelete emits */
    eg_set_flags(o, 0, DF_1_NOW | DF_1_NODELETE);
    eg_set_gnu_relro(o, 1);
    eg_set_gnu_stack(o, 1, 0);
    loaded l; load(o, &l);
    ob_report r; run(&l, OB_PROFILE_S, &r);

    ASSERT_FALSE(has_id(&r, "OB0051"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* --------------------------------------------------------------------- #7 */

TEST(harden_exec_stack_ob0052) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_set_gnu_relro(o, 1);
    eg_set_flags(o, 0, DF_1_NOW);
    eg_set_gnu_stack(o, 1, PF_R | PF_W | PF_X);
    loaded l; load(o, &l);
    ob_report r; run(&l, OB_PROFILE_S, &r);

    ASSERT_TRUE(has_id(&r, "OB0052"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* --------------------------------------------------------------------- #8 */

TEST(harden_no_stack_segment_warns) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_set_gnu_relro(o, 1);
    eg_set_flags(o, 0, DF_1_NOW);
    /* no eg_set_gnu_stack(): PT_GNU_STACK absent */
    loaded l; load(o, &l);
    ob_report r; run(&l, OB_PROFILE_S, &r);

    ASSERT_TRUE(has_id(&r, "OB0053"));
    ASSERT_FALSE(has_id(&r, "OB0052"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* --------------------------------------------------------------------- #9 */

TEST(harden_et_exec_hybrid_ob0054) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_EXEC);
    eg_set_interp(o, "/lib64/ld-linux-x86-64.so.2");
    eg_set_gnu_relro(o, 1);
    eg_set_flags(o, 0, DF_1_NOW);
    eg_set_gnu_stack(o, 1, 0);
    loaded l; load(o, &l);
    ob_report r; run(&l, OB_PROFILE_H, &r);

    ASSERT_TRUE(has_id(&r, "OB0054"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* -------------------------------------------------------------- #10, #11 */

TEST(harden_dt_textrel_ob0055) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_set_gnu_relro(o, 1);
    eg_set_flags(o, 0, DF_1_NOW);
    eg_set_gnu_stack(o, 1, 0);
    eg_set_textrel(o, 1);
    loaded l; load(o, &l);
    ob_report r; run(&l, OB_PROFILE_S, &r);

    ASSERT_TRUE(has_id(&r, "OB0055"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

TEST(harden_df_textrel_ob0055) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_set_gnu_relro(o, 1);
    eg_set_flags(o, DF_TEXTREL | DF_BIND_NOW, 0);
    eg_set_gnu_stack(o, 1, 0);
    loaded l; load(o, &l);
    ob_report r; run(&l, OB_PROFILE_S, &r);

    ASSERT_TRUE(has_id(&r, "OB0055"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* -------------------------------------------------------------------- #12 */

TEST(harden_no_pt_dynamic_ob0056_no_relro_bindnow) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_EXEC); /* no dynamic content at all */
    loaded l; load(o, &l);
    ASSERT_FALSE(l.dyn.has_dynamic);
    ob_report r; run(&l, OB_PROFILE_S, &r);

    ASSERT_TRUE(has_id(&r, "OB0056"));
    ASSERT_FALSE(has_id(&r, "OB0050"));
    ASSERT_FALSE(has_id(&r, "OB0051"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* -------------------------------------------------------------- #13, #14 */

TEST(harden_elf32_exec_stack_ob0052) {
    eg *o = eg_new(32, EG_LE, EM_386, ET_DYN);
    eg_set_gnu_relro(o, 1);
    eg_set_flags(o, 0, DF_1_NOW);
    eg_set_gnu_stack(o, 1, PF_R | PF_W | PF_X);
    loaded l; load(o, &l);
    ob_report r; run(&l, OB_PROFILE_S, &r);

    ASSERT_TRUE(has_id(&r, "OB0052"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

TEST(harden_elf32_non_exec_stack_no_ob0052) {
    eg *o = eg_new(32, EG_LE, EM_386, ET_DYN);
    eg_set_gnu_relro(o, 1);
    eg_set_flags(o, 0, DF_1_NOW);
    eg_set_gnu_stack(o, 1, PF_R | PF_W);
    loaded l; load(o, &l);
    ob_report r; run(&l, OB_PROFILE_S, &r);

    ASSERT_FALSE(has_id(&r, "OB0052"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* -------------------------------------------------------------------- #15 */

TEST(harden_be_exec_stack_ob0052) {
    eg *o = eg_new(64, EG_BE, EM_X86_64, ET_DYN);
    eg_set_gnu_relro(o, 1);
    eg_set_flags(o, 0, DF_1_NOW);
    eg_set_gnu_stack(o, 1, PF_R | PF_W | PF_X);
    loaded l; load(o, &l);
    ob_report r; run(&l, OB_PROFILE_S, &r);

    ASSERT_TRUE(has_id(&r, "OB0052"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

TEST(harden_elf32_be_exec_stack_ob0052) {
    eg *o = eg_new(32, EG_BE, EM_386, ET_DYN);
    eg_set_gnu_relro(o, 1);
    eg_set_flags(o, 0, DF_1_NOW);
    eg_set_gnu_stack(o, 1, PF_R | PF_W | PF_X);
    loaded l; load(o, &l);
    ob_report r; run(&l, OB_PROFILE_S, &r);

    ASSERT_TRUE(has_id(&r, "OB0052"));

    ob_report_free(&r); unload(&l); eg_free(o);
}
