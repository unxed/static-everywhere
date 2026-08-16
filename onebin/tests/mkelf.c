/* mkelf.c — see mkelf.h for the layout contract.
 *
 * Style notes for whoever extends this:
 *   - Nothing here casts a struct onto file bytes, in either direction.  Every
 *     field is written one at a time through put*(), which is the mirror image
 *     of the rule the parser lives under.
 *   - Allocation failure and out-of-range pokes abort().  This is test-support
 *     code: a fixture that silently comes out wrong is worse than a crash,
 *     because it makes the suite pass for the wrong reason.
 */
#include "mkelf.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "elf/elf_const.h"

/* ---------------------------------------------------------------- helpers */

static void *xmalloc(size_t n)
{
    void *p = malloc(n ? n : 1);
    if (!p) { fprintf(stderr, "mkelf: out of memory\n"); abort(); }
    return p;
}

static void *xrealloc(void *p, size_t n)
{
    void *q = realloc(p, n ? n : 1);
    if (!q) { fprintf(stderr, "mkelf: out of memory\n"); abort(); }
    return q;
}

static char *xstrdup(const char *s)
{
    size_t n = strlen(s) + 1;
    char *d = (char *)xmalloc(n);
    memcpy(d, s, n);
    return d;
}

/* Growable byte buffer. */
typedef struct { uint8_t *p; size_t len, cap; } bbuf;

static void bb_need(bbuf *b, size_t extra)
{
    if (b->len + extra <= b->cap) return;
    size_t cap = b->cap ? b->cap : 64;
    while (cap < b->len + extra) cap *= 2;
    b->p = (uint8_t *)xrealloc(b->p, cap);
    b->cap = cap;
}

static void bb_put(bbuf *b, const void *data, size_t n)
{
    bb_need(b, n);
    memcpy(b->p + b->len, data, n);
    b->len += n;
}

static size_t bb_put_str(bbuf *b, const char *s)   /* returns start offset */
{
    size_t at = b->len;
    bb_put(b, s, strlen(s) + 1);
    return at;
}

/* ------------------------------------------------------------ the builder */

typedef struct { uint64_t tag, val; int val_is_stroff; } eg_dyn;
typedef struct { char *file; char **vers; size_t nvers; } eg_vn;
typedef struct { char *name; uint16_t versym; uint8_t info; uint16_t shndx; } eg_sym;
typedef struct { char *name; uint32_t type; uint8_t *data; size_t len; } eg_sec;
typedef struct { uint64_t vaddr, filesz; uint32_t flags; } eg_load;

#define VEC(type, name) type *name; size_t n##name, c##name

struct eg {
    int      cls;          /* 32 or 64 */
    int      be;
    uint16_t machine;
    uint16_t type;
    uint64_t entry;
    uint64_t base;
    uint32_t load_flags;
    size_t   pad_to;

    char *interp;
    char *soname;
    char *rpath;
    char *runpath;
    VEC(char *, needed);

    uint64_t dt_flags, dt_flags_1;
    int      have_flags;
    int      textrel;
    int      force_dynamic;
    VEC(eg_dyn, extradyn);

    int      stack_present;
    uint32_t stack_flags;
    int      relro;
    VEC(eg_load, loads);

    VEC(eg_vn, verneeds);
    VEC(eg_sym, syms);
    int hash_sysv, hash_gnu;

    VEC(char *, rodata);
    VEC(eg_sec, sections);
    int emit_shdrs;

    /* filled in by eg_emit() */
    size_t off[8], siz[8];
};

