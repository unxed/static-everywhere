/* t_mkelf.c — the generator tests itself.  03-TESTPLAN.md §3.
 *
 * The assertions here read raw bytes, or read them back through util/buf.
 * They deliberately do NOT use the ELF parser: it does not exist until Task 5,
 * and once it does, a shared bug in the byte-order code would make both sides
 * agree and both be wrong.
 */
#include <sys/types.h>
#include <sys/wait.h>

#include "test.h"
#include "mkelf.h"
#include "util/buf.h"
#include "elf/elf_const.h"

/* ------------------------------------------------------------- helpers */

static uint16_t rd16(const uint8_t *p, size_t off, int be)
{
    /* Assign, don't return the ternary: its operands promote to int, and the
     * implicit narrowing back to uint16_t trips -Wconversion. */
    uint16_t v;
    if (be) v = (uint16_t)(((uint16_t)p[off] << 8) | p[off + 1]);
    else    v = (uint16_t)(((uint16_t)p[off + 1] << 8) | p[off]);
    return v;
}

static uint32_t rd32(const uint8_t *p, size_t off, int be)
{
    uint32_t v = 0;
    for (int i = 0; i < 4; i++) {
        unsigned sh = (unsigned)(be ? (3 - i) : i) * 8u;
        v |= (uint32_t)p[off + (size_t)i] << sh;
    }
    return v;
}

/* What a semantic round-trip compares.  Read back with util/buf, which is the
 * only component that is allowed to touch raw file bytes. */
typedef struct {
    uint16_t type, machine, phnum;
    size_t   nneeded;
    int      has_dynamic, has_interp, has_soname;
    uint64_t strsz;
} semantics;

static int read_back(const uint8_t *buf, size_t len, int cls, int be, semantics *s)
{
    ob_buf b = { .p = buf, .len = len, .be = be, .c64 = (cls == 64) };
    uint16_t phentsize = 0;
    uint64_t phoff = 0;
    uint32_t tmp32 = 0;

    memset(s, 0, sizeof(*s));

    if (ob_rd16(&b, 16, &s->type) != 0) return -1;
    if (ob_rd16(&b, 18, &s->machine) != 0) return -1;

    if (cls == 64) {
        if (ob_rd64(&b, 32, &phoff) != 0) return -1;
        if (ob_rd16(&b, 54, &phentsize) != 0) return -1;
        if (ob_rd16(&b, 56, &s->phnum) != 0) return -1;
    } else {
        if (ob_rd32(&b, 28, &tmp32) != 0) return -1;
        phoff = tmp32;
        if (ob_rd16(&b, 42, &phentsize) != 0) return -1;
        if (ob_rd16(&b, 44, &s->phnum) != 0) return -1;
    }

    uint64_t dyn_off = 0, dyn_sz = 0;
    for (uint16_t i = 0; i < s->phnum; i++) {
        size_t at = (size_t)phoff + (size_t)i * phentsize;
        uint32_t ptype = 0;
        if (ob_rd32(&b, at, &ptype) != 0) return -1;
        if (ptype == PT_INTERP) s->has_interp = 1;
        if (ptype == PT_DYNAMIC) {
            s->has_dynamic = 1;
            if (cls == 64) {
                if (ob_rd64(&b, at + 8, &dyn_off) != 0) return -1;
                if (ob_rd64(&b, at + 32, &dyn_sz) != 0) return -1;
            } else {
                if (ob_rd32(&b, at + 4, &tmp32) != 0) return -1;
                dyn_off = tmp32;
                if (ob_rd32(&b, at + 16, &tmp32) != 0) return -1;
                dyn_sz = tmp32;
            }
        }
    }

    if (!s->has_dynamic) return 0;

    size_t entsz = (size_t)(cls == 64 ? DYN64_SIZE : DYN32_SIZE);
    for (size_t at = (size_t)dyn_off; at + entsz <= dyn_off + dyn_sz; at += entsz) {
        uint64_t tag = 0, val = 0;
        if (cls == 64) {
            if (ob_rd64(&b, at, &tag) != 0) return -1;
            if (ob_rd64(&b, at + 8, &val) != 0) return -1;
        } else {
            if (ob_rd32(&b, at, &tmp32) != 0) return -1;
            tag = tmp32;
            if (ob_rd32(&b, at + 4, &tmp32) != 0) return -1;
            val = tmp32;
        }
        if (tag == DT_NULL) break;
        if (tag == DT_NEEDED) s->nneeded++;
        if (tag == DT_SONAME) s->has_soname = 1;
        if (tag == DT_STRSZ)  s->strsz = val;
    }
    return 0;
}

