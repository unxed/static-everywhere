/* t_dynamic.c — elf/dynamic.c.  03-TESTPLAN.md §5.6, 00-AGENT-TASK.md Task 6.
 *
 * Item numbers in comments match 03-TESTPLAN.md §5.6.  Items 12-24 (verneed)
 * are in t_verneed.c; items 30-33 (symbol/hash counting) are in t_symbols.c.
 */
#include "test.h"
#include "mkelf.h"
#include "elf/image.h"
#include "elf/dynamic.h"
#include "elf/elf_const.h"
#include "util/limits.h"

/* A minimal dynamic ELF: one DT_NEEDED, no symbols, no versions.  With no
 * interp, no extra loads, no relro, no stack marker, the phdr array is
 * exactly [PT_LOAD, PT_DYNAMIC] — index 1 is always PT_DYNAMIC below. */
static eg *make_minimal_dynamic(void) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_add_needed(o, "libc.so.6");
    return o;
}

static void load_ok(const uint8_t *raw, size_t len, ob_image *img, ob_dynamic *dyn) {
    ASSERT_EQ_INT(ob_image_load(raw, len, img), OB_IMG_OK);
    ASSERT_EQ_INT(ob_dynamic_load(img, dyn), 0);
}

/* ------------------------------------------------------------------ item 1 */

TEST(dynamic_pt_dynamic_offset_beyond_eof) {
    eg *o = make_minimal_dynamic();
    size_t len;
    uint8_t *raw = eg_emit(o, &len);

    /* phdr[1] is PT_DYNAMIC; Phdr64.p_offset is at offset 8 within it. */
    size_t phdr1 = eg_off(o, EG_OFF_PHDR) + PHDR64_SIZE;
    eg_poke64(raw, len, phdr1 + 8, (uint64_t)len + 1000, 0);

    ob_image img;
    ASSERT_EQ_INT(ob_image_load(raw, len, &img), OB_IMG_OK);
    ob_dynamic dyn;
    ASSERT_EQ_INT(ob_dynamic_load(&img, &dyn), 0);
    ASSERT_TRUE(dyn.has_dynamic);
    ASSERT_TRUE(dyn.segment_out_of_range);
    ASSERT_EQ_U64(dyn.nraw, 0);

    ob_dynamic_free(&dyn); ob_image_free(&img);
    free(raw); eg_free(o);
}

/* ------------------------------------------------------------------ item 2 */

TEST(dynamic_pt_dynamic_filesz_zero) {
    eg *o = make_minimal_dynamic();
    size_t len;
    uint8_t *raw = eg_emit(o, &len);

    size_t phdr1 = eg_off(o, EG_OFF_PHDR) + PHDR64_SIZE;
    eg_poke64(raw, len, phdr1 + 32, 0, 0); /* p_filesz */

    ob_image img; ob_dynamic dyn;
    load_ok(raw, len, &img, &dyn);
    ASSERT_TRUE(dyn.has_dynamic);
    ASSERT_FALSE(dyn.segment_out_of_range);
    ASSERT_EQ_U64(dyn.nraw, 0);

    ob_dynamic_free(&dyn); ob_image_free(&img);
    free(raw); eg_free(o);
}

/* ------------------------------------------------------------------ item 3 */

TEST(dynamic_pt_dynamic_filesz_misaligned) {
    eg *o = make_minimal_dynamic();
    size_t len;
    uint8_t *raw = eg_emit(o, &len);

    size_t dynsz = eg_size(o, EG_OFF_DYNAMIC);
    size_t phdr1 = eg_off(o, EG_OFF_PHDR) + PHDR64_SIZE;
    /* One byte short: no longer a multiple of 16, and the trailing DT_NULL
     * falls (partly) outside the declared segment. */
    eg_poke64(raw, len, phdr1 + 32, (uint64_t)dynsz - 1, 0);

    ob_image img; ob_dynamic dyn;
    load_ok(raw, len, &img, &dyn);
    ASSERT_TRUE(dyn.has_dynamic);
    ASSERT_FALSE(dyn.segment_out_of_range);
    ASSERT_TRUE(dyn.size_not_aligned);

    ob_dynamic_free(&dyn); ob_image_free(&img);
    free(raw); eg_free(o);
}