#define VEC_PUSH(o, name, type, value)                                        \
    do {                                                                      \
        if ((o)->n##name == (o)->c##name) {                                   \
            (o)->c##name = (o)->c##name ? (o)->c##name * 2 : 8;               \
            (o)->name = (type *)xrealloc((o)->name,                           \
                                         (o)->c##name * sizeof(type));        \
        }                                                                     \
        (o)->name[(o)->n##name++] = (value);                                  \
    } while (0)

eg *eg_new(int cls, int endian, uint16_t machine, uint16_t type)
{
    if (cls != 32 && cls != 64) { fprintf(stderr, "mkelf: bad class %d\n", cls); abort(); }
    eg *o = (eg *)xmalloc(sizeof(*o));
    memset(o, 0, sizeof(*o));
    o->cls        = cls;
    o->be         = (endian == EG_BE);
    o->machine    = machine;
    o->type       = type;
    o->entry      = 0x1000;
    o->base       = (type == ET_EXEC) ? EG_BASE_EXEC : EG_BASE_DYN;
    o->load_flags = PF_R | PF_X;
    o->stack_flags = PF_R | PF_W;
    return o;
}

void eg_free(eg *o)
{
    if (!o) return;
    free(o->interp); free(o->soname); free(o->rpath); free(o->runpath);
    for (size_t i = 0; i < o->nneeded; i++) free(o->needed[i]);
    free(o->needed);
    free(o->extradyn);
    free(o->loads);
    for (size_t i = 0; i < o->nverneeds; i++) {
        free(o->verneeds[i].file);
        for (size_t j = 0; j < o->verneeds[i].nvers; j++) free(o->verneeds[i].vers[j]);
        free(o->verneeds[i].vers);
    }
    free(o->verneeds);
    for (size_t i = 0; i < o->nsyms; i++) free(o->syms[i].name);
    free(o->syms);
    for (size_t i = 0; i < o->nrodata; i++) free(o->rodata[i]);
    free(o->rodata);
    for (size_t i = 0; i < o->nsections; i++) { free(o->sections[i].name); free(o->sections[i].data); }
    free(o->sections);
    free(o);
}

static void set_str(char **slot, const char *v)
{
    free(*slot);
    *slot = v ? xstrdup(v) : NULL;
}

void eg_set_interp (eg *o, const char *p) { set_str(&o->interp, p); }
void eg_set_soname (eg *o, const char *s) { set_str(&o->soname, s); }
void eg_set_rpath  (eg *o, const char *v) { set_str(&o->rpath, v); }
void eg_set_runpath(eg *o, const char *v) { set_str(&o->runpath, v); }

void eg_add_needed(eg *o, const char *s)
{
    char *d = xstrdup(s);
    VEC_PUSH(o, needed, char *, d);
}

void eg_add_dyn(eg *o, uint64_t tag, uint64_t val)
{
    eg_dyn d = { tag, val, 0 };
    VEC_PUSH(o, extradyn, eg_dyn, d);
}

void eg_set_flags(eg *o, uint64_t f, uint64_t f1)
{
    o->dt_flags = f; o->dt_flags_1 = f1; o->have_flags = 1;
}

void eg_set_textrel(eg *o, int on) { o->textrel = on; }
void eg_force_dynamic(eg *o, int on) { o->force_dynamic = on; }
void eg_set_entry(eg *o, uint64_t e) { o->entry = e; }
void eg_set_pad_to(eg *o, size_t n) { o->pad_to = n; }
void eg_set_load_flags(eg *o, uint32_t f) { o->load_flags = f; }

void eg_set_gnu_stack(eg *o, int present, uint32_t flags)
{
    o->stack_present = present; o->stack_flags = flags;
}

void eg_set_gnu_relro(eg *o, int present) { o->relro = present; }

void eg_add_extra_load(eg *o, uint64_t vaddr, uint64_t filesz, uint32_t flags)
{
    eg_load l = { vaddr, filesz, flags };
    VEC_PUSH(o, loads, eg_load, l);
}

void eg_add_verneed(eg *o, const char *file, const char *const *versions, size_t n)
{
    eg_vn vn;
    vn.file  = xstrdup(file);
    vn.nvers = n;
    vn.vers  = (char **)xmalloc(n * sizeof(char *));
    for (size_t i = 0; i < n; i++) vn.vers[i] = xstrdup(versions[i]);
    VEC_PUSH(o, verneeds, eg_vn, vn);
}

void eg_add_dynsym(eg *o, const char *name, uint16_t versym, uint8_t info, uint16_t shndx)
{
    eg_sym s;
    s.name = xstrdup(name);
    s.versym = versym; s.info = info; s.shndx = shndx;
    VEC_PUSH(o, syms, eg_sym, s);
}

void eg_set_hash_style(eg *o, int sysv, int gnu) { o->hash_sysv = sysv; o->hash_gnu = gnu; }

void eg_add_rodata_string(eg *o, const char *s)
{
    char *d = xstrdup(s);
    VEC_PUSH(o, rodata, char *, d);
}

void eg_add_section(eg *o, const char *name, uint32_t type, const void *data, size_t len)
{
    eg_sec s;
    s.name = xstrdup(name);
    s.type = type;
    s.len  = len;
    s.data = (uint8_t *)xmalloc(len ? len : 1);
    if (len) memcpy(s.data, data, len);
    VEC_PUSH(o, sections, eg_sec, s);
    o->emit_shdrs = 1;
}

void eg_set_shdrs(eg *o, int emit) { o->emit_shdrs = emit; }

/* ------------------------------------------------------------------ emit */

static void put8(bbuf *b, uint8_t v) { bb_put(b, &v, 1); }

static void put16(bbuf *b, int be, uint16_t v)
{
    uint8_t t[2];
    if (be) { t[0] = (uint8_t)(v >> 8); t[1] = (uint8_t)v; }
    else    { t[0] = (uint8_t)v; t[1] = (uint8_t)(v >> 8); }
    bb_put(b, t, 2);
}

static void put32(bbuf *b, int be, uint32_t v)
{
    uint8_t t[4];
    for (int i = 0; i < 4; i++) {
        unsigned sh = (unsigned)(be ? (3 - i) : i) * 8u;
        t[i] = (uint8_t)(v >> sh);
    }
    bb_put(b, t, 4);
}

static void put64(bbuf *b, int be, uint64_t v)
{
    uint8_t t[8];
    for (int i = 0; i < 8; i++) {
        unsigned sh = (unsigned)(be ? (7 - i) : i) * 8u;
        t[i] = (uint8_t)(v >> sh);
    }
    bb_put(b, t, 8);
}

/* Word: 4 bytes on ELF32, 8 on ELF64. */
static void putw(bbuf *b, const eg *o, uint64_t v)
{
    if (o->cls == 64) put64(b, o->be, v);
    else              put32(b, o->be, (uint32_t)v);
}

static void pad_to(bbuf *b, size_t align)
{
    while (b->len % align) put8(b, 0);
}

static size_t align_up(size_t v, size_t a) { return (v + a - 1) / a * a; }

/* Does this file have a .dynamic at all? */
static int has_dynamic(const eg *o)
{
    return o->force_dynamic || o->nneeded || o->soname || o->rpath || o->runpath
        || o->nsyms || o->nverneeds || o->have_flags || o->textrel || o->nextradyn;
}

static size_t phnum_of(const eg *o)
{
    size_t n = 1;                               /* the main PT_LOAD */
    if (o->interp)        n++;
    n += o->nloads;
    if (has_dynamic(o))   n++;
    if (o->relro)         n++;
    if (o->stack_present) n++;
    return n;
}

/* Where each part starts, and how big it is.  Computed before writing so that
 * .dynamic can name addresses of parts that come after it. */
typedef struct {
    size_t ehdr, phdr, interp, dynstr, dynsym, hash, gnuhash;
    size_t versym, verneed, dynamic, rodata, secdata, shdr, total;
    size_t dynstr_sz, dynsym_sz, hash_sz, gnuhash_sz, versym_sz, verneed_sz;
    size_t dynamic_sz, rodata_sz, secdata_sz, shdr_sz, interp_sz, phdr_sz;
    size_t nsym;           /* including the reserved null symbol */
    size_t ndyn;           /* including DT_NULL */
} layout;

static size_t dynstr_size(const eg *o)
{
    size_t n = 1;                                        /* leading NUL */
    if (o->soname)  n += strlen(o->soname) + 1;
    for (size_t i = 0; i < o->nneeded; i++) n += strlen(o->needed[i]) + 1;
    if (o->rpath)   n += strlen(o->rpath) + 1;
    if (o->runpath) n += strlen(o->runpath) + 1;
    for (size_t i = 0; i < o->nsyms; i++) n += strlen(o->syms[i].name) + 1;
    for (size_t i = 0; i < o->nverneeds; i++) {
        n += strlen(o->verneeds[i].file) + 1;
        for (size_t j = 0; j < o->verneeds[i].nvers; j++)
            n += strlen(o->verneeds[i].vers[j]) + 1;
    }
    return n;
}

static size_t count_dyn(const eg *o)
{
    size_t n = 0;
    n += o->nneeded;
    if (o->soname)  n++;
    if (o->rpath)   n++;
    if (o->runpath) n++;
    n += 2;                                     /* DT_STRTAB, DT_STRSZ */
    if (o->nsyms) { n += 2; }                   /* DT_SYMTAB, DT_SYMENT */
    if (o->nsyms && o->hash_sysv) n++;
    if (o->nsyms && o->hash_gnu)  n++;
    if (o->nverneeds) n += 3;                   /* VERNEED, VERNEEDNUM, VERSYM */
    if (o->have_flags) n += 2;
    if (o->textrel)    n++;
    n += o->nextradyn;
    return n + 1;                               /* DT_NULL */
}

static void compute_layout(const eg *o, layout *L)
{
    size_t A    = (o->cls == 64) ? 8u : 4u;
    size_t ehsz = (o->cls == 64) ? EHDR64_SIZE : EHDR32_SIZE;
    size_t phsz = (o->cls == 64) ? PHDR64_SIZE : PHDR32_SIZE;
    size_t symsz= (o->cls == 64) ? SYM64_SIZE  : SYM32_SIZE;
    size_t dynsz= (o->cls == 64) ? DYN64_SIZE  : DYN32_SIZE;

    memset(L, 0, sizeof(*L));
    L->nsym = o->nsyms ? o->nsyms + 1 : 0;

    L->ehdr    = 0;
    L->phdr    = ehsz;
    L->phdr_sz = phsz * phnum_of(o);

    size_t at = align_up(L->phdr + L->phdr_sz, A);

    if (o->interp) {
        L->interp    = at;
        L->interp_sz = strlen(o->interp) + 1;
        at = align_up(at + L->interp_sz, A);
    }

    int dyn = has_dynamic(o);
    if (dyn) {
        L->dynstr    = at;
        L->dynstr_sz = dynstr_size(o);
        at = align_up(at + L->dynstr_sz, A);
    }

    if (L->nsym) {
        L->dynsym    = at;
        L->dynsym_sz = symsz * L->nsym;
        at = align_up(at + L->dynsym_sz, A);

        if (o->hash_sysv) {
            L->hash    = at;
            L->hash_sz = (2 + 1 + L->nsym) * 4;   /* nbucket=1, nchain=nsym */
            at = align_up(at + L->hash_sz, A);
        }
        if (o->hash_gnu) {
            size_t bloomw = (o->cls == 64) ? 8u : 4u;
            L->gnuhash    = at;
            L->gnuhash_sz = 4 * 4 + bloomw + 4 + (L->nsym - 1) * 4;
            at = align_up(at + L->gnuhash_sz, A);
        }
    }

    if (o->nverneeds) {
        L->versym    = at;
        L->versym_sz = 2 * L->nsym;
        at = align_up(at + L->versym_sz, A);

        L->verneed = at;
        for (size_t i = 0; i < o->nverneeds; i++)
            L->verneed_sz += VERNEED_SIZE + VERNAUX_SIZE * o->verneeds[i].nvers;
        at = align_up(at + L->verneed_sz, A);
    }

    if (dyn) {
        L->ndyn       = count_dyn(o);
        L->dynamic    = at;
        L->dynamic_sz = dynsz * L->ndyn;
        at = align_up(at + L->dynamic_sz, A);
    }

    if (o->nrodata) {
        L->rodata = at;
        for (size_t i = 0; i < o->nrodata; i++) L->rodata_sz += strlen(o->rodata[i]) + 1;
        at = align_up(at + L->rodata_sz, A);
    }

    if (o->emit_shdrs) {
        L->secdata = at;
        for (size_t i = 0; i < o->nsections; i++)
            L->secdata_sz = align_up(L->secdata_sz + o->sections[i].len, A);
        /* .shstrtab lives at the end of the section-data region */
        size_t shstr = 1;
        for (size_t i = 0; i < o->nsections; i++) shstr += strlen(o->sections[i].name) + 1;
        shstr += strlen(".shstrtab") + 1;
        L->secdata_sz += shstr;
        at = align_up(at + L->secdata_sz, A);

        size_t shsz = (o->cls == 64) ? SHDR64_SIZE : SHDR32_SIZE;
        L->shdr    = at;
        L->shdr_sz = shsz * (o->nsections + 2);   /* NULL + user + .shstrtab */
        at += L->shdr_sz;
    }

    if (o->pad_to > at) at = o->pad_to;
    L->total = at;
}

/* String offsets inside .dynstr, assigned in the same order dynstr is built. */
typedef struct {
    size_t soname, rpath, runpath;
    size_t *needed, *symname, *vnfile, **vnver;
} stroffs;

static void build_dynstr(const eg *o, bbuf *ds, stroffs *S)
{
    put8(ds, 0);
    S->soname = S->rpath = S->runpath = 0;
    if (o->soname) S->soname = bb_put_str(ds, o->soname);
    S->needed = (size_t *)xmalloc((o->nneeded ? o->nneeded : 1) * sizeof(size_t));
    for (size_t i = 0; i < o->nneeded; i++) S->needed[i] = bb_put_str(ds, o->needed[i]);
    if (o->rpath)   S->rpath   = bb_put_str(ds, o->rpath);
    if (o->runpath) S->runpath = bb_put_str(ds, o->runpath);
    S->symname = (size_t *)xmalloc((o->nsyms ? o->nsyms : 1) * sizeof(size_t));
    for (size_t i = 0; i < o->nsyms; i++) S->symname[i] = bb_put_str(ds, o->syms[i].name);
    S->vnfile = (size_t *)xmalloc((o->nverneeds ? o->nverneeds : 1) * sizeof(size_t));
    S->vnver  = (size_t **)xmalloc((o->nverneeds ? o->nverneeds : 1) * sizeof(size_t *));
    for (size_t i = 0; i < o->nverneeds; i++) {
        S->vnfile[i] = bb_put_str(ds, o->verneeds[i].file);
        size_t nv = o->verneeds[i].nvers;
        S->vnver[i] = (size_t *)xmalloc((nv ? nv : 1) * sizeof(size_t));
        for (size_t j = 0; j < nv; j++)
            S->vnver[i][j] = bb_put_str(ds, o->verneeds[i].vers[j]);
    }
}

static void free_stroffs(const eg *o, stroffs *S)
{
    free(S->needed); free(S->symname); free(S->vnfile);
    for (size_t i = 0; i < o->nverneeds; i++) free(S->vnver[i]);
    free(S->vnver);
}

static void put_phdr(bbuf *b, const eg *o, uint32_t type, uint32_t flags,
                     uint64_t offset, uint64_t vaddr, uint64_t filesz,
                     uint64_t memsz, uint64_t align)
{
    put32(b, o->be, type);
    if (o->cls == 64) {
        put32(b, o->be, flags);
        put64(b, o->be, offset);
        put64(b, o->be, vaddr);
        put64(b, o->be, vaddr);          /* p_paddr */
        put64(b, o->be, filesz);
        put64(b, o->be, memsz);
        put64(b, o->be, align);
    } else {
        put32(b, o->be, (uint32_t)offset);
        put32(b, o->be, (uint32_t)vaddr);
        put32(b, o->be, (uint32_t)vaddr);
        put32(b, o->be, (uint32_t)filesz);
        put32(b, o->be, (uint32_t)memsz);
        put32(b, o->be, flags);          /* ELF32 puts p_flags here */
        put32(b, o->be, (uint32_t)align);
    }
}

static void put_sym(bbuf *b, const eg *o, uint32_t name, uint8_t info,
                    uint16_t shndx, uint64_t value, uint64_t size)
{
    put32(b, o->be, name);
    if (o->cls == 64) {
        put8(b, info);
        put8(b, 0);                       /* st_other */
        put16(b, o->be, shndx);
        put64(b, o->be, value);
        put64(b, o->be, size);
    } else {
        put32(b, o->be, (uint32_t)value);
        put32(b, o->be, (uint32_t)size);
        put8(b, info);
        put8(b, 0);
        put16(b, o->be, shndx);
    }
}

static void put_dyn_entry(bbuf *b, const eg *o, uint64_t tag, uint64_t val)
{
    putw(b, o, tag);
    putw(b, o, val);
}

static void emit_dynamic(bbuf *b, const eg *o, const layout *L, const stroffs *S)
{
    uint64_t base = o->base;
    size_t symsz = (o->cls == 64) ? SYM64_SIZE : SYM32_SIZE;

    for (size_t i = 0; i < o->nneeded; i++)
        put_dyn_entry(b, o, DT_NEEDED, S->needed[i]);
    if (o->soname)  put_dyn_entry(b, o, DT_SONAME,  S->soname);
    if (o->rpath)   put_dyn_entry(b, o, DT_RPATH,   S->rpath);
    if (o->runpath) put_dyn_entry(b, o, DT_RUNPATH, S->runpath);

    put_dyn_entry(b, o, DT_STRTAB, base + L->dynstr);
    put_dyn_entry(b, o, DT_STRSZ,  L->dynstr_sz);

    if (o->nsyms) {
        put_dyn_entry(b, o, DT_SYMTAB, base + L->dynsym);
        put_dyn_entry(b, o, DT_SYMENT, symsz);
        if (o->hash_sysv) put_dyn_entry(b, o, DT_HASH,     base + L->hash);
        if (o->hash_gnu)  put_dyn_entry(b, o, DT_GNU_HASH, base + L->gnuhash);
    }

    if (o->nverneeds) {
        put_dyn_entry(b, o, DT_VERNEED,    base + L->verneed);
        put_dyn_entry(b, o, DT_VERNEEDNUM, o->nverneeds);
        put_dyn_entry(b, o, DT_VERSYM,     base + L->versym);
    }

    if (o->have_flags) {
        put_dyn_entry(b, o, DT_FLAGS,   o->dt_flags);
        put_dyn_entry(b, o, DT_FLAGS_1, o->dt_flags_1);
    }
    if (o->textrel) put_dyn_entry(b, o, DT_TEXTREL, 0);

    for (size_t i = 0; i < o->nextradyn; i++)
        put_dyn_entry(b, o, o->extradyn[i].tag, o->extradyn[i].val);

    put_dyn_entry(b, o, DT_NULL, 0);
}

uint8_t *eg_emit(eg *o, size_t *out_len)
{
    layout L;
    compute_layout(o, &L);

    bbuf ds = { NULL, 0, 0 };
    stroffs S;
    memset(&S, 0, sizeof(S));
    build_dynstr(o, &ds, &S);

    bbuf b = { NULL, 0, 0 };
    size_t A     = (o->cls == 64) ? 8u : 4u;
    size_t ehsz  = (o->cls == 64) ? EHDR64_SIZE : EHDR32_SIZE;
    size_t phsz  = (o->cls == 64) ? PHDR64_SIZE : PHDR32_SIZE;
    size_t shsz  = (o->cls == 64) ? SHDR64_SIZE : SHDR32_SIZE;
    size_t phnum = phnum_of(o);

    /* ---- ELF header ---- */
    put8(&b, ELFMAG0); put8(&b, ELFMAG1); put8(&b, ELFMAG2); put8(&b, ELFMAG3);
    put8(&b, (uint8_t)((o->cls == 64) ? ELFCLASS64 : ELFCLASS32));
    put8(&b, (uint8_t)(o->be ? ELFDATA2MSB : ELFDATA2LSB));
    put8(&b, EV_CURRENT);
    put8(&b, ELFOSABI_NONE);
    for (int i = EI_ABIVERSION; i < EI_NIDENT; i++) put8(&b, 0);

    put16(&b, o->be, o->type);
    put16(&b, o->be, o->machine);
    put32(&b, o->be, EV_CURRENT);
    putw(&b, o, o->entry);
    putw(&b, o, L.phdr);
    putw(&b, o, o->emit_shdrs ? L.shdr : 0);
    put32(&b, o->be, 0);                                   /* e_flags */
    put16(&b, o->be, (uint16_t)ehsz);
    put16(&b, o->be, (uint16_t)phsz);
    put16(&b, o->be, (uint16_t)phnum);
    put16(&b, o->be, (uint16_t)shsz);
    put16(&b, o->be, (uint16_t)(o->emit_shdrs ? o->nsections + 2 : 0));
    put16(&b, o->be, (uint16_t)(o->emit_shdrs ? o->nsections + 1 : 0));

    /* ---- program headers ---- */
    if (o->interp)
        put_phdr(&b, o, PT_INTERP, PF_R, L.interp, o->base + L.interp,
                 L.interp_sz, L.interp_sz, 1);

    put_phdr(&b, o, PT_LOAD, o->load_flags, 0, o->base, L.total, L.total, 0x1000);

    for (size_t i = 0; i < o->nloads; i++)
        put_phdr(&b, o, PT_LOAD, o->loads[i].flags,
                 o->loads[i].vaddr - o->base, o->loads[i].vaddr,
                 o->loads[i].filesz, o->loads[i].filesz, 0x1000);

    if (has_dynamic(o))
        put_phdr(&b, o, PT_DYNAMIC, PF_R | PF_W, L.dynamic, o->base + L.dynamic,
                 L.dynamic_sz, L.dynamic_sz, (uint64_t)A);

    if (o->relro) {
        size_t rstart = has_dynamic(o) ? L.dynamic : L.phdr;
        size_t rsize  = has_dynamic(o) ? L.dynamic_sz : L.phdr_sz;
        put_phdr(&b, o, PT_GNU_RELRO, PF_R, rstart, o->base + rstart, rsize, rsize, 1);
    }

    if (o->stack_present)
        put_phdr(&b, o, PT_GNU_STACK, o->stack_flags, 0, 0, 0, 0, 0x10);

    /* ---- body ---- */
    if (o->interp) {
        pad_to(&b, A);
        bb_put(&b, o->interp, L.interp_sz);
    }

    if (has_dynamic(o)) {
        pad_to(&b, A);
        bb_put(&b, ds.p, ds.len);
    }

    if (L.nsym) {
        pad_to(&b, A);
        put_sym(&b, o, 0, 0, SHN_UNDEF, 0, 0);            /* reserved sym 0 */
        for (size_t i = 0; i < o->nsyms; i++)
            put_sym(&b, o, (uint32_t)S.symname[i], o->syms[i].info,
                    o->syms[i].shndx, 0, 0);

        if (o->hash_sysv) {
            pad_to(&b, A);
            put32(&b, o->be, 1);                            /* nbucket */
            put32(&b, o->be, (uint32_t)L.nsym);             /* nchain  */
            put32(&b, o->be, 0);                            /* bucket[0] */
            for (size_t i = 0; i < L.nsym; i++) put32(&b, o->be, 0);
        }
        if (o->hash_gnu) {
            pad_to(&b, A);
            put32(&b, o->be, 1);                            /* nbuckets */
            put32(&b, o->be, 1);                            /* symoffset */
            put32(&b, o->be, 1);                            /* bloom_size */
            put32(&b, o->be, 0);                            /* bloom_shift */
            if (o->cls == 64) put64(&b, o->be, ~(uint64_t)0);
            else              put32(&b, o->be, ~(uint32_t)0);
            put32(&b, o->be, 1);                            /* bucket[0] = 1 */
            for (size_t i = 1; i < L.nsym; i++)
                put32(&b, o->be, (i + 1 == L.nsym) ? 1u : 0u);  /* LSB ends chain */
        }
    }

    if (o->nverneeds) {
        pad_to(&b, A);
        for (size_t i = 0; i < L.nsym; i++) {
            uint16_t v = VER_NDX_GLOBAL;
            if (i == 0) v = VER_NDX_LOCAL;
            else if (o->syms[i - 1].versym) v = o->syms[i - 1].versym;
            put16(&b, o->be, v);
        }

        pad_to(&b, A);
        for (size_t i = 0; i < o->nverneeds; i++) {
            size_t nv   = o->verneeds[i].nvers;
            int    last = (i + 1 == o->nverneeds);
            put16(&b, o->be, 1);                              /* vn_version */
            put16(&b, o->be, (uint16_t)nv);                   /* vn_cnt */
            put32(&b, o->be, (uint32_t)S.vnfile[i]);          /* vn_file */
            put32(&b, o->be, VERNEED_SIZE);                   /* vn_aux */
            put32(&b, o->be, last ? 0u : (uint32_t)(VERNEED_SIZE + VERNAUX_SIZE * nv));

            for (size_t j = 0; j < nv; j++) {
                put32(&b, o->be, 0);                          /* vna_hash */
                put16(&b, o->be, 0);                          /* vna_flags */
                put16(&b, o->be, (uint16_t)(j + 2));          /* vna_other */
                put32(&b, o->be, (uint32_t)S.vnver[i][j]);    /* vna_name */
                put32(&b, o->be, (j + 1 == nv) ? 0u : VERNAUX_SIZE);
            }
        }
    }

    if (has_dynamic(o)) {
        pad_to(&b, A);
        emit_dynamic(&b, o, &L, &S);
    }

    if (o->nrodata) {
        pad_to(&b, A);
        for (size_t i = 0; i < o->nrodata; i++)
            bb_put(&b, o->rodata[i], strlen(o->rodata[i]) + 1);
    }

    /* ---- sections ---- */
    size_t *secoff = NULL;
    size_t shstroff = 0;
    size_t *namoff = NULL;
    size_t shstrname = 0;
    if (o->emit_shdrs) {
        pad_to(&b, A);
        secoff = (size_t *)xmalloc((o->nsections ? o->nsections : 1) * sizeof(size_t));
        for (size_t i = 0; i < o->nsections; i++) {
            pad_to(&b, A);
            secoff[i] = b.len;
            if (o->sections[i].len) bb_put(&b, o->sections[i].data, o->sections[i].len);
        }
        shstroff = b.len;
        namoff = (size_t *)xmalloc((o->nsections ? o->nsections : 1) * sizeof(size_t));
        put8(&b, 0);
        for (size_t i = 0; i < o->nsections; i++) {
            namoff[i] = b.len - shstroff;
            bb_put(&b, o->sections[i].name, strlen(o->sections[i].name) + 1);
        }
        shstrname = b.len - shstroff;
        bb_put(&b, ".shstrtab", strlen(".shstrtab") + 1);
        size_t shstrsz = b.len - shstroff;

        pad_to(&b, A);
        size_t shdr_at = b.len;

        /* null section header */
        put32(&b, o->be, 0); put32(&b, o->be, SHT_NULL);
        putw(&b, o, 0); putw(&b, o, 0); putw(&b, o, 0); putw(&b, o, 0);
        put32(&b, o->be, 0); put32(&b, o->be, 0);
        putw(&b, o, 0); putw(&b, o, 0);

        for (size_t i = 0; i < o->nsections; i++) {
            put32(&b, o->be, (uint32_t)namoff[i]);
            put32(&b, o->be, o->sections[i].type);
            putw(&b, o, 0);                            /* sh_flags */
            putw(&b, o, o->base + secoff[i]);          /* sh_addr */
            putw(&b, o, secoff[i]);                    /* sh_offset */
            putw(&b, o, o->sections[i].len);           /* sh_size */
            put32(&b, o->be, 0); put32(&b, o->be, 0);  /* link, info */
            putw(&b, o, 1); putw(&b, o, 0);            /* addralign, entsize */
        }

        put32(&b, o->be, (uint32_t)shstrname);
        put32(&b, o->be, SHT_STRTAB);
        putw(&b, o, 0); putw(&b, o, 0);
        putw(&b, o, shstroff);
        putw(&b, o, shstrsz);
        put32(&b, o->be, 0); put32(&b, o->be, 0);
        putw(&b, o, 1); putw(&b, o, 0);

        L.shdr = shdr_at;                               /* authoritative */
    }

    while (b.len < L.total) put8(&b, 0);

    /* eg_off()/eg_size() report the emit we just did. */
    o->off[EG_OFF_EHDR]    = L.ehdr;    o->siz[EG_OFF_EHDR]    = ehsz;
    o->off[EG_OFF_PHDR]    = L.phdr;    o->siz[EG_OFF_PHDR]    = L.phdr_sz;
    o->off[EG_OFF_DYNAMIC] = L.dynamic; o->siz[EG_OFF_DYNAMIC] = L.dynamic_sz;
    o->off[EG_OFF_DYNSTR]  = L.dynstr;  o->siz[EG_OFF_DYNSTR]  = L.dynstr_sz;
    o->off[EG_OFF_VERNEED] = L.verneed; o->siz[EG_OFF_VERNEED] = L.verneed_sz;
    o->off[EG_OFF_DYNSYM]  = L.dynsym;  o->siz[EG_OFF_DYNSYM]  = L.dynsym_sz;
    o->off[EG_OFF_SHDR]    = o->emit_shdrs ? L.shdr : 0;
    o->siz[EG_OFF_SHDR]    = o->emit_shdrs ? L.shdr_sz : 0;
    o->off[EG_OFF_RODATA]  = L.rodata;  o->siz[EG_OFF_RODATA]  = L.rodata_sz;

    free(secoff);
    free(namoff);
    free(ds.p);
    free_stroffs(o, &S);

    if (out_len) *out_len = b.len;
    return b.p;
}

int eg_write(eg *o, const char *path)
{
    size_t len = 0;
    uint8_t *buf = eg_emit(o, &len);
    FILE *f = fopen(path, "wb");
    if (!f) { free(buf); return -1; }
    size_t n = fwrite(buf, 1, len, f);
    int rc = (n == len) ? 0 : -1;
    if (fclose(f) != 0) rc = -1;
    free(buf);
    return rc;
}

size_t eg_off (const eg *o, eg_part p) { return o->off[p]; }
size_t eg_size(const eg *o, eg_part p) { return o->siz[p]; }

/* --------------------------------------------------------------- pokes */

static void poke_check(size_t len, size_t off, size_t n)
{
    if (off > len || len - off < n) {
        fprintf(stderr, "mkelf: eg_poke out of range: off=%zu n=%zu len=%zu\n",
                off, n, len);
        abort();
    }
}

void eg_poke8(uint8_t *buf, size_t len, size_t off, uint8_t v)
{
    poke_check(len, off, 1);
    buf[off] = v;
}

void eg_poke16(uint8_t *buf, size_t len, size_t off, uint16_t v, int be)
{
    poke_check(len, off, 2);
    if (be) { buf[off] = (uint8_t)(v >> 8); buf[off + 1] = (uint8_t)v; }
    else    { buf[off] = (uint8_t)v; buf[off + 1] = (uint8_t)(v >> 8); }
}

void eg_poke32(uint8_t *buf, size_t len, size_t off, uint32_t v, int be)
{
    poke_check(len, off, 4);
    for (int i = 0; i < 4; i++) {
        unsigned sh = (unsigned)(be ? (3 - i) : i) * 8u;
        buf[off + (size_t)i] = (uint8_t)(v >> sh);
    }
}

void eg_poke64(uint8_t *buf, size_t len, size_t off, uint64_t v, int be)
{
    poke_check(len, off, 8);
    for (int i = 0; i < 8; i++) {
        unsigned sh = (unsigned)(be ? (7 - i) : i) * 8u;
        buf[off + (size_t)i] = (uint8_t)(v >> sh);
    }
}

/* ------------------------------------------------------------- presets */

eg *eg_preset_hybrid_ok(void)
{
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_set_interp(o, "/lib64/ld-linux-x86-64.so.2");
    eg_add_needed(o, "libc.so.6");
    eg_add_needed(o, "libm.so.6");
    static const char *const v[] = { "GLIBC_2.2.5", "GLIBC_2.28" };
    eg_add_verneed(o, "libc.so.6", v, 2);
    eg_add_dynsym(o, "printf", 2, ELF_ST_INFO(STB_GLOBAL, STT_FUNC), SHN_UNDEF);
    eg_add_dynsym(o, "fmod",   3, ELF_ST_INFO(STB_GLOBAL, STT_FUNC), SHN_UNDEF);
    eg_set_hash_style(o, 0, 1);
    eg_set_flags(o, DF_BIND_NOW, DF_1_NOW | DF_1_PIE);
    eg_set_gnu_relro(o, 1);
    eg_set_gnu_stack(o, 1, PF_R | PF_W);
    return o;
}

eg *eg_preset_static_ok(void)
{
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_set_flags(o, DF_BIND_NOW, DF_1_NOW | DF_1_PIE);
    eg_set_gnu_relro(o, 1);
    eg_set_gnu_stack(o, 1, PF_R | PF_W);
    return o;
}

eg *eg_preset_static_nopie(void)
{
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_EXEC);
    eg_set_gnu_stack(o, 1, PF_R | PF_W);
    return o;
}

eg *eg_preset_shared_lib(void)
{
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_set_soname(o, "libfoo.so.1");
    eg_add_needed(o, "libc.so.6");
    eg_set_flags(o, DF_BIND_NOW, DF_1_NOW);
    eg_set_gnu_relro(o, 1);
    eg_set_gnu_stack(o, 1, PF_R | PF_W);
    return o;
}

eg *eg_preset_module(void)
{
    /* A plugin as CMake actually builds one: a MODULE library, so no
     * DT_SONAME, and undefined symbols that only the loading executable can
     * satisfy.  See 04-REFERENCE-far2l.md §7.6 for why this preset exists. */
    eg *o = eg_new(64, EG_LE, EM_X86_64, ET_DYN);
    eg_add_needed(o, "libc.so.6");
    eg_add_dynsym(o, "WINPORT_ReadConsoleOutput", 0,
                  ELF_ST_INFO(STB_GLOBAL, STT_FUNC), SHN_UNDEF);
    eg_set_hash_style(o, 0, 1);
    eg_set_flags(o, DF_BIND_NOW, DF_1_NOW);
    eg_set_gnu_relro(o, 1);
    eg_set_gnu_stack(o, 1, PF_R | PF_W);
    return o;
}