static int same(const semantics *a, const semantics *b)
{
    return a->type == b->type && a->machine == b->machine
        && a->phnum == b->phnum && a->nneeded == b->nneeded
        && a->has_dynamic == b->has_dynamic && a->has_interp == b->has_interp
        && a->has_soname == b->has_soname && a->strsz == b->strsz;
}

/* --------------------------------------------- 3.1 raw bytes, 8 variants */

TEST(mkelf_raw_header_all_variants) {
    const int classes[] = { 32, 64 };
    const int ends[]    = { EG_LE, EG_BE };
    const uint16_t types[] = { ET_EXEC, ET_DYN };

    for (int ci = 0; ci < 2; ci++) {
        for (int ei = 0; ei < 2; ei++) {
            for (int ti = 0; ti < 2; ti++) {
                int cls = classes[ci];
                int be  = (ends[ei] == EG_BE);
                eg *o = eg_new(cls, ends[ei], EM_X86_64, types[ti]);
                size_t len = 0;
                uint8_t *b = eg_emit(o, &len);

                ASSERT_NOT_NULL(b);
                ASSERT_EQ_INT(b[0], 0x7F);
                ASSERT_EQ_INT(b[1], 'E');
                ASSERT_EQ_INT(b[2], 'L');
                ASSERT_EQ_INT(b[3], 'F');
                ASSERT_EQ_INT(b[EI_CLASS], cls == 64 ? ELFCLASS64 : ELFCLASS32);
                ASSERT_EQ_INT(b[EI_DATA], be ? ELFDATA2MSB : ELFDATA2LSB);
                ASSERT_EQ_INT(b[EI_VERSION], EV_CURRENT);
                ASSERT_EQ_INT(b[EI_OSABI], ELFOSABI_NONE);

                ASSERT_EQ_INT(rd16(b, 16, be), types[ti]);
                ASSERT_EQ_INT(rd16(b, 18, be), EM_X86_64);
                ASSERT_EQ_U64(rd32(b, 20, be), EV_CURRENT);

                if (cls == 64) {
                    ASSERT_EQ_INT(rd16(b, 52, be), EHDR64_SIZE);   /* e_ehsize */
                    ASSERT_EQ_INT(rd16(b, 54, be), PHDR64_SIZE);   /* e_phentsize */
                    ASSERT_EQ_INT(rd16(b, 56, be), 1);             /* e_phnum */
                    /* e_phoff is 8 bytes: its low word sits at +4 on BE. */
                    ASSERT_EQ_U64(rd32(b, be ? 36 : 32, be), EHDR64_SIZE);
                } else {
                    ASSERT_EQ_INT(rd16(b, 40, be), EHDR32_SIZE);
                    ASSERT_EQ_INT(rd16(b, 42, be), PHDR32_SIZE);
                    ASSERT_EQ_INT(rd16(b, 44, be), 1);
                    ASSERT_EQ_U64(rd32(b, 28, be), EHDR32_SIZE);
                }

                free(b);
                eg_free(o);
            }
        }
    }
}

/* -------------------------------------------------- 3.2 hand-computed size */

TEST(mkelf_minimal_length_is_hand_computable) {
    eg *o64 = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    size_t l64 = 0;
    uint8_t *b64 = eg_emit(o64, &l64);
    ASSERT_EQ_U64(l64, (uint64_t)(EHDR64_SIZE + PHDR64_SIZE));   /* 64 + 56 */
    ASSERT_EQ_U64(eg_off(o64, EG_OFF_PHDR), EHDR64_SIZE);
    ASSERT_EQ_U64(eg_size(o64, EG_OFF_PHDR), PHDR64_SIZE);
    free(b64); eg_free(o64);

    eg *o32 = eg_new(32, EG_LE, EM_386, ET_DYN);
    size_t l32 = 0;
    uint8_t *b32 = eg_emit(o32, &l32);
    ASSERT_EQ_U64(l32, (uint64_t)(EHDR32_SIZE + PHDR32_SIZE));   /* 52 + 32 */
    free(b32); eg_free(o32);
}

/* ------------------------------- 3.3 the worked example, 02-REFERENCE §9 */