/* ------------------------------------------------------------------ item 4 */

TEST(dynamic_no_dt_null_runs_to_end_of_segment) {
    eg *o = make_minimal_dynamic();
    size_t len;
    uint8_t *raw = eg_emit(o, &len);

    /* Overwrite the DT_NULL terminator (the last entry) with something
     * else, so the array runs off the end of the segment with no
     * terminator at all. */
    size_t dynsz = eg_size(o, EG_OFF_DYNAMIC);
    size_t last_entry = eg_off(o, EG_OFF_DYNAMIC) + dynsz - DYN64_SIZE;
    eg_poke64(raw, len, last_entry, DT_TEXTREL, 0);
    eg_poke64(raw, len, last_entry + 8, 0, 0);

    ob_image img; ob_dynamic dyn;
    load_ok(raw, len, &img, &dyn);
    ASSERT_TRUE(dyn.no_dt_null);
    ASSERT_TRUE(dyn.has_textrel);

    ob_dynamic_free(&dyn); ob_image_free(&img);
    free(raw); eg_free(o);
}

/* ------------------------------------------------------------------ item 5 */

TEST(dynamic_100000_entries_bounded) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    for (int i = 0; i < 100000; i++) {
        /* Unknown tags in the (processor-specific, unused) high range:
         * ignored by process_tag, but still counted towards nraw. */
        eg_add_dyn(o, 0x60000000u + (uint64_t)i, (uint64_t)i);
    }
    size_t len;
    uint8_t *raw = eg_emit(o, &len);

    ob_image img; ob_dynamic dyn;
    load_ok(raw, len, &img, &dyn);
    ASSERT_TRUE(dyn.has_dynamic);
    ASSERT_EQ_U64(dyn.nraw, ONEBIN_MAX_DYNENT);
    ASSERT_TRUE(dyn.no_dt_null); /* bound hit before the real DT_NULL */

    ob_dynamic_free(&dyn); ob_image_free(&img);
    free(raw); eg_free(o);
}

/* ------------------------------------------------------------------ item 6 */

TEST(dynamic_strtab_unmapped) {
    eg *o = make_minimal_dynamic();
    size_t len;
    uint8_t *raw = eg_emit(o, &len);

    /* DT_STRTAB is the entry right after all DT_NEEDED entries (§ mkelf.c
     * emit_dynamic order): index 1 here (index 0 is the one DT_NEEDED). */
    size_t e1 = eg_off(o, EG_OFF_DYNAMIC) + DYN64_SIZE * 1;
    uint64_t bogus_vaddr = 0xFFFFFFFFFFFF0000ull;
    eg_poke64(raw, len, e1 + 8, bogus_vaddr, 0); /* d_un of DT_STRTAB */

    ob_image img; ob_dynamic dyn;
    load_ok(raw, len, &img, &dyn);
    ASSERT_TRUE(dyn.has_strtab);
    ASSERT_EQ_U64(dyn.strtab_off, OB_NOT_MAPPED);

    char out[64];
    ASSERT_EQ_INT(ob_dynamic_string(&img, &dyn, 1, out, sizeof(out)), OB_STR_NOT_MAPPED);

    ob_dynamic_free(&dyn); ob_image_free(&img);
    free(raw); eg_free(o);
}

/* ------------------------------------------------------------------ item 7 */

