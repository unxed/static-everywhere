/* t_checks_hygiene.c — audit/checks/c_hygiene.c. 03-TESTPLAN.md §4.6. */
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
    ob_check_hygiene(&ctx, r);
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

/* ------------------------------------------------------------------- #1 */

TEST(hygiene_no_strings_no_findings) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    loaded l; load(o, &l);
    ob_report r; run(&l, &r);

    ASSERT_EQ_INT(ob_finding_list_count(&r.findings), 0);

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* ------------------------------------------------------------------- #2,3 */

TEST(hygiene_home_buildpath_warns) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_add_rodata_string(o, "/home/builder/src/main.c");
    loaded l; load(o, &l);
    ob_report r; run(&l, &r);

    ASSERT_TRUE(has_id(&r, "OB0060"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

TEST(hygiene_users_buildpath_warns) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_add_rodata_string(o, "/Users/bob/proj/x.c");
    loaded l; load(o, &l);
    ob_report r; run(&l, &r);

    ASSERT_TRUE(has_id(&r, "OB0060"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* ------------------------------------------------------------------- #4,5 */

TEST(hygiene_toolchain_path_warns) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_add_rodata_string(o, "/usr/lib/x86_64-linux-gnu/libfoo.so");
    loaded l; load(o, &l);
    ob_report r; run(&l, &r);

    ASSERT_TRUE(has_id(&r, "OB0061"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

TEST(hygiene_nix_store_path_warns) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_add_rodata_string(o, "/nix/store/abc-glibc/lib");
    loaded l; load(o, &l);
    ob_report r; run(&l, &r);

    ASSERT_TRUE(has_id(&r, "OB0061"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* ------------------------------------------------------------------- #6 */

TEST(hygiene_50_buildpaths_capped_at_10) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    for (int i = 0; i < 50; i++) {
        char s[64];
        snprintf(s, sizeof(s), "/home/builder/src/file%d.c", i);
        eg_add_rodata_string(o, s);
    }
    loaded l; load(o, &l);
    ob_report r; run(&l, &r);

    /* 10 per-string findings + 1 "note the total" finding, same ID. */
    ASSERT_EQ_INT(count_id(&r, "OB0060"), 11);

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* ------------------------------------------------------------------- #7 */

TEST(hygiene_homely_prefix_no_finding) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_add_rodata_string(o, "/homely/path/of/some/length");
    loaded l; load(o, &l);
    ob_report r; run(&l, &r);

    ASSERT_FALSE(has_id(&r, "OB0060"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* ------------------------------------------------------------------- #9 */

TEST(hygiene_8mib_no_nul_capped_string) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    size_t n = 8 * 1024 * 1024;
    char *big = malloc(n + 1);
    ASSERT_NOT_NULL(big);
    memset(big, 'A', n);
    big[n] = '\0';
    eg_add_section(o, ".bigblob", SHT_PROGBITS, big, n);
    free(big);
    loaded l; load(o, &l);
    ob_report r; run(&l, &r);
    /* No crash and no allocation proportional to 8 MiB is the point; this
     * string doesn't match any hygiene prefix, so no finding either way. */
    (void)r;

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* ------------------------------------------------------------------ #10,11 */

TEST(hygiene_debug_section_present_ob0062) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    uint8_t data[128] = { 0 };
    eg_add_section(o, ".debug_info", SHT_PROGBITS, data, sizeof(data));
    loaded l; load(o, &l);
    ob_report r; run(&l, &r);

    const ob_finding *f = NULL;
    size_t n = ob_finding_list_count(&r.findings);
    for (size_t i = 0; i < n; i++) {
        const ob_finding *g = ob_finding_list_at(&r.findings, i);
        if (strcmp(g->id, "OB0062") == 0) f = g;
    }
    ASSERT_NOT_NULL(f);
    ASSERT_EQ_INT(f->severity, OB_SEV_INFO);
    ASSERT_TRUE(strstr(f->message, "128") != NULL);

    ob_report_free(&r); unload(&l); eg_free(o);
}

TEST(hygiene_gnu_debuglink_present_ob0063) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    uint8_t data[16] = { 0 };
    eg_add_section(o, ".gnu_debuglink", SHT_PROGBITS, data, sizeof(data));
    loaded l; load(o, &l);
    ob_report r; run(&l, &r);

    ASSERT_TRUE(has_id(&r, "OB0063"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* ------------------------------------------------------------------- #12 */

TEST(hygiene_no_section_headers_no_crash) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    /* eg_set_shdrs never called: no section headers at all */
    loaded l; load(o, &l);
    ob_report r; run(&l, &r);

    ASSERT_FALSE(has_id(&r, "OB0062"));
    ASSERT_FALSE(has_id(&r, "OB0063"));

    ob_report_free(&r); unload(&l); eg_free(o);
}