TEST(mkelf_reproduces_reference_example) {
    /* ET_DYN x86_64, e_entry 0x1000, two phdrs, PT_LOAD covering 512 bytes
     * with PF_R|PF_X.  The second phdr is PT_GNU_STACK, which is what gets
     * e_phnum to 2 without disturbing the PT_LOAD the reference describes. */
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_set_entry(o, 0x1000);
    eg_set_load_flags(o, PF_R | PF_X);
    eg_set_gnu_stack(o, 1, PF_R | PF_W);
    eg_set_pad_to(o, 512);

    size_t len = 0;
    uint8_t *b = eg_emit(o, &len);
    ASSERT_EQ_U64(len, 512);

    static const uint8_t want_ehdr[64] = {
        0x7F,'E','L','F', 0x02, 0x01, 0x01, 0x00,
        0,0,0,0,0,0,0,0,
        0x03,0x00,                                     /* e_type = ET_DYN   */
        0x3E,0x00,                                     /* e_machine = 62    */
        0x01,0x00,0x00,0x00,                           /* e_version         */
        0x00,0x10,0,0,0,0,0,0,                         /* e_entry = 0x1000  */
        0x40,0,0,0,0,0,0,0,                            /* e_phoff = 64      */
        0,0,0,0,0,0,0,0,                               /* e_shoff = 0       */
        0,0,0,0,                                       /* e_flags           */
        0x40,0x00,                                     /* e_ehsize = 64     */
        0x38,0x00,                                     /* e_phentsize = 56  */
        0x02,0x00,                                     /* e_phnum = 2       */
        0x40,0x00,                                     /* e_shentsize = 64  */
        0x00,0x00,                                     /* e_shnum = 0       */
        0x00,0x00                                      /* e_shstrndx = 0    */
    };
    ASSERT_EQ_MEM(b, want_ehdr, sizeof(want_ehdr));

    static const uint8_t want_phdr[56] = {
        0x01,0,0,0,                                    /* PT_LOAD           */
        0x05,0,0,0,                                    /* PF_R|PF_X at +4   */
        0,0,0,0,0,0,0,0,                               /* p_offset = 0      */
        0,0,0,0,0,0,0,0,                               /* p_vaddr  = 0      */
        0,0,0,0,0,0,0,0,                               /* p_paddr  = 0      */
        0x00,0x02,0,0,0,0,0,0,                         /* p_filesz = 512    */
        0x00,0x02,0,0,0,0,0,0,                         /* p_memsz  = 512    */
        0x00,0x10,0,0,0,0,0,0                          /* p_align  = 0x1000 */
    };
    ASSERT_EQ_MEM(b + 64, want_phdr, sizeof(want_phdr));

    free(b);
    eg_free(o);
}

/* ------------------------------------------ 3.4 ELF32 vs ELF64 semantics */

static void build_logical(eg *o)
{
    eg_set_interp(o, "/lib/ld.so.1");
    eg_add_needed(o, "libc.so.6");
    eg_add_needed(o, "libm.so.6");
    eg_set_flags(o, DF_BIND_NOW, DF_1_NOW);
    eg_set_gnu_relro(o, 1);
    eg_set_gnu_stack(o, 1, PF_R | PF_W);
}

TEST(mkelf_elf32_and_elf64_agree) {
    eg *a = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg *c = eg_new(32, EG_LE, EM_X86_64, ET_DYN);
    build_logical(a); build_logical(c);

    size_t la = 0, lc = 0;
    uint8_t *ba = eg_emit(a, &la);
    uint8_t *bc = eg_emit(c, &lc);

    semantics sa, sc;
    ASSERT_EQ_INT(read_back(ba, la, 64, 0, &sa), 0);
    ASSERT_EQ_INT(read_back(bc, lc, 32, 0, &sc), 0);

    ASSERT_EQ_INT(sa.nneeded, 2);
    ASSERT_EQ_INT(sa.has_interp, 1);
    ASSERT_EQ_INT(sa.has_dynamic, 1);
    ASSERT_TRUE(same(&sa, &sc));

    free(ba); free(bc); eg_free(a); eg_free(c);
}

/* --------------------------------------------- 3.5 LE vs BE semantics */