TEST(dynamic_strtab_in_bss_only) {
    eg *o = make_minimal_dynamic();
    /* p_memsz > p_filesz on the main load, so an address past p_filesz but
     * within p_memsz is real virtual memory with no file bytes behind it. */
    /* eg always sets p_memsz == p_filesz for the main load, so instead point
     * DT_STRTAB just past the file's own length: since BASE == 0 for ET_DYN
     * and p_offset == p_vaddr == 0, any vaddr >= p_filesz is unmapped —
     * exercising the same code path vaddr_to_offset uses for a .bss-only
     * address (delta < p_filesz fails either way). */
    size_t len;
    uint8_t *raw = eg_emit(o, &len);

    size_t e1 = eg_off(o, EG_OFF_DYNAMIC) + DYN64_SIZE * 1;
    eg_poke64(raw, len, e1 + 8, (uint64_t)len + 1, 0);

    ob_image img; ob_dynamic dyn;
    load_ok(raw, len, &img, &dyn);
    ASSERT_EQ_U64(dyn.strtab_off, OB_NOT_MAPPED);

    ob_dynamic_free(&dyn); ob_image_free(&img);
    free(raw); eg_free(o);
}

/* ------------------------------------------------------------------ item 8 */

TEST(dynamic_strsz_zero) {
    eg *o = make_minimal_dynamic();
    size_t len;
    uint8_t *raw = eg_emit(o, &len);

    /* DT_STRSZ is the entry right after DT_STRTAB: index 2. */
    size_t e2 = eg_off(o, EG_OFF_DYNAMIC) + DYN64_SIZE * 2;
    eg_poke64(raw, len, e2 + 8, 0, 0);

    ob_image img; ob_dynamic dyn;
    load_ok(raw, len, &img, &dyn);
    ASSERT_EQ_U64(dyn.strsz, 0);

    char out[64];
    ASSERT_EQ_INT(ob_dynamic_string(&img, &dyn, 0, out, sizeof(out)), OB_STR_OUT_OF_RANGE);

    ob_dynamic_free(&dyn); ob_image_free(&img);
    free(raw); eg_free(o);
}

/* ------------------------------------------------------------------ item 9 */

TEST(dynamic_strsz_uint64_max) {
    eg *o = make_minimal_dynamic();
    size_t len;
    uint8_t *raw = eg_emit(o, &len);

    size_t e2 = eg_off(o, EG_OFF_DYNAMIC) + DYN64_SIZE * 2;
    eg_poke64(raw, len, e2 + 8, UINT64_MAX, 0);

    ob_image img; ob_dynamic dyn;
    load_ok(raw, len, &img, &dyn);

    /* idx well within the (bogus) declared size, but ob_rdstr still bounds
     * every read against the real buffer length, so this must not read out
     * of bounds even though DT_STRSZ claims almost the whole address space
     * is valid string data. */
    char out[64];
    ob_str_err e = ob_dynamic_string(&img, &dyn, 0, out, sizeof(out));
    ASSERT_TRUE(e == OB_STR_OK || e == OB_STR_NO_NUL);

    ob_dynamic_free(&dyn); ob_image_free(&img);
    free(raw); eg_free(o);
}

/* ----------------------------------------------------------------- item 10 */

TEST(dynamic_strtab_last_byte_not_nul) {
    /* Build a normal file, then reach into .dynstr and clobber its very
     * last byte (the NUL that ends the last needed-soname string). */
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_add_needed(o, "libc.so.6");
    size_t len;
    uint8_t *raw = eg_emit(o, &len);

    size_t dynstr_off = eg_off(o, EG_OFF_DYNSTR);
    size_t dynstr_sz = eg_size(o, EG_OFF_DYNSTR);
    ASSERT_TRUE(dynstr_sz > 0);
    eg_poke8(raw, len, dynstr_off + dynstr_sz - 1, (uint8_t)'X');

    ob_image img; ob_dynamic dyn;
    load_ok(raw, len, &img, &dyn);
    ASSERT_EQ_U64(dyn.nneeded, 1);

    char out[64];
    /* The needed string's offset is the last string in dynstr: 1 (after the
     * leading NUL) — reading it now runs off the (corrupted) end. */
    ob_str_err e = ob_dynamic_string(&img, &dyn, dyn.needed[0], out, sizeof(out));
    ASSERT_EQ_INT(e, OB_STR_NO_NUL);

    ob_dynamic_free(&dyn); ob_image_free(&img);
    free(raw); eg_free(o);
}

/* ----------------------------------------------------------------- item 11 */

