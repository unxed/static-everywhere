/* t_verneed.c — elf/verneed.c.  03-TESTPLAN.md §5.6 items 12-24,
 * 00-AGENT-TASK.md Task 6.  02-REFERENCE-elf.md §7 is the algorithm this
 * tests against; read it before changing anything here.
 */
#include "test.h"
#include "mkelf.h"
#include "elf/image.h"
#include "elf/dynamic.h"
#include "elf/verneed.h"
#include "elf/elf_const.h"
#include "util/limits.h"

/* One Verneed (libc.so.6) with two Vernaux entries. Needs a symbol table
 * too — DT_VERSYM's array is sized off it — so eg_add_dynsym is required
 * even though these tests don't read .gnu.version itself. */
static eg *make_verneed_fixture(void) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_add_needed(o, "libc.so.6");
    static const char *const v[] = { "GLIBC_2.2.5", "GLIBC_2.28" };
    eg_add_verneed(o, "libc.so.6", v, 2);
    eg_add_dynsym(o, "printf", 2, ELF_ST_INFO(STB_GLOBAL, STT_FUNC), SHN_UNDEF);
    eg_set_hash_style(o, 0, 1);
    return o;
}

static void load3(const uint8_t *raw, size_t len, ob_image *img,
                   ob_dynamic *dyn, ob_verneed *vn) {
    ASSERT_EQ_INT(ob_image_load(raw, len, img), OB_IMG_OK);
    ASSERT_EQ_INT(ob_dynamic_load(img, dyn), 0);
    ASSERT_EQ_INT(ob_verneed_load(img, dyn, vn), 0);
}

/* ----------------------------------------------------------------- item 12 */

TEST(verneed_dt_verneed_unmapped) {
    eg *o = make_verneed_fixture();
    size_t len;
    uint8_t *raw = eg_emit(o, &len);

    ob_image img;
    ASSERT_EQ_INT(ob_image_load(raw, len, &img), OB_IMG_OK);
    ob_dynamic dyn;
    ASSERT_EQ_INT(ob_dynamic_load(&img, &dyn), 0);
    ASSERT_TRUE(dyn.has_verneed);
    dyn.verneed_vaddr = 0xFFFFFFFFFFFF0000ull; /* now unmapped */

    ob_verneed vn;
    ASSERT_EQ_INT(ob_verneed_load(&img, &dyn, &vn), 0);
    ASSERT_TRUE(vn.truncated);
    ASSERT_EQ_U64(vn.nreqs, 0);

    ob_verneed_free(&vn); ob_dynamic_free(&dyn); ob_image_free(&img);
    free(raw); eg_free(o);
}

/* ----------------------------------------------------------------- item 13 */

TEST(verneed_verneednum_uint32_max_bounded) {
    eg *o = make_verneed_fixture();
    size_t len;
    uint8_t *raw = eg_emit(o, &len);

    ob_image img;
    ASSERT_EQ_INT(ob_image_load(raw, len, &img), OB_IMG_OK);
    ob_dynamic dyn;
    ASSERT_EQ_INT(ob_dynamic_load(&img, &dyn), 0);
    dyn.verneednum = UINT32_MAX; /* the file only has one real Verneed */

    ob_verneed vn;
    ASSERT_EQ_INT(ob_verneed_load(&img, &dyn, &vn), 0);
    /* vn_next == 0 on the one real record ends the walk cleanly long before
     * the (absurd) declared count is reached. */
    ASSERT_EQ_U64(vn.nverneed_seen, 1);
    ASSERT_FALSE(vn.truncated);

    ob_verneed_free(&vn); ob_dynamic_free(&dyn); ob_image_free(&img);
    free(raw); eg_free(o);
}

/* ----------------------------------------------------------------- item 14 */