TEST(mkelf_le_and_be_agree) {
    eg *a = eg_new(64, EG_LE, EM_AARCH64, ET_DYN);
    eg *c = eg_new(64, EG_BE, EM_AARCH64, ET_DYN);
    build_logical(a); build_logical(c);

    size_t la = 0, lc = 0;
    uint8_t *ba = eg_emit(a, &la);
    uint8_t *bc = eg_emit(c, &lc);

    ASSERT_EQ_U64(la, lc);

    semantics sa, sc;
    ASSERT_EQ_INT(read_back(ba, la, 64, 0, &sa), 0);
    ASSERT_EQ_INT(read_back(bc, lc, 64, 1, &sc), 0);
    ASSERT_TRUE(same(&sa, &sc));

    free(ba); free(bc); eg_free(a); eg_free(c);
}

/* ------------------------------------------------- 3.6 pokes bounds-check */

TEST(mkelf_poke_in_range_writes) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    size_t len = 0;
    uint8_t *b = eg_emit(o, &len);

    eg_poke32(b, len, 20, 0xDEADBEEF, 0);
    ASSERT_EQ_U64(rd32(b, 20, 0), 0xDEADBEEF);

    eg_poke16(b, len, 16, 0x1234, 1);
    ASSERT_EQ_INT(rd16(b, 16, 1), 0x1234);

    eg_poke8(b, len, 0, 0x00);
    ASSERT_EQ_INT(b[0], 0);

    free(b); eg_free(o);
}

TEST(mkelf_poke_out_of_range_aborts) {
    /* The harness runs each test in a forked child, so an abort() here is
     * observed as a failing child rather than taking the suite down.  We want
     * the abort, so we assert the inverse: reaching the next line is failure. */
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    size_t len = 0;
    uint8_t *b = eg_emit(o, &len);

    pid_t pid = fork();
    if (pid == 0) {
        /* Silence the abort message so a passing run has clean output. */
        FILE *devnull = freopen("/dev/null", "w", stderr);
        (void)devnull;
        eg_poke32(b, len, len, 0, 0);   /* one past the end */
        _exit(0);                        /* must not be reached */
    }
    ASSERT_TRUE(pid > 0);

    int status = 0;
    waitpid(pid, &status, 0);
    ASSERT_TRUE(WIFSIGNALED(status) || (WIFEXITED(status) && WEXITSTATUS(status) != 0));

    free(b); eg_free(o);
}

/* ----------------------------------------------- 3.7 presets round-trip */

TEST(mkelf_preset_hybrid_ok) {
    eg *o = eg_preset_hybrid_ok();
    size_t len = 0;
    uint8_t *b = eg_emit(o, &len);

    semantics s;
    ASSERT_EQ_INT(read_back(b, len, 64, 0, &s), 0);
    ASSERT_EQ_INT(s.type, ET_DYN);
    ASSERT_EQ_INT(s.machine, EM_X86_64);
    ASSERT_EQ_INT(s.has_interp, 1);
    ASSERT_EQ_INT(s.has_dynamic, 1);
    ASSERT_EQ_INT(s.nneeded, 2);
    ASSERT_EQ_INT(s.has_soname, 0);
    ASSERT_TRUE(s.strsz > 0);
    ASSERT_TRUE(eg_size(o, EG_OFF_VERNEED) > 0);
    ASSERT_TRUE(eg_size(o, EG_OFF_DYNSYM) > 0);

    free(b); eg_free(o);
}

TEST(mkelf_preset_static_ok) {
    eg *o = eg_preset_static_ok();
    size_t len = 0;
    uint8_t *b = eg_emit(o, &len);

    semantics s;
    ASSERT_EQ_INT(read_back(b, len, 64, 0, &s), 0);
    ASSERT_EQ_INT(s.type, ET_DYN);
    ASSERT_EQ_INT(s.has_interp, 0);       /* static-PIE: no interpreter */
    ASSERT_EQ_INT(s.has_dynamic, 1);      /* but it does have PT_DYNAMIC */
    ASSERT_EQ_INT(s.nneeded, 0);

    free(b); eg_free(o);
}

TEST(mkelf_preset_static_nopie) {
    eg *o = eg_preset_static_nopie();
    size_t len = 0;
    uint8_t *b = eg_emit(o, &len);

    semantics s;
    ASSERT_EQ_INT(read_back(b, len, 64, 0, &s), 0);
    ASSERT_EQ_INT(s.type, ET_EXEC);
    ASSERT_EQ_INT(s.has_dynamic, 0);      /* no PT_DYNAMIC at all */
    ASSERT_EQ_INT(s.has_interp, 0);

    free(b); eg_free(o);
}

