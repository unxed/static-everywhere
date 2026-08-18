/* fuzz.c — deterministic mutation fuzzer, 03-TESTPLAN.md §6.
 * 00-AGENT-TASK.md Task 10.
 *
 * Runs entirely in-process against the in-memory parsing+checks pipeline
 * (elf/image -> elf/dynamic -> elf/verneed -> elf/symbols -> every check
 * function), not by spawning the built binary, so ASan/UBSan see
 * everything. audit/audit.c's file-handling is comparatively trivial and
 * already covered by tests/t_audit.c; what needs fuzzing is the parser.
 *
 * Build/run: `make fuzz` (20000 iterations) or `make fuzz FUZZ_ITERS=N`.
 * Reproduce a specific failure: `./build/fuzz --seed S --iters N`.
 */
#define _POSIX_C_SOURCE 200809L
#include "mkelf.h"
#include "elf/elf_const.h"
#include "elf/image.h"
#include "elf/dynamic.h"
#include "elf/verneed.h"
#include "elf/symbols.h"
#include "elf/strings.h"
#include "audit/checks.h"

#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* ---- the exact PRNG the spec requires, for cross-machine reproducibility */
static uint64_t s;
static uint64_t next(void) {
    s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s;
}
static uint64_t next_range(uint64_t n) {
    return n ? next() % n : 0;
}

/* ---- corpus: every preset the generator ships, plus a handful of manual
 * class/endian variants (mkelf's presets are not class/endian-parameterised
 * — extending them to be is out of this task's scope; the manual variants
 * below cover the structural diversity that matters: ELF32/64 x LE/BE). */
typedef struct { uint8_t *data; size_t len; } blob;

static blob emit_of(eg *o) {
    blob b;
    b.data = eg_emit(o, &b.len);
    return b;
}

static size_t build_corpus(blob **out) {
    size_t cap = 32, n = 0;
    blob *c = malloc(cap * sizeof(*c));

    eg *(*presets[])(void) = {
        eg_preset_hybrid_ok, eg_preset_static_ok, eg_preset_static_nopie,
        eg_preset_shared_lib, eg_preset_module,
    };
    for (size_t i = 0; i < sizeof(presets) / sizeof(presets[0]); i++) {
        eg *o = presets[i]();
        c[n++] = emit_of(o);
        eg_free(o);
    }

    int classes[2] = { 32, 64 };
    int endians[2] = { EG_LE, EG_BE };
    for (int ci = 0; ci < 2; ci++) {
        for (int ei = 0; ei < 2; ei++) {
            eg *o = eg_new(classes[ci], endians[ei],
                            classes[ci] == 64 ? EM_X86_64 : EM_386, ET_DYN);
            eg_add_needed(o, "libc.so.6");
            static const char *const v[] = { "GLIBC_2.2.5", "GLIBC_2.28" };
            eg_add_verneed(o, "libc.so.6", v, 2);
            eg_add_dynsym(o, "printf", 3, ELF_ST_INFO(STB_GLOBAL, STT_FUNC), SHN_UNDEF);
            eg_set_hash_style(o, 1, 1);
            eg_set_gnu_relro(o, 1);
            eg_set_flags(o, 0, DF_1_NOW | DF_1_PIE);
            eg_set_gnu_stack(o, 1, PF_R | PF_W);
            if (n == cap) { cap *= 2; c = realloc(c, cap * sizeof(*c)); }
            c[n++] = emit_of(o);
            eg_free(o);
        }
    }

    *out = c;
    return n;
}

/* ---- mutations, 03-TESTPLAN.md §6, chosen by next() % 6 -------------- */

static void mutate(uint8_t *data, size_t *len, size_t cap, const blob *corpus, size_t ncorpus) {
    if (*len == 0) {
        return;
    }
    switch (next_range(6)) {
    case 0: { /* flip a random bit */
        size_t byte = next_range(*len);
        int bit = (int)next_range(8);
        data[byte] ^= (uint8_t)(1u << bit);
        break;
    }
    case 1: { /* overwrite a random byte */
        size_t byte = next_range(*len);
        uint64_t choice = next_range(3);
        data[byte] = choice == 0 ? 0x00 : choice == 1 ? 0xFF : (uint8_t)next();
        break;
    }
    case 2: { /* truncate at a random offset */
        size_t off = next_range(*len);
        if (off > 0) {
            *len = off;
        }
        break;
    }
    case 3: { /* overwrite an aligned field with a boundary value */
        size_t width = next_range(2) ? 8u : 4u;
        if (*len < width) {
            break;
        }
        size_t off = next_range(*len - width + 1);
        off -= off % width;
        uint64_t choices[] = { 0, 1, 0x7FFFFFFFu, UINT32_MAX, UINT64_MAX };
        uint64_t v = choices[next_range(sizeof(choices) / sizeof(choices[0]))];
        for (size_t i = 0; i < width && off + i < *len; i++) {
            data[off + i] = (uint8_t)(v >> (8 * i));
        }
        break;
    }
    case 4: { /* splice another corpus entry in at a random offset */
        if (ncorpus == 0) {
            break;
        }
        const blob *other = &corpus[next_range(ncorpus)];
        size_t off = next_range(*len);
        size_t room = cap - off;
        size_t n = other->len < room ? other->len : room;
        memcpy(data + off, other->data, n);
        if (off + n > *len) {
            *len = off + n;
        }
        break;
    }
    case 5: { /* duplicate a random 16-byte record over the next 16 bytes */
        if (*len < 32) {
            break;
        }
        size_t src = next_range(*len - 16);
        size_t dst = next_range(*len - 16);
        uint8_t tmp[16];
        memcpy(tmp, data + src, 16);
        memcpy(data + dst, tmp, 16);
        break;
    }
    default:
        break;
    }
}

