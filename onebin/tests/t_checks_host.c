/* t_checks_host.c — audit/checks/c_host.c. 03-TESTPLAN.md §4.7. */
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
    ob_check_host(&ctx, r);
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

static loaded load_with_string(eg *o, const char *s) {
    eg_add_rodata_string(o, s);
    loaded l;
    load(o, &l);
    return l;
}

/* --------------------------------------------------------------------- #1 */

TEST(host_libGL_known) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    loaded l = load_with_string(o, "libGL.so.1");
    ob_report r; run(&l, &r);

    ASSERT_TRUE(has_id(&r, "OB0070"));
    ASSERT_FALSE(has_id(&r, "OB0071"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* --------------------------------------------------------------------- #2 */

TEST(host_libvulkan_known) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    loaded l = load_with_string(o, "libvulkan.so.1");
    ob_report r; run(&l, &r);

    ASSERT_TRUE(has_id(&r, "OB0070"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* --------------------------------------------------------------------- #3 */

TEST(host_libpipewire_known) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    loaded l = load_with_string(o, "libpipewire-0.3.so");
    ob_report r; run(&l, &r);

    ASSERT_TRUE(has_id(&r, "OB0070"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* --------------------------------------------------------------------- #3a
 * far2l-sdl (contrib/far2l/deps.lock's SDL2 entry): SDL_X11_SHARED
 * dlopens libX11 itself rather than linking it, so this is now part of
 * the host contract even though it's windowing, not GPU/audio. */

TEST(host_libX11_known) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    loaded l = load_with_string(o, "libX11.so.6");
    ob_report r; run(&l, &r);

    ASSERT_TRUE(has_id(&r, "OB0070"));
    ASSERT_FALSE(has_id(&r, "OB0071"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* --------------------------------------------------------------------- #3b
 * Same rationale, Wayland side: SDL_WAYLAND_SHARED dlopens this. */

TEST(host_libwayland_client_known) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    loaded l = load_with_string(o, "libwayland-client.so.0");
    ob_report r; run(&l, &r);

    ASSERT_TRUE(has_id(&r, "OB0070"));
    ASSERT_FALSE(has_id(&r, "OB0071"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* --------------------------------------------------------------------- #3c
 * libGLES_CM.so / libGLESv1_CM.so are OpenGL ES 1.x Common Profile names,
 * distinct strings from the already-listed libGLESv2.so -- SDL dlopens
 * this one as its ES1 fallback, so the existing "libGLESv2.so" prefix
 * entry does not already cover it (confirmed: this string does NOT start
 * with "libGLESv2.so"). */

TEST(host_libGLES_CM_known) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    loaded l = load_with_string(o, "libGLES_CM.so.1");
    ob_report r; run(&l, &r);

    ASSERT_TRUE(has_id(&r, "OB0070"));
    ASSERT_FALSE(has_id(&r, "OB0071"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* --------------------------------------------------------------------- #4 */

TEST(host_unlisted_not_needed_warns) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    loaded l = load_with_string(o, "libfoo.so.1");
    ob_report r; run(&l, &r);

    ASSERT_TRUE(has_id(&r, "OB0071"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* --------------------------------------------------------------------- #5 */

TEST(host_allowlisted_no_warn) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    loaded l = load_with_string(o, "libc.so.6");
    ob_report r; run(&l, &r);

    ASSERT_FALSE(has_id(&r, "OB0071"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* --------------------------------------------------------------------- #6 */

TEST(host_actual_needed_no_warn) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_add_needed(o, "libbar.so.2");
    eg_add_rodata_string(o, "libbar.so.2");
    loaded l; load(o, &l);
    ob_report r; run(&l, &r);

    ASSERT_FALSE(has_id(&r, "OB0071"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* --------------------------------------------------------------------- #7 */

TEST(host_no_lib_prefix_no_finding) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    loaded l = load_with_string(o, "notalib.so");
    ob_report r; run(&l, &r);

    ASSERT_FALSE(has_id(&r, "OB0070"));
    ASSERT_FALSE(has_id(&r, "OB0071"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* --------------------------------------------------------------------- #8 */

TEST(host_libGL_no_version_suffix_known) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    loaded l = load_with_string(o, "libGL.so");
    ob_report r; run(&l, &r);

    ASSERT_TRUE(has_id(&r, "OB0070"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* --------------------------------------------------------------------- #9 */

TEST(host_lib_so_needs_name_char) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    loaded l = load_with_string(o, "lib.so");
    ob_report r; run(&l, &r);

    ASSERT_FALSE(has_id(&r, "OB0070"));
    ASSERT_FALSE(has_id(&r, "OB0071"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* -------------------------------------------------------------------- #10 */

TEST(host_multi_numeric_suffix_warns) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    loaded l = load_with_string(o, "libfoo.so.1.2.3");
    ob_report r; run(&l, &r);

    ASSERT_TRUE(has_id(&r, "OB0071"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* -------------------------------------------------------------------- #11 */

TEST(host_nonnumeric_suffix_no_finding) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    loaded l = load_with_string(o, "libfoo.so.x");
    ob_report r; run(&l, &r);

    ASSERT_FALSE(has_id(&r, "OB0070"));
    ASSERT_FALSE(has_id(&r, "OB0071"));

    ob_report_free(&r); unload(&l); eg_free(o);
}

/* -------------------------------------------------------------------- #12 */

TEST(host_100_unknown_capped_at_20) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    for (int i = 0; i < 100; i++) {
        char s[64];
        snprintf(s, sizeof(s), "libunknown%d.so.1", i);
        eg_add_rodata_string(o, s);
    }
    loaded l; load(o, &l);
    ob_report r; run(&l, &r);

    /* 20 per-string findings + 1 "note the total" finding, same ID. */
    ASSERT_EQ_INT(count_id(&r, "OB0071"), 21);

    ob_report_free(&r); unload(&l); eg_free(o);
}