TEST(mkelf_preset_shared_lib) {
    eg *o = eg_preset_shared_lib();
    size_t len = 0;
    uint8_t *b = eg_emit(o, &len);

    semantics s;
    ASSERT_EQ_INT(read_back(b, len, 64, 0, &s), 0);
    ASSERT_EQ_INT(s.type, ET_DYN);
    ASSERT_EQ_INT(s.has_soname, 1);
    ASSERT_EQ_INT(s.has_interp, 0);

    free(b); eg_free(o);
}

TEST(mkelf_preset_module) {
    /* The regression fixture for 04-REFERENCE-far2l.md §7.6: a CMake MODULE
     * library has DT_NEEDED but no DT_SONAME, which is what made the old
     * profile ladder call every far2l plugin a broken executable. */
    eg *o = eg_preset_module();
    size_t len = 0;
    uint8_t *b = eg_emit(o, &len);

    semantics s;
    ASSERT_EQ_INT(read_back(b, len, 64, 0, &s), 0);
    ASSERT_EQ_INT(s.type, ET_DYN);
    ASSERT_EQ_INT(s.has_soname, 0);
    ASSERT_EQ_INT(s.has_interp, 0);
    ASSERT_EQ_INT(s.nneeded, 1);
    ASSERT_EQ_INT(s.has_dynamic, 1);

    free(b); eg_free(o);
}

/* ---------------------------------------------------- structural extras */

TEST(mkelf_base_makes_vaddr_translation_trivial) {
    /* BASE is 0 for ET_DYN and 0x400000 for ET_EXEC, and the single PT_LOAD
     * starts at file offset 0, so vaddr - BASE == offset for the whole file. */
    eg *d = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_add_needed(d, "libc.so.6");
    size_t ld = 0;
    uint8_t *bd = eg_emit(d, &ld);
    ASSERT_EQ_U64(rd32(bd, 64 + 8, 0), 0);               /* p_offset = 0 */
    ASSERT_EQ_U64(rd32(bd, 64 + 16, 0), EG_BASE_DYN);    /* p_vaddr      */
    free(bd); eg_free(d);

    eg *e = eg_new(64, EG_LE, EM_X86_64, ET_EXEC);
    eg_add_needed(e, "libc.so.6");
    size_t le = 0;
    uint8_t *be = eg_emit(e, &le);
    ASSERT_EQ_U64(rd32(be, 64 + 8, 0), 0);
    ASSERT_EQ_U64(rd32(be, 64 + 16, 0), EG_BASE_EXEC);
    free(be); eg_free(e);
}

TEST(mkelf_sections_and_rodata) {
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_add_rodata_string(o, "/home/builder/src/main.c");
    eg_add_rodata_string(o, "libGL.so.1");
    static const uint8_t dbg[4] = { 1, 2, 3, 4 };
    eg_add_section(o, ".debug_info", SHT_PROGBITS, dbg, sizeof(dbg));

    size_t len = 0;
    uint8_t *b = eg_emit(o, &len);

    size_t ro = eg_off(o, EG_OFF_RODATA);
    ASSERT_TRUE(ro > 0);
    ASSERT_EQ_STR((const char *)(b + ro), "/home/builder/src/main.c");
    ASSERT_EQ_STR((const char *)(b + ro + strlen("/home/builder/src/main.c") + 1),
                  "libGL.so.1");

    ASSERT_TRUE(eg_off(o, EG_OFF_SHDR) > 0);
    ASSERT_EQ_INT(rd16(b, 60, 0), 3);      /* e_shnum: NULL + .debug_info + shstrtab */
    ASSERT_EQ_INT(rd16(b, 62, 0), 2);      /* e_shstrndx */

    free(b); eg_free(o);
}

TEST(mkelf_write_to_disk_round_trips) {
    eg *o = eg_preset_hybrid_ok();
    const char *path = "build/t_mkelf_out.elf";

    ASSERT_EQ_INT(eg_write(o, path), 0);

    FILE *f = fopen(path, "rb");
    ASSERT_NOT_NULL(f);
    uint8_t head[4] = { 0, 0, 0, 0 };
    size_t n = fread(head, 1, 4, f);
    fclose(f);
    remove(path);

    ASSERT_EQ_U64(n, 4);
    ASSERT_EQ_INT(head[0], 0x7F);
    ASSERT_EQ_INT(head[1], 'E');

    eg_free(o);
}