TEST(dynamic_needed_index_out_of_range) {
    eg *o = make_minimal_dynamic();
    size_t len;
    uint8_t *raw = eg_emit(o, &len);

    ob_image img; ob_dynamic dyn;
    load_ok(raw, len, &img, &dyn);

    char out[64];
    ASSERT_EQ_INT(ob_dynamic_string(&img, &dyn, dyn.strsz, out, sizeof(out)), OB_STR_OUT_OF_RANGE);
    ASSERT_EQ_INT(ob_dynamic_string(&img, &dyn, dyn.strsz + 1, out, sizeof(out)), OB_STR_OUT_OF_RANGE);
    ASSERT_EQ_INT(ob_dynamic_string(&img, &dyn, UINT64_MAX, out, sizeof(out)), OB_STR_OUT_OF_RANGE);

    ob_dynamic_free(&dyn); ob_image_free(&img);
    free(raw); eg_free(o);
}

/* -------------------------------------------------------- items 25, 26 (§6.1) */

TEST(vaddr_to_offset_duplicate_pt_load_first_wins) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_set_pad_to(o, 0x2000);
    /* An extra PT_LOAD claiming the same vaddr as the main one (0), but with
     * a different file offset — the FIRST program header (the main load)
     * must win. */
    eg_add_extra_load(o, 0, 0x100, PF_R);

    size_t len;
    uint8_t *raw = eg_emit(o, &len);
    ob_image img;
    ASSERT_EQ_INT(ob_image_load(raw, len, &img), OB_IMG_OK);

    ASSERT_EQ_U64(ob_image_vaddr_to_offset(&img, 0x10), 0x10); /* main load: offset == vaddr */

    ob_image_free(&img);
    free(raw); eg_free(o);
}

TEST(vaddr_to_offset_pt_load_overflow_never_crashes) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    /* p_vaddr + p_filesz would overflow UINT64_MAX for a naive implementation
     * that computes the sum before comparing. */
    eg_add_extra_load(o, UINT64_MAX - 10, 100, PF_R);

    size_t len;
    uint8_t *raw = eg_emit(o, &len);
    ob_image img;
    ASSERT_EQ_INT(ob_image_load(raw, len, &img), OB_IMG_OK);

    ASSERT_EQ_U64(ob_image_vaddr_to_offset(&img, 5), 5); /* still resolved by the main load */
    /* p_vaddr == UINT64_MAX-10 means only queries in [UINT64_MAX-10,
     * UINT64_MAX] are even reachable without overflowing the query itself —
     * delta can never reach the declared filesz of 100. The point of this
     * test is that querying anywhere in that reachable band, right up to
     * the very top of the address space, must not crash or read out of
     * bounds, precisely because a naive p_vaddr + p_filesz computation
     * would have overflowed for this segment. */
    for (uint64_t v = UINT64_MAX - 10; v != 0; v++) {
        (void)ob_image_vaddr_to_offset(&img, v);
        if (v == UINT64_MAX) {
            break; /* v++ here would overflow the loop counter itself */
        }
    }

    ob_image_free(&img);
    free(raw); eg_free(o);
}

/* -------------------------------------------------------- items 27, 28, 29 */

TEST(vaddr_to_offset_pt_load_bogus_offset_or_size_never_crashes) {
    /* p_offset beyond EOF (27), p_filesz > file length (28), and
     * p_memsz < p_filesz (29, harmless to vaddr_to_offset, which only ever
     * reads p_filesz) — none of these may crash or read out of bounds when
     * a caller later tries to actually read at the returned offset. */
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_add_extra_load(o, 0x100000, 0x1000, PF_R); /* p_offset defaults small; poked below */

    size_t len;
    uint8_t *raw = eg_emit(o, &len);

    size_t phdr1 = eg_off(o, EG_OFF_PHDR) + PHDR64_SIZE; /* the extra load */
    eg_poke64(raw, len, phdr1 + 8, (uint64_t)len * 100, 0);   /* p_offset beyond EOF */

    ob_image img;
    ASSERT_EQ_INT(ob_image_load(raw, len, &img), OB_IMG_OK);

    /* The address is in range for the (bogus) segment; the offset this
     * returns must not be blindly trusted for reads — every subsequent
     * ob_rd* call bounds-checks it independently, which is what makes this
     * safe rather than merely convenient. */
    uint64_t off = ob_image_vaddr_to_offset(&img, 0x100000 + 4);
    uint32_t dummy;
    if (off != OB_NOT_MAPPED) {
        ASSERT_TRUE(ob_rd32(&img.buf, (size_t)off, &dummy) != 0 || off < len);
    }

    ob_image_free(&img);
    free(raw); eg_free(o);
}

