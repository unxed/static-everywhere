/* t_checks_glibc.c — audit/checks/c_glibc.c. 03-TESTPLAN.md §4.2.
 * Highest-value cases for this chunk; more follow with later chunks.
 */
#include "test.h"
#include "mkelf.h"
#include "elf/image.h"
#include "elf/dynamic.h"
#include "elf/verneed.h"
#include "elf/symbols.h"
#include "elf/elf_const.h"
#include "audit/checks.h"

#include <string.h>

typedef struct {
    ob_image   img;
    ob_dynamic dyn;
    ob_verneed vn;
    ob_symbols syms;
    uint8_t   *raw;
} loaded;

static void load(eg *o, loaded *l) {
    size_t len;
    l->raw = eg_emit(o, &len);
    ASSERT_EQ_INT(ob_image_load(l->raw, len, &l->img), OB_IMG_OK);
    ASSERT_EQ_INT(ob_dynamic_load(&l->img, &l->dyn), 0);
    ASSERT_EQ_INT(ob_verneed_load(&l->img, &l->dyn, &l->vn), 0);
    ASSERT_EQ_INT(ob_symbols_count(&l->img, &l->dyn, &l->syms), 0);
}
static void unload(loaded *l) {
    ob_verneed_free(&l->vn);
    ob_dynamic_free(&l->dyn);
    ob_image_free(&l->img);
    free(l->raw);
}

static void run(loaded *l, const char *glibc_max, ob_report *r) {
    ob_check_ctx ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.img = &l->img;
    ctx.dyn = &l->dyn;
    ctx.verneed = &l->vn;
    ctx.syms = &l->syms;
    ctx.glibc_max = glibc_max;
    ob_report_init(r);
    ob_check_glibc(&ctx, r);
    ob_report_finalize(r, NULL, 0);
}

static int has_id(const ob_report *r, const char *id) {
    size_t n = ob_finding_list_count(&r->findings);
    for (size_t i = 0; i < n; i++) {
        if (strcmp(ob_finding_list_at(&r->findings, i)->id, id) == 0) return 1;
    }
    return 0;
}
static const ob_finding *find_id(const ob_report *r, const char *id) {
    size_t n = ob_finding_list_count(&r->findings);
    for (size_t i = 0; i < n; i++) {
        const ob_finding *f = ob_finding_list_at(&r->findings, i);
        if (strcmp(f->id, id) == 0) return f;
    }
    return NULL;
}

/* --------------------------------------------------------------------- #1 */

