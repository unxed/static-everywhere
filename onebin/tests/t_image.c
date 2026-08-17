/* t_image.c — elf/image.c.  03-TESTPLAN.md §5.5, 00-AGENT-TASK.md Task 5.
 *
 * Every numbered comment below corresponds to the matching numbered item in
 * 03-TESTPLAN.md §5.5.  The gate is "clean error, never a crash, never a
 * hang" — which for several of these items (8, 9, 12, 16, 17, 18, 19) means
 * the correct outcome is OB_IMG_OK, because the field in question is either
 * informational (warn-and-continue) or genuinely out of this module's scope
 * (section headers, beyond the one field PN_XNUM needs).  See elf/image.h's
 * top comment for why.
 */
#include "test.h"
#include "mkelf.h"
#include "elf/image.h"
#include "elf/elf_const.h"

/* ------------------------------------------------------------- helpers */

/* A minimal, fully valid image: one main PT_LOAD, ET_DYN, no PT_INTERP, no
 * dynamic section.  Whatever the test needs to be wrong, it starts here and
 * pokes exactly one thing. */
static uint8_t *make_valid(int cls, size_t *len, eg **out_o) {
    eg *o = eg_new(cls, EG_LE, cls == 64 ? EM_X86_64 : EM_386, ET_DYN);
    uint8_t *raw = eg_emit(o, len);
    *out_o = o;
    return raw;
}

static void ehdr_off_phnum(int cls, size_t *off_phnum, size_t *off_phentsize,
                            size_t *off_ehsize, size_t *off_shoff,
                            size_t *off_shentsize, size_t *off_shnum,
                            size_t *off_shstrndx) {
    if (cls == 64) {
        *off_phnum = 56; *off_phentsize = 54; *off_ehsize = 52;
        *off_shoff = 40; *off_shentsize = 58; *off_shnum = 60; *off_shstrndx = 62;
    } else {
        *off_phnum = 44; *off_phentsize = 42; *off_ehsize = 40;
        *off_shoff = 32; *off_shentsize = 46; *off_shnum = 48; *off_shstrndx = 50;
    }
}

/* ----------------------------------------------------------- items 1-3 */

TEST(image_empty_file) {
    /* 1. Empty file. */
    uint8_t dummy = 0;
    ob_image img;
    ASSERT_EQ_INT(ob_image_load(&dummy, 0, &img), OB_IMG_ERR_TOO_SHORT);
}

TEST(image_tiny_files) {
    /* 2. 1, 2, 3 bytes. */
    uint8_t raw[3] = { 0x7F, 'E', 'L' };
    ob_image img;
    for (size_t n = 1; n <= 3; n++) {
        ASSERT_EQ_INT(ob_image_load(raw, n, &img), OB_IMG_ERR_TOO_SHORT);
    }
}

TEST(image_magic_then_eof) {
    /* 3. Correct magic then EOF at 4 bytes. */
    uint8_t raw[4] = { ELFMAG0, ELFMAG1, ELFMAG2, ELFMAG3 };
    ob_image img;
    ASSERT_EQ_INT(ob_image_load(raw, 4, &img), OB_IMG_ERR_TOO_SHORT);
}

/* ----------------------------------------------------------------- item 4 */

TEST(image_truncated_ehdr_boundary) {
    /* 4. Truncated at 15, 16, 51, 52, 63, 64 bytes (both class values).
     * e_phnum is forced to 0 first so the only thing under test is whether
     * the ELF header itself is fully present — not phdr-table coverage. */
    struct { int cls; size_t bad, ok; } cases[] = {
        { 32, 51, 52 },
        { 64, 63, 64 },
    };
    for (size_t c = 0; c < 2; c++) {
        int cls = cases[c].cls;
        size_t len;
        eg *o;
        uint8_t *raw = make_valid(cls, &len, &o);

        size_t off_phnum, off_phentsize, off_ehsize, off_shoff,
               off_shentsize, off_shnum, off_shstrndx;
        ehdr_off_phnum(cls, &off_phnum, &off_phentsize, &off_ehsize,
                       &off_shoff, &off_shentsize, &off_shnum, &off_shstrndx);
        eg_poke16(raw, len, off_phnum, 0, 0); /* nphdrs -> 0 */

        ob_image img;
        ASSERT_EQ_INT(ob_image_load(raw, 15, &img), OB_IMG_ERR_TOO_SHORT);
        ASSERT_EQ_INT(ob_image_load(raw, 16, &img), OB_IMG_ERR_TOO_SHORT);
        ASSERT_EQ_INT(ob_image_load(raw, cases[c].bad, &img), OB_IMG_ERR_TOO_SHORT);
        ASSERT_EQ_INT(ob_image_load(raw, cases[c].ok, &img), OB_IMG_OK);
        ASSERT_EQ_U64(img.nphdrs, 0);
        ob_image_free(&img);

        free(raw);
        eg_free(o);
    }
}