TEST(verneed_vn_next_zero_with_verneednum_5) {
    /* Only one real Verneed on disk (vn_next == 0), but DT_VERNEEDNUM says
     * there are 5. The walk must stop at the real terminator, not read
     * four more (nonexistent) records. */
    eg *o = make_verneed_fixture();
    size_t len;
    uint8_t *raw = eg_emit(o, &len);

    ob_image img;
    ASSERT_EQ_INT(ob_image_load(raw, len, &img), OB_IMG_OK);
    ob_dynamic dyn;
    ASSERT_EQ_INT(ob_dynamic_load(&img, &dyn), 0);
    dyn.verneednum = 5;

    ob_verneed vn;
    ASSERT_EQ_INT(ob_verneed_load(&img, &dyn, &vn), 0);
    ASSERT_EQ_U64(vn.nverneed_seen, 1);
    ASSERT_EQ_U64(vn.nreqs, 2); /* the two real Vernaux entries */

    ob_verneed_free(&vn); ob_dynamic_free(&dyn); ob_image_free(&img);
    free(raw); eg_free(o);
}

/* ----------------------------------------------------------------- item 15 */

TEST(verneed_vn_next_wraps_past_buffer) {
    eg *o = make_verneed_fixture();
    size_t len;
    uint8_t *raw = eg_emit(o, &len);

    size_t vn_off = eg_off(o, EG_OFF_VERNEED);
    /* vn_next at offset 12 within the Verneed record. */
    eg_poke32(raw, len, vn_off + 12, 0xFFFFFFF0u, 0);

    ob_image img;
    ASSERT_EQ_INT(ob_image_load(raw, len, &img), OB_IMG_OK);
    ob_dynamic dyn;
    ASSERT_EQ_INT(ob_dynamic_load(&img, &dyn), 0);
    /* The file only has one real Verneed; bump the declared count so the
     * walk actually attempts to follow the corrupted vn_next instead of
     * stopping (correctly, but for the wrong reason) at the real count. */
    dyn.verneednum = 3;

    ob_verneed vn;
    ASSERT_EQ_INT(ob_verneed_load(&img, &dyn, &vn), 0);
    ASSERT_TRUE(vn.truncated);
    ASSERT_EQ_U64(vn.nverneed_seen, 1);

    ob_verneed_free(&vn); ob_dynamic_free(&dyn); ob_image_free(&img);
    free(raw); eg_free(o);
}

/* ----------------------------------------------------------------- item 16 */

TEST(verneed_vn_next_points_backwards) {
    eg *o = make_verneed_fixture();
    size_t len;
    uint8_t *raw = eg_emit(o, &len);

    size_t vn_off = eg_off(o, EG_OFF_VERNEED);
    /* A vn_next that points squarely at an earlier, already-visited offset
     * (the start of the ELF header) rather than forward. */
    eg_poke32(raw, len, vn_off + 12, (uint32_t)(0u - (uint32_t)vn_off), 0);

    ob_image img;
    ASSERT_EQ_INT(ob_image_load(raw, len, &img), OB_IMG_OK);
    ob_dynamic dyn;
    ASSERT_EQ_INT(ob_dynamic_load(&img, &dyn), 0);
    dyn.verneednum = 3;

    ob_verneed vn;
    ASSERT_EQ_INT(ob_verneed_load(&img, &dyn, &vn), 0);
    ASSERT_TRUE(vn.truncated);

    ob_verneed_free(&vn); ob_dynamic_free(&dyn); ob_image_free(&img);
    free(raw); eg_free(o);
}

/* ----------------------------------------------------------------- item 17 */

TEST(verneed_vna_next_zero_with_vn_cnt_100) {
    eg *o = make_verneed_fixture(); /* real vn_cnt is 2 */
    size_t len;
    uint8_t *raw = eg_emit(o, &len);

    size_t vn_off = eg_off(o, EG_OFF_VERNEED);
    eg_poke16(raw, len, vn_off + 2, 100, 0); /* vn_cnt, real count is 2 */
    /* The second (real, last) Vernaux's vna_next is 0 because mkelf already
     * terminates the real chain there — the walk must stop at the two real
     * entries, not read 98 more past the end of the file. */

    ob_image img; ob_dynamic dyn; ob_verneed vn;
    load3(raw, len, &img, &dyn, &vn);
    ASSERT_EQ_U64(vn.nreqs, 2);

    ob_verneed_free(&vn); ob_dynamic_free(&dyn); ob_image_free(&img);
    free(raw); eg_free(o);
}