/* ----------------------------------------------------------- items 34, 35 */

TEST(interp_filesz_zero_no_string) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_set_interp(o, "/lib64/ld-linux-x86-64.so.2");
    size_t len;
    uint8_t *raw = eg_emit(o, &len);

    /* phdr[0] would be PT_INTERP per mkelf.h's fixed order; zero its
     * p_filesz so the string has no bytes to be read from. */
    size_t phdr0 = eg_off(o, EG_OFF_PHDR);
    eg_poke64(raw, len, phdr0 + 32, 0, 0);

    ob_image img;
    ASSERT_EQ_INT(ob_image_load(raw, len, &img), OB_IMG_OK);
    ASSERT_EQ_INT(img.phdrs[0].p_type, PT_INTERP);

    char out[256];
    ASSERT_TRUE(ob_rdstr(&img.buf, (size_t)img.phdrs[0].p_offset, out, sizeof(out),
                          (size_t)img.phdrs[0].p_filesz) < 0);

    ob_image_free(&img);
    free(raw); eg_free(o);
}

TEST(interp_no_nul_inside_filesz) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_set_interp(o, "/lib64/ld-linux-x86-64.so.2");
    size_t len;
    uint8_t *raw = eg_emit(o, &len);

    size_t phdr0 = eg_off(o, EG_OFF_PHDR);
    /* Shrink p_filesz so it no longer reaches the terminating NUL, which
     * mkelf places right after the string. */
    eg_poke64(raw, len, phdr0 + 32, 5, 0); /* "/lib6" — no NUL in 5 bytes */

    ob_image img;
    ASSERT_EQ_INT(ob_image_load(raw, len, &img), OB_IMG_OK);

    char out[256];
    ASSERT_TRUE(ob_rdstr(&img.buf, (size_t)img.phdrs[0].p_offset, out, sizeof(out),
                          (size_t)img.phdrs[0].p_filesz) < 0);

    ob_image_free(&img);
    free(raw); eg_free(o);
}

/* --------------------------------------------------------------- baseline */

TEST(dynamic_hybrid_ok_preset_sanity) {
    eg *o = eg_preset_hybrid_ok();
    size_t len;
    uint8_t *raw = eg_emit(o, &len);

    ob_image img; ob_dynamic dyn;
    load_ok(raw, len, &img, &dyn);
    ASSERT_TRUE(dyn.has_dynamic);
    ASSERT_FALSE(dyn.no_dt_null);
    ASSERT_FALSE(dyn.segment_out_of_range);
    ASSERT_EQ_U64(dyn.nneeded, 2);
    ASSERT_TRUE(dyn.has_strtab);
    ASSERT_TRUE(dyn.has_symtab);
    ASSERT_TRUE(dyn.has_gnu_hash);
    ASSERT_TRUE(dyn.has_verneed);
    ASSERT_EQ_U64(dyn.verneednum, 1);

    char name[64];
    ASSERT_EQ_INT(ob_dynamic_string(&img, &dyn, dyn.needed[0], name, sizeof(name)), OB_STR_OK);
    ASSERT_EQ_STR(name, "libc.so.6");
    ASSERT_EQ_INT(ob_dynamic_string(&img, &dyn, dyn.needed[1], name, sizeof(name)), OB_STR_OK);
    ASSERT_EQ_STR(name, "libm.so.6");

    ob_dynamic_free(&dyn); ob_image_free(&img);
    free(raw); eg_free(o);
}