/* ----------------------------------------------------------------- item 5 */

TEST(image_bad_magic) {
    /* 5. Bad magic, one byte wrong, each of the four positions. */
    for (int pos = 0; pos < 4; pos++) {
        size_t len;
        eg *o;
        uint8_t *raw = make_valid(64, &len, &o);
        eg_poke8(raw, len, (size_t)pos, (uint8_t)(raw[pos] ^ 0xFF));

        ob_image img;
        ASSERT_EQ_INT(ob_image_load(raw, len, &img), OB_IMG_ERR_BAD_MAGIC);

        free(raw);
        eg_free(o);
    }
}

/* ----------------------------------------------------------------- item 6 */

TEST(image_bad_class) {
    /* 6. EI_CLASS = 0, 3, 255. */
    uint8_t values[] = { 0, 3, 255 };
    for (size_t i = 0; i < 3; i++) {
        size_t len;
        eg *o;
        uint8_t *raw = make_valid(64, &len, &o);
        eg_poke8(raw, len, EI_CLASS, values[i]);

        ob_image img;
        ASSERT_EQ_INT(ob_image_load(raw, len, &img), OB_IMG_ERR_BAD_CLASS);

        free(raw);
        eg_free(o);
    }
}

/* ----------------------------------------------------------------- item 7 */

TEST(image_bad_data) {
    /* 7. EI_DATA = 0, 3, 255. */
    uint8_t values[] = { 0, 3, 255 };
    for (size_t i = 0; i < 3; i++) {
        size_t len;
        eg *o;
        uint8_t *raw = make_valid(64, &len, &o);
        eg_poke8(raw, len, EI_DATA, values[i]);

        ob_image img;
        ASSERT_EQ_INT(ob_image_load(raw, len, &img), OB_IMG_ERR_BAD_DATA);

        free(raw);
        eg_free(o);
    }
}

/* ----------------------------------------------------------------- item 8 */

TEST(image_ei_version_zero_warns_not_fatal) {
    /* 8. EI_VERSION = 0 -> warn, continues. */
    size_t len;
    eg *o;
    uint8_t *raw = make_valid(64, &len, &o);
    eg_poke8(raw, len, EI_VERSION, 0);

    ob_image img;
    ASSERT_EQ_INT(ob_image_load(raw, len, &img), OB_IMG_OK);
    ASSERT_EQ_INT(img.ei_version_is_current, 0);
    ob_image_free(&img);

    free(raw);
    eg_free(o);
}

/* ----------------------------------------------------------------- item 9 */

TEST(image_unusual_e_type_not_rejected_here) {
    /* 9. e_type = ET_REL, ET_CORE, 0, 65535.  Rejecting ET_REL/ET_CORE is an
     * audit-level decision (OB0001, 01-SPEC-audit.md §12), not this
     * module's.  image.c must load them cleanly and report the raw value. */
    uint16_t values[] = { ET_REL, ET_CORE, 0, 65535 };
    for (size_t i = 0; i < 4; i++) {
        size_t len;
        eg *o;
        uint8_t *raw = make_valid(64, &len, &o);
        eg_poke16(raw, len, 16, values[i], 0);

        ob_image img;
        ASSERT_EQ_INT(ob_image_load(raw, len, &img), OB_IMG_OK);
        ASSERT_EQ_INT(img.e_type, values[i]);
        ob_image_free(&img);

        free(raw);
        eg_free(o);
    }
}

/* ---------------------------------------------------------------- item 10 */

TEST(image_bad_phentsize_64) {
    /* 10. e_phentsize = 0, 1, 55, 57, 65535 on ELF64. */
    uint16_t values[] = { 0, 1, 55, 57, 65535 };
    for (size_t i = 0; i < 5; i++) {
        size_t len;
        eg *o;
        uint8_t *raw = make_valid(64, &len, &o);
        eg_poke16(raw, len, 54, values[i], 0);

        ob_image img;
        ASSERT_EQ_INT(ob_image_load(raw, len, &img), OB_IMG_ERR_BAD_PHENTSIZE);

        free(raw);
        eg_free(o);
    }
}

/* ---------------------------------------------------------------- item 11 */

TEST(image_bad_phentsize_32) {
    /* 11. e_phentsize = 31, 33 on ELF32. */
    uint16_t values[] = { 31, 33 };
    for (size_t i = 0; i < 2; i++) {
        size_t len;
        eg *o;
        uint8_t *raw = make_valid(32, &len, &o);
        eg_poke16(raw, len, 42, values[i], 0);

        ob_image img;
        ASSERT_EQ_INT(ob_image_load(raw, len, &img), OB_IMG_ERR_BAD_PHENTSIZE);

        free(raw);
        eg_free(o);
    }
}