/* ----------------------------------------------------------------- item 18 */

TEST(verneed_vna_next_self_loop) {
    eg *o = make_verneed_fixture();
    size_t len;
    uint8_t *raw = eg_emit(o, &len);

    size_t vn_off = eg_off(o, EG_OFF_VERNEED);
    size_t vna0_off = vn_off + VERNEED_SIZE; /* first Vernaux */
    eg_poke32(raw, len, vna0_off + 12, 0, 0); /* vna_next == 0, but bump vn_cnt so the walk would try to continue */
    eg_poke16(raw, len, vn_off + 2, 5, 0);
    /* Now make it a genuine self-loop: vna_next such that aux + vna_next ==
     * aux again is only possible with 0, which the algorithm treats as
     * "last" rather than a cycle — so instead point it at itself via a
     * nonzero delta that wraps back exactly. Simplify: 0 already proves
     * termination (previous test); here exercise vn_cnt continuing past a
     * true 0 by re-pointing vna_next to a huge wrapping value instead. */
    eg_poke32(raw, len, vna0_off + 12, 0xFFFFFFFFu - (uint32_t)vna0_off + 1u, 0);

    ob_image img; ob_dynamic dyn; ob_verneed vn;
    load3(raw, len, &img, &dyn, &vn);
    ASSERT_TRUE(vn.truncated);

    ob_verneed_free(&vn); ob_dynamic_free(&dyn); ob_image_free(&img);
    free(raw); eg_free(o);
}

/* ----------------------------------------------------------------- item 19 */

TEST(verneed_vn_cnt_0xffff) {
    eg *o = make_verneed_fixture();
    size_t len;
    uint8_t *raw = eg_emit(o, &len);

    size_t vn_off = eg_off(o, EG_OFF_VERNEED);
    eg_poke16(raw, len, vn_off + 2, 0xFFFF, 0);
    /* The real chain still terminates after 2 Vernaux via vna_next == 0 on
     * the second one, so the walk must stop there, not hang trying to read
     * 65535 of them. */

    ob_image img; ob_dynamic dyn; ob_verneed vn;
    load3(raw, len, &img, &dyn, &vn);
    ASSERT_EQ_U64(vn.nreqs, 2);
    ASSERT_FALSE(vn.truncated);

    ob_verneed_free(&vn); ob_dynamic_free(&dyn); ob_image_free(&img);
    free(raw); eg_free(o);
}

/* ----------------------------------------------------------------- item 20 */

TEST(verneed_vn_aux_zero_points_at_self) {
    eg *o = make_verneed_fixture();
    size_t len;
    uint8_t *raw = eg_emit(o, &len);

    size_t vn_off = eg_off(o, EG_OFF_VERNEED);
    eg_poke32(raw, len, vn_off + 8, 0, 0); /* vn_aux == 0 */
    eg_poke16(raw, len, vn_off + 2, 1, 0); /* vn_cnt = 1, so only one (bogus) read */

    ob_image img; ob_dynamic dyn; ob_verneed vn;
    load3(raw, len, &img, &dyn, &vn);
    /* Must not crash. vna_hash lands on vn_version/vn_cnt's bytes — garbage,
     * not a fault. The walk either records one bogus requirement or gives up
     * cleanly; either is acceptable, a crash or hang is not. */
    (void)vn;

    ob_verneed_free(&vn); ob_dynamic_free(&dyn); ob_image_free(&img);
    free(raw); eg_free(o);
}

/* ----------------------------------------------------------------- item 21 */

TEST(verneed_vn_aux_beyond_eof) {
    eg *o = make_verneed_fixture();
    size_t len;
    uint8_t *raw = eg_emit(o, &len);

    size_t vn_off = eg_off(o, EG_OFF_VERNEED);
    eg_poke32(raw, len, vn_off + 8, 0xFFFFFFF0u, 0); /* vn_aux: wildly beyond EOF */

    ob_image img; ob_dynamic dyn; ob_verneed vn;
    load3(raw, len, &img, &dyn, &vn);
    ASSERT_TRUE(vn.truncated);
    ASSERT_EQ_U64(vn.nreqs, 0);

    ob_verneed_free(&vn); ob_dynamic_free(&dyn); ob_image_free(&img);
    free(raw); eg_free(o);
}