/* ---- one fuzz target iteration: parse, then run every check -------- */

static void run_one(const uint8_t *data, size_t len) {
    ob_image img;
    if (ob_image_load(data, len, &img) != OB_IMG_OK) {
        return;
    }
    ob_dynamic dyn;
    ob_dynamic_load(&img, &dyn);
    ob_verneed vn;
    ob_verneed_load(&img, &dyn, &vn);
    ob_symbols syms;
    ob_symbols_count(&img, &dyn, &syms);
    for (size_t i = 0; i < syms.count && i < 64; i++) {
        ob_sym_entry se;
        ob_symbols_at(&img, &dyn, &syms, i, &se);
    }

    ob_check_ctx ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.img = &img;
    ctx.dyn = &dyn;
    ctx.verneed = &vn;
    ctx.syms = &syms;
    ctx.level = OB_LEVEL_1;
    ob_checks_resolve_profile(&ctx);

    ob_report r;
    ob_report_init(&r);
    ob_check_needed(&ctx, &r);
    ob_check_glibc(&ctx, &r);
    ob_check_profile(&ctx, &r);
    ob_check_rpath(&ctx, &r);
    ob_check_harden(&ctx, &r);
    ob_check_hygiene(&ctx, &r);
    ob_check_host(&ctx, &r);
    ob_report_finalize(&r, NULL, 0);

    ob_report_free(&r);
    ob_verneed_free(&vn);
    ob_dynamic_free(&dyn);
    ob_image_free(&img);
}

/* ---- crash/timeout capture ------------------------------------------- */

static const uint8_t *g_cur_data;
static size_t g_cur_len;
static uint64_t g_seed, g_iter;

static void dump_and_die(const char *why) {
    char path[128];
    snprintf(path, sizeof(path), "build/fuzz-crash-%llu-%llu.bin",
             (unsigned long long)g_seed, (unsigned long long)g_iter);
    FILE *f = fopen(path, "wb");
    if (f) {
        fwrite(g_cur_data, 1, g_cur_len, f);
        fclose(f);
    }
    fprintf(stderr, "\nFUZZ FAILURE: %s\n", why);
    fprintf(stderr, "input saved to %s (%zu bytes)\n", path, g_cur_len);
    fprintf(stderr, "reproduce with: ./build/fuzz --seed %llu --iters %llu\n",
            (unsigned long long)g_seed, (unsigned long long)g_iter + 1);
    _exit(1);
}

static void on_signal(int sig) {
    dump_and_die(sig == SIGALRM ? "timeout" : strsignal(sig));
}

int main(int argc, char **argv) {
    uint64_t iters = 20000;
    s = 1;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--seed") == 0 && i + 1 < argc) {
            s = strtoull(argv[++i], NULL, 10);
        } else if (strcmp(argv[i], "--iters") == 0 && i + 1 < argc) {
            iters = strtoull(argv[++i], NULL, 10);
        }
    }
    g_seed = s;
    if (s == 0) {
        s = 1; /* the xorshift PRNG is fixed at 0 forever if seeded with 0 */
    }

    signal(SIGSEGV, on_signal);
    signal(SIGABRT, on_signal);
    signal(SIGBUS, on_signal);
    signal(SIGFPE, on_signal);
    signal(SIGALRM, on_signal);

    blob *corpus;
    size_t ncorpus = build_corpus(&corpus);
    fprintf(stderr, "fuzz: %zu corpus entries, seed=%llu, iters=%llu\n",
            ncorpus, (unsigned long long)g_seed, (unsigned long long)iters);

    size_t cap = 1 << 20; /* 1 MiB working buffer, plenty for these fixtures */
    uint8_t *work = malloc(cap);

    for (uint64_t it = 0; it < iters; it++) {
        g_iter = it;
        const blob *base = &corpus[next_range(ncorpus)];
        size_t len = base->len < cap ? base->len : cap;
        memcpy(work, base->data, len);
        mutate(work, &len, cap, corpus, ncorpus);

        g_cur_data = work;
        g_cur_len = len;

        alarm(2);
        run_one(work, len);
        alarm(0);
    }

    fprintf(stderr, "fuzz: %llu iterations clean\n", (unsigned long long)iters);
    for (size_t i = 0; i < ncorpus; i++) {
        free(corpus[i].data);
    }
    free(corpus);
    free(work);
    return 0;
}