/* ---------------------------------------------------------------- item 12 */

TEST(image_phnum_zero) {
    /* 12. e_phnum = 0. */
    size_t len;
    eg *o;
    uint8_t *raw = make_valid(64, &len, &o);
    eg_poke16(raw, len, 56, 0, 0);

    ob_image img;
    ASSERT_EQ_INT(ob_image_load(raw, len, &img), OB_IMG_OK);
    ASSERT_EQ_U64(img.nphdrs, 0);
    ASSERT_EQ_U64(ob_image_vaddr_to_offset(&img, 0), OB_NOT_MAPPED);
    ob_image_free(&img);

    free(raw);
    eg_free(o);
}

/* ---------------------------------------------------------------- item 13 */

TEST(image_pn_xnum_without_shdrs) {
    /* 13. e_phnum = 0xFFFF with no section headers. */
    size_t len;
    eg *o;
    uint8_t *raw = make_valid(64, &len, &o);
    eg_poke16(raw, len, 56, 0xFFFF, 0);

    ob_image img;
    ASSERT_EQ_INT(ob_image_load(raw, len, &img), OB_IMG_ERR_PN_XNUM_UNSUPPORTED);

    free(raw);
    eg_free(o);
}

/* ---------------------------------------------------------------- item 14 */

TEST(image_phnum_too_large_for_file) {
    /* 14. e_phnum = 1000 in a small file. */
    size_t len;
    eg *o;
    uint8_t *raw = make_valid(64, &len, &o);
    ASSERT_TRUE(len < 1000u * PHDR64_SIZE);
    eg_poke16(raw, len, 56, 1000, 0);

    ob_image img;
    ASSERT_EQ_INT(ob_image_load(raw, len, &img), OB_IMG_ERR_PHDR_RANGE);

    free(raw);
    eg_free(o);
}

/* ---------------------------------------------------------------- item 15 */

TEST(image_phoff_out_of_range) {
    /* 15. e_phoff = file length, = length+1, = UINT64_MAX. */
    {
        size_t len;
        eg *o;
        uint8_t *raw = make_valid(64, &len, &o);
        eg_poke64(raw, len, 32, (uint64_t)len, 0);
        ob_image img;
        ASSERT_EQ_INT(ob_image_load(raw, len, &img), OB_IMG_ERR_PHDR_RANGE);
        free(raw);
        eg_free(o);
    }
    {
        size_t len;
        eg *o;
        uint8_t *raw = make_valid(64, &len, &o);
        eg_poke64(raw, len, 32, (uint64_t)len + 1, 0);
        ob_image img;
        ASSERT_EQ_INT(ob_image_load(raw, len, &img), OB_IMG_ERR_PHDR_RANGE);
        free(raw);
        eg_free(o);
    }
    {
        size_t len;
        eg *o;
        uint8_t *raw = make_valid(64, &len, &o);
        eg_poke64(raw, len, 32, UINT64_MAX, 0);
        ob_image img;
        ASSERT_EQ_INT(ob_image_load(raw, len, &img), OB_IMG_ERR_PHDR_OVERFLOW);
        free(raw);
        eg_free(o);
    }
}

/* ---------------------------------------------------------------- item 16 */

TEST(image_shoff_beyond_eof_does_not_affect_phdrs) {
    /* 16. e_shoff beyond EOF must not affect program-header parsing. */
    size_t len;
    eg *o;
    uint8_t *raw = make_valid(64, &len, &o);
    eg_poke64(raw, len, 40, 0xFFFFFFFFFFFFFFF0ull, 0);

    ob_image img;
    ASSERT_EQ_INT(ob_image_load(raw, len, &img), OB_IMG_OK);
    ASSERT_TRUE(img.nphdrs >= 1);
    ob_image_free(&img);

    free(raw);
    eg_free(o);
}

/* ---------------------------------------------------------------- item 17 */

TEST(image_bad_shentsize_ignored) {
    /* 17. e_shentsize wrong with e_shnum > 0 — out of this module's scope
     * unless e_phnum == PN_XNUM, which it is not here. */
    size_t len;
    eg *o;
    uint8_t *raw = make_valid(64, &len, &o);
    eg_poke16(raw, len, 58, 999, 0);  /* e_shentsize */
    eg_poke16(raw, len, 60, 1, 0);    /* e_shnum */

    ob_image img;
    ASSERT_EQ_INT(ob_image_load(raw, len, &img), OB_IMG_OK);
    ob_image_free(&img);

    free(raw);
    eg_free(o);
}

/* ---------------------------------------------------------------- item 18 */