/* ------------------------------------------------------------- items 22, 23 */

TEST(verneed_file_and_version_name_out_of_range) {
    eg *o = make_verneed_fixture();
    size_t len;
    uint8_t *raw = eg_emit(o, &len);

    size_t vn_off = eg_off(o, EG_OFF_VERNEED);
    eg_poke32(raw, len, vn_off + 4, 0xFFFFFF00u, 0); /* vn_file: garbage stroff */
    size_t vna0_off = vn_off + VERNEED_SIZE;
    eg_poke32(raw, len, vna0_off + 8, 0xFFFFFF00u, 0); /* vna_name: garbage stroff */

    ob_image img; ob_dynamic dyn; ob_verneed vn;
    load3(raw, len, &img, &dyn, &vn);
    /* The walk itself only records offsets, never dereferences them — so it
     * must succeed exactly as normal; resolving the (bogus) offsets is
     * ob_dynamic_string's job and is exercised separately. */
    ASSERT_EQ_U64(vn.nreqs, 2);

    char out[64];
    ASSERT_EQ_INT(ob_dynamic_string(&img, &dyn, vn.reqs[0].vn_file_stroff, out, sizeof(out)),
                  OB_STR_OUT_OF_RANGE);
    ASSERT_EQ_INT(ob_dynamic_string(&img, &dyn, vn.reqs[0].vna_name_stroff, out, sizeof(out)),
                  OB_STR_OUT_OF_RANGE);

    ob_verneed_free(&vn); ob_dynamic_free(&dyn); ob_image_free(&img);
    free(raw); eg_free(o);
}

/* ----------------------------------------------------------------- item 24 */

TEST(verneed_vn_version_values) {
    uint16_t values[] = { 0, 2, 0xFFFF };
    for (size_t i = 0; i < 3; i++) {
        eg *o = make_verneed_fixture();
        size_t len;
        uint8_t *raw = eg_emit(o, &len);

        size_t vn_off = eg_off(o, EG_OFF_VERNEED);
        eg_poke16(raw, len, vn_off + 0, values[i], 0);

        ob_image img; ob_dynamic dyn; ob_verneed vn;
        load3(raw, len, &img, &dyn, &vn);
        ASSERT_TRUE(vn.truncated); /* vn_version != 1: stop, per the algorithm */
        ASSERT_EQ_U64(vn.nreqs, 0);

        ob_verneed_free(&vn); ob_dynamic_free(&dyn); ob_image_free(&img);
        free(raw); eg_free(o);
    }
}

/* --------------------------------------------------------------- baseline */

TEST(verneed_hybrid_ok_preset_sanity) {
    eg *o = eg_preset_hybrid_ok();
    size_t len;
    uint8_t *raw = eg_emit(o, &len);

    ob_image img; ob_dynamic dyn; ob_verneed vn;
    load3(raw, len, &img, &dyn, &vn);
    ASSERT_FALSE(vn.truncated);
    ASSERT_EQ_U64(vn.nverneed_seen, 1);
    ASSERT_EQ_U64(vn.nreqs, 2);

    char file[64], ver[64];
    ASSERT_EQ_INT(ob_dynamic_string(&img, &dyn, vn.reqs[0].vn_file_stroff, file, sizeof(file)), OB_STR_OK);
    ASSERT_EQ_STR(file, "libc.so.6");
    ASSERT_EQ_INT(ob_dynamic_string(&img, &dyn, vn.reqs[0].vna_name_stroff, ver, sizeof(ver)), OB_STR_OK);
    ASSERT_EQ_STR(ver, "GLIBC_2.2.5");
    ASSERT_EQ_INT(ob_dynamic_string(&img, &dyn, vn.reqs[1].vna_name_stroff, ver, sizeof(ver)), OB_STR_OK);
    ASSERT_EQ_STR(ver, "GLIBC_2.28");

    ob_verneed_free(&vn); ob_dynamic_free(&dyn); ob_image_free(&img);
    free(raw); eg_free(o);
}