TEST(glibc_within_max_passes) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    static const char *const v[] = { "GLIBC_2.2.5", "GLIBC_2.28" };
    eg_add_verneed(o, "libc.so.6", v, 2);
    eg_add_dynsym(o, "printf", 2, ELF_ST_INFO(STB_GLOBAL, STT_FUNC), SHN_UNDEF);
    eg_set_hash_style(o, 0, 1);
    loaded l; load(o, &l);

    ob_report r;
    run(&l, "2.28", &r);
    ASSERT_FALSE(has_id(&r, "OB0020"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* --------------------------------------------------------------------- #2 */

TEST(glibc_exceeds_max_names_both_versions) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    static const char *const v[] = { "GLIBC_2.2.5", "GLIBC_2.28" };
    eg_add_verneed(o, "libc.so.6", v, 2);
    eg_add_dynsym(o, "printf", 2, ELF_ST_INFO(STB_GLOBAL, STT_FUNC), SHN_UNDEF);
    eg_set_hash_style(o, 0, 1);
    loaded l; load(o, &l);

    ob_report r;
    run(&l, "2.17", &r);
    const ob_finding *f = find_id(&r, "OB0020");
    ASSERT_NOT_NULL(f);
    ASSERT_EQ_INT(f->severity, OB_SEV_ERROR);
    ASSERT_TRUE(strstr(f->message, "2.28") != NULL);
    ASSERT_TRUE(strstr(f->message, "2.17") != NULL);

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* --------------------------------------------------------------------- #3 */

TEST(glibc_comparison_is_numeric_not_lexical) {
    /* "2.10" < "2.9" lexically; must not be. */
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    static const char *const v[] = { "GLIBC_2.9", "GLIBC_2.10" };
    eg_add_verneed(o, "libc.so.6", v, 2);
    eg_add_dynsym(o, "printf", 2, ELF_ST_INFO(STB_GLOBAL, STT_FUNC), SHN_UNDEF);
    eg_set_hash_style(o, 0, 1);
    loaded l; load(o, &l);

    ob_report r;
    run(&l, "2.9", &r);
    ASSERT_TRUE(has_id(&r, "OB0020")); /* 2.10 > 2.9 numerically */

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* --------------------------------------------------------------------- #6 */

TEST(glibc_abi_dt_relr_is_warn_and_excluded_from_max) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    static const char *const v[] = { "GLIBC_2.28", "GLIBC_ABI_DT_RELR" };
    eg_add_verneed(o, "libc.so.6", v, 2);
    eg_add_dynsym(o, "printf", 2, ELF_ST_INFO(STB_GLOBAL, STT_FUNC), SHN_UNDEF);
    eg_set_hash_style(o, 0, 1);
    loaded l; load(o, &l);

    ob_report r;
    run(&l, "2.28", &r);
    ASSERT_TRUE(has_id(&r, "OB0022"));
    ASSERT_FALSE(has_id(&r, "OB0020")); /* GLIBC_ABI_DT_RELR must not count towards the max */

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* --------------------------------------------------------------------- #7 */

TEST(glibc_private_is_error) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    static const char *const v[] = { "GLIBC_PRIVATE" };
    eg_add_verneed(o, "libc.so.6", v, 1);
    eg_add_dynsym(o, "__some_internal", 2, ELF_ST_INFO(STB_GLOBAL, STT_FUNC), SHN_UNDEF);
    eg_set_hash_style(o, 0, 1);
    loaded l; load(o, &l);

    ob_report r;
    run(&l, "2.28", &r);
    const ob_finding *f = find_id(&r, "OB0024");
    ASSERT_NOT_NULL(f);
    ASSERT_EQ_INT(f->severity, OB_SEV_ERROR);

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* --------------------------------------------------------------------- #8 */

TEST(glibcxx_is_ob0023_warn) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    static const char *const v[] = { "GLIBCXX_3.4.29" };
    eg_add_verneed(o, "libstdc++.so.6", v, 1);
    eg_add_dynsym(o, "_Znwm", 2, ELF_ST_INFO(STB_GLOBAL, STT_FUNC), SHN_UNDEF);
    eg_set_hash_style(o, 0, 1);
    loaded l; load(o, &l);

    ob_report r;
    run(&l, "2.28", &r);
    const ob_finding *f = find_id(&r, "OB0023");
    ASSERT_NOT_NULL(f);
    ASSERT_EQ_INT(f->severity, OB_SEV_WARN);
    ASSERT_EQ_STR(f->subject, "GLIBCXX_3.4.29");

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* -------------------------------------------------------------------- #10 */

TEST(glibc_no_verneed_at_all_no_finding) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    loaded l; load(o, &l);

    ob_report r;
    run(&l, "2.28", &r);
    ASSERT_FALSE(has_id(&r, "OB0020"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* -------------------------------------------------------------------- #16 */

TEST(glibc_offending_symbol_named_correctly) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    static const char *const v[] = { "GLIBC_2.2.5", "GLIBC_2.28" };
    eg_add_verneed(o, "libc.so.6", v, 2); /* vna_other: 2.2.5=2, 2.28=3 */
    eg_add_dynsym(o, "old_func", 2, ELF_ST_INFO(STB_GLOBAL, STT_FUNC), SHN_UNDEF);
    eg_add_dynsym(o, "new_func", 3, ELF_ST_INFO(STB_GLOBAL, STT_FUNC), SHN_UNDEF);
    eg_set_hash_style(o, 1, 0);
    loaded l; load(o, &l);
    ASSERT_TRUE(l.syms.count_known);

    ob_report r;
    run(&l, "2.17", &r);
    const ob_finding *f = find_id(&r, "OB0021");
    ASSERT_NOT_NULL(f);
    ASSERT_EQ_STR(f->subject, "new_func@GLIBC_2.28");

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* -------------------------------------------------------------------- #17 */

TEST(glibc_symcount_unknown_ob0025_but_max_still_correct) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    static const char *const v[] = { "GLIBC_2.28" };
    eg_add_verneed(o, "libc.so.6", v, 1);
    eg_add_dynsym(o, "printf", 2, ELF_ST_INFO(STB_GLOBAL, STT_FUNC), SHN_UNDEF);
    /* deliberately no eg_set_hash_style(): no DT_HASH, no DT_GNU_HASH, no
     * section headers -> symbol count cannot be determined */
    loaded l; load(o, &l);
    ASSERT_FALSE(l.syms.count_known);

    ob_report r;
    run(&l, "2.17", &r);
    ASSERT_TRUE(has_id(&r, "OB0025"));
    ASSERT_TRUE(has_id(&r, "OB0020")); /* still correct: doesn't need symbol count */

    ob_report_free(&r); unload(&l); eg_free(o);
}