TEST(image_shstrndx_out_of_range_ignored) {
    /* 18. e_shstrndx >= e_shnum — stored raw, unchecked at this layer. */
    size_t len;
    eg *o;
    uint8_t *raw = make_valid(64, &len, &o);
    eg_poke16(raw, len, 60, 2, 0); /* e_shnum */
    eg_poke16(raw, len, 62, 5, 0); /* e_shstrndx */

    ob_image img;
    ASSERT_EQ_INT(ob_image_load(raw, len, &img), OB_IMG_OK);
    ASSERT_EQ_INT(img.e_shstrndx, 5);
    ob_image_free(&img);

    free(raw);
    eg_free(o);
}

/* ---------------------------------------------------------------- item 19 */

TEST(image_ehsize_zero_is_informational) {
    /* 19. e_ehsize = 0. */
    size_t len;
    eg *o;
    uint8_t *raw = make_valid(64, &len, &o);
    eg_poke16(raw, len, 52, 0, 0);

    ob_image img;
    ASSERT_EQ_INT(ob_image_load(raw, len, &img), OB_IMG_OK);
    ASSERT_EQ_INT(img.e_ehsize_matches_canonical, 0);
    ob_image_free(&img);

    free(raw);
    eg_free(o);
}

/* --------------------------------------------------- vaddr_to_offset (§6.1) */

TEST(image_vaddr_to_offset_basic) {
    size_t len;
    eg *o;
    uint8_t *raw = make_valid(64, &len, &o); /* ET_DYN: BASE = 0 */

    ob_image img;
    ASSERT_EQ_INT(ob_image_load(raw, len, &img), OB_IMG_OK);
    ASSERT_TRUE(img.nphdrs >= 1);

    /* The main PT_LOAD covers the whole file with p_offset == p_vaddr == 0
     * (mkelf.h's contract), so translation is the identity within it. */
    ASSERT_EQ_U64(ob_image_vaddr_to_offset(&img, 0), 0);
    ASSERT_EQ_U64(ob_image_vaddr_to_offset(&img, 8), 8);
    ASSERT_EQ_U64(ob_image_vaddr_to_offset(&img, len), OB_NOT_MAPPED);
    ASSERT_EQ_U64(ob_image_vaddr_to_offset(&img, (uint64_t)len + 1000), OB_NOT_MAPPED);

    ob_image_free(&img);
    free(raw);
    eg_free(o);
}

TEST(image_vaddr_to_offset_worked_example) {
    /* Reproduces 02-REFERENCE-elf.md §9's worked example: e_phoff == 64,
     * e_phnum == 2, phdr[0] is PT_LOAD, PF_R|PF_X, p_filesz == 512, and
     * vaddr_to_offset(0x100) == 0x100 while vaddr_to_offset(0x300) is
     * NOT_MAPPED. */
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_set_entry(o, 0x1000);
    eg_set_load_flags(o, PF_R | PF_X);
    eg_set_pad_to(o, 512);

    size_t len;
    uint8_t *raw = eg_emit(o, &len);

    ob_image img;
    ASSERT_EQ_INT(ob_image_load(raw, len, &img), OB_IMG_OK);
    ASSERT_EQ_U64(img.e_phoff, 64);
    ASSERT_EQ_U64(img.e_entry, 0x1000);
    ASSERT_EQ_INT(img.phdrs[0].p_type, PT_LOAD);
    ASSERT_EQ_INT(img.phdrs[0].p_flags, (int)(PF_R | PF_X));
    ASSERT_EQ_U64(img.phdrs[0].p_filesz, 512);

    ASSERT_EQ_U64(ob_image_vaddr_to_offset(&img, 0x100), 0x100);
    ASSERT_EQ_U64(ob_image_vaddr_to_offset(&img, 0x300), OB_NOT_MAPPED);

    ob_image_free(&img);
    free(raw);
    eg_free(o);
}

/* Guard against the ELF32 p_flags-offset bug the reference doc warns about
 * by name (02-REFERENCE-elf.md §4): read it back and confirm it lands where
 * ELF32 puts it (offset 24 within the phdr), not where ELF64 does. */
TEST(image_elf32_pflags_offset) {
    eg *o = eg_new(32, EG_LE, EM_386, ET_DYN);
    eg_set_load_flags(o, PF_R | PF_W);

    size_t len;
    uint8_t *raw = eg_emit(o, &len);

    ob_image img;
    ASSERT_EQ_INT(ob_image_load(raw, len, &img), OB_IMG_OK);
    ASSERT_TRUE(img.nphdrs >= 1);
    ASSERT_EQ_INT(img.phdrs[0].p_type, PT_LOAD);
    ASSERT_EQ_INT(img.phdrs[0].p_flags, (int)(PF_R | PF_W));

    ob_image_free(&img);
    free(raw);
    eg_free(o);
}
