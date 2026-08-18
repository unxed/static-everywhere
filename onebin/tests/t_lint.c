/* t_lint.c — architecture rules enforced as tests, 03-TESTPLAN.md §5.7.
 * A test that reads the project's own source files and asserts ten rules
 * about them. Runs from onebin/'s own repo, not against fixtures.
 */
#define _POSIX_C_SOURCE 200809L
#include "test.h"

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

/* GCC's -Wformat-truncation cannot bound `files[i].path` (a fixed 512-byte
 * array reused across many call sites via a helper struct) tightly enough
 * and estimates a wildly pessimistic worst case for every %s here. Every
 * message buffer below is sized generously and every write goes through
 * snprintf, so truncation itself is harmless by construction — silencing
 * the false positive for this file only, not project-wide. */
#if defined(__GNUC__)
#pragma GCC diagnostic ignored "-Wformat-truncation"
#pragma GCC diagnostic ignored "-Wstringop-truncation"
#endif

#define MAX_FILES 256
#define MAX_LINE  4096

typedef struct {
    char path[512];
    char **lines;   /* owned, NUL-terminated, newline stripped */
    size_t nlines;
} src_file;

static char *xstrdup(const char *s) {
    size_t n = strlen(s);
    char *p = malloc(n + 1);
    if (!p) {
        abort();
    }
    memcpy(p, s, n + 1);
    return p;
}

/* Recursively collects every regular file under `dir` whose name ends in
 * .c or .h into `files`, up to MAX_FILES. Small, bounded, and only ever
 * run against this project's own src/ tree — not untrusted input. */
static void collect(const char *dir, src_file *files, size_t *nfiles) {
    DIR *d = opendir(dir);
    if (!d) {
        return;
    }
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) {
            continue;
        }
        char path[512];
        snprintf(path, sizeof(path), "%s/%s", dir, e->d_name);

        FILE *probe = fopen(path, "r");
        if (probe) {
            fclose(probe);
            size_t n = strlen(e->d_name);
            int is_c = n > 2 && strcmp(e->d_name + n - 2, ".c") == 0;
            int is_h = n > 2 && strcmp(e->d_name + n - 2, ".h") == 0;
            if ((is_c || is_h) && *nfiles < MAX_FILES) {
                strncpy(files[*nfiles].path, path, sizeof(files[*nfiles].path) - 1);
                files[*nfiles].path[sizeof(files[*nfiles].path) - 1] = '\0';
                (*nfiles)++;
                continue;
            }
        }
        collect(path, files, nfiles); /* a directory (or unreadable as a file) */
    }
    closedir(d);
}

static void load_lines(src_file *f) {
    FILE *fp = fopen(f->path, "r");
    if (!fp) {
        f->lines = NULL;
        f->nlines = 0;
        return;
    }
    size_t cap = 64;
    f->lines = malloc(cap * sizeof(char *));
    if (!f->lines) {
        abort();
    }
    f->nlines = 0;
    char buf[MAX_LINE];
    while (fgets(buf, sizeof(buf), fp)) {
        size_t n = strlen(buf);
        while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r')) {
            buf[--n] = '\0';
        }
        if (f->nlines == cap) {
            cap *= 2;
            char **p = realloc(f->lines, cap * sizeof(char *));
            if (!p) {
                abort();
            }
            f->lines = p;
        }
        f->lines[f->nlines++] = xstrdup(buf);
    }
    fclose(fp);
}

static void free_files(src_file *files, size_t n) {
    for (size_t i = 0; i < n; i++) {
        for (size_t j = 0; j < files[i].nlines; j++) {
            free(files[i].lines[j]);
        }
        free(files[i].lines);
    }
}

static int ends_with(const char *s, const char *suffix) {
    size_t ls = strlen(s), lx = strlen(suffix);
    return ls >= lx && strcmp(s + ls - lx, suffix) == 0;
}

static size_t load_all(src_file *files) {
    size_t n = 0;
    collect("src", files, &n);
    for (size_t i = 0; i < n; i++) {
        load_lines(&files[i]);
    }
    return n;
}

/* ---------------------------------------------------------------- rule 1 */

TEST(lint_no_raw_buf_indexing_outside_buf_c) {
    src_file files[MAX_FILES];
    size_t n = load_all(files);
    for (size_t i = 0; i < n; i++) {
        if (ends_with(files[i].path, "util/buf.c")) {
            continue;
        }
        for (size_t j = 0; j < files[i].nlines; j++) {
            if (strstr(files[i].lines[j], "b->p[") || strstr(files[i].lines[j], "buf->p[")) {
                char msg[1024];
                snprintf(msg, sizeof(msg), "%s:%zu: raw buffer indexing outside util/buf.c",
                         files[i].path, j + 1);
                test_fail(__FILE__, __LINE__, msg);
            }
        }
    }
    free_files(files, n);
}

/* ---------------------------------------------------------------- rule 2 */

TEST(lint_no_elf_struct_casts) {
    src_file files[MAX_FILES];
    size_t n = load_all(files);
    for (size_t i = 0; i < n; i++) {
        for (size_t j = 0; j < files[i].nlines; j++) {
            if (strstr(files[i].lines[j], "(Elf64_") || strstr(files[i].lines[j], "(Elf32_")) {
                char msg[1024];
                snprintf(msg, sizeof(msg), "%s:%zu: cast to Elf64_/Elf32_ struct type",
                         files[i].path, j + 1);
                test_fail(__FILE__, __LINE__, msg);
            }
        }
    }
    free_files(files, n);
}

/* ---------------------------------------------------------------- rule 3 */

TEST(lint_no_system_elf_h) {
    src_file files[MAX_FILES];
    size_t n = load_all(files);
    for (size_t i = 0; i < n; i++) {
        for (size_t j = 0; j < files[i].nlines; j++) {
            /* A real directive starts the line (after whitespace) — this
             * project's own elf_const.h explains the rule in a comment
             * containing the literal text "#include <elf.h>", which must
             * not itself trip the check. */
            const char *l = files[i].lines[j];
            while (*l == ' ' || *l == '\t') {
                l++;
            }
            if (strncmp(l, "#include <elf.h>", 17) == 0) {
                char msg[1024];
                snprintf(msg, sizeof(msg), "%s:%zu: #include <elf.h>", files[i].path, j + 1);
                test_fail(__FILE__, __LINE__, msg);
            }
        }
    }
    free_files(files, n);
}

/* ---------------------------------------------------------------- rule 4 */

TEST(lint_no_mmap) {
    src_file files[MAX_FILES];
    size_t n = load_all(files);
    for (size_t i = 0; i < n; i++) {
        for (size_t j = 0; j < files[i].nlines; j++) {
            if (strstr(files[i].lines[j], "mmap(")) {
                char msg[1024];
                snprintf(msg, sizeof(msg), "%s:%zu: mmap( — 01-SPEC-audit.md §3.2 forbids it",
                         files[i].path, j + 1);
                test_fail(__FILE__, __LINE__, msg);
            }
        }
    }
    free_files(files, n);
}

/* ---------------------------------------------------------------- rule 5 */

TEST(lint_no_unsafe_stdlib_calls) {
    static const char *const banned[] = {
        "strcpy(", "strcat(", "sprintf(", "gets(", "alloca(",
    };
    src_file files[MAX_FILES];
    size_t n = load_all(files);
    for (size_t i = 0; i < n; i++) {
        for (size_t j = 0; j < files[i].nlines; j++) {
            for (size_t k = 0; k < sizeof(banned) / sizeof(banned[0]); k++) {
                const char *l = files[i].lines[j];
                const char *hit = strstr(l, banned[k]);
                /* A word-boundary check: "fgets(" must not trip "gets(".
                 * The character immediately before the match, if any, must
                 * not be an identifier character. */
                while (hit) {
                    int boundary_ok = (hit == l) ||
                        !(isalnum((unsigned char)hit[-1]) || hit[-1] == '_');
                    if (boundary_ok) {
                        char msg[1024];
                        snprintf(msg, sizeof(msg), "%s:%zu: banned call %s",
                                 files[i].path, j + 1, banned[k]);
                        test_fail(__FILE__, __LINE__, msg);
                    }
                    hit = strstr(hit + 1, banned[k]);
                }
            }
        }
    }
    free_files(files, n);
}

/* ---------------------------------------------------------------- rule 6 */

TEST(lint_malloc_family_has_nearby_null_check) {
    static const char *const allocs[] = { "malloc(", "calloc(", "realloc(" };
    src_file files[MAX_FILES];
    size_t n = load_all(files);
    for (size_t i = 0; i < n; i++) {
        for (size_t j = 0; j < files[i].nlines; j++) {
            int is_alloc = 0;
            for (size_t k = 0; k < 3; k++) {
                if (strstr(files[i].lines[j], allocs[k])) {
                    is_alloc = 1;
                    break;
                }
            }
            if (!is_alloc) {
                continue;
            }
            int found_check = 0;
            for (size_t d = 0; d <= 3 && j + d < files[i].nlines; d++) {
                if (strstr(files[i].lines[j + d], "if (!") ||
                    strstr(files[i].lines[j + d], "if(!")) {
                    found_check = 1;
                    break;
                }
            }
            if (!found_check) {
                char msg[1024];
                snprintf(msg, sizeof(msg),
                         "%s:%zu: allocation with no NULL check within 3 lines",
                         files[i].path, j + 1);
                test_fail(__FILE__, __LINE__, msg);
            }
        }
    }
    free_files(files, n);
}

/* ---------------------------------------------------------------- rule 7 */

TEST(lint_no_unowned_todo_fixme) {
    src_file files[MAX_FILES];
    size_t n = load_all(files);
    for (size_t i = 0; i < n; i++) {
        for (size_t j = 0; j < files[i].nlines; j++) {
            const char *l = files[i].lines[j];
            const char *hit = strstr(l, "TODO");
            if (!hit) {
                hit = strstr(l, "FIXME");
            }
            if (hit && !strchr(hit, '(')) {
                char msg[1024];
                snprintf(msg, sizeof(msg), "%s:%zu: TODO/FIXME with no owner in parentheses",
                         files[i].path, j + 1);
                test_fail(__FILE__, __LINE__, msg);
            }
        }
    }
    free_files(files, n);
}

/* -------------------------------------------------------------- rules 8/9 */

/* Every ID from 01-SPEC-audit.md §8's registry, plus OB0100/OB0101, which
 * are documented in §9.4/§12 but live outside that table. OB0035 is a
 * deliberate, documented exception (onebin/NOTES.md): implementing it as
 * an unconditional fallback would violate 03-TESTPLAN.md §4.3 #1's
 * false-positive requirement, so it is allowlisted here rather than faked
 * into existence just to satisfy this rule. */
static const char *const SPEC_IDS[] = {
    "OB0001", "OB0002", "OB0003", "OB0004", "OB0005",
    "OB0010", "OB0011", "OB0012", "OB0013",
    "OB0020", "OB0021", "OB0022", "OB0023", "OB0024", "OB0025",
    "OB0030", "OB0031", "OB0032", "OB0033", "OB0034", "OB0035",
    "OB0036", "OB0037", "OB0038", "OB0039",
    "OB0040", "OB0041", "OB0042", "OB0043",
    "OB0050", "OB0051", "OB0052", "OB0053", "OB0054", "OB0055", "OB0056",
    "OB0060", "OB0061", "OB0062", "OB0063",
    "OB0070", "OB0071",
    "OB0080",
    "OB0090", "OB0091", "OB0092", "OB0093",
    "OB0100", "OB0101",
};
#define N_SPEC_IDS (sizeof(SPEC_IDS) / sizeof(SPEC_IDS[0]))
static const char *const ID_NOT_REQUIRED_IN_SRC[] = { "OB0035" };

static int is_spec_id(const char *s) {
    for (size_t i = 0; i < N_SPEC_IDS; i++) {
        if (strcmp(s, SPEC_IDS[i]) == 0) {
            return 1;
        }
    }
    return 0;
}
static int is_exempt(const char *s) {
    for (size_t i = 0; i < sizeof(ID_NOT_REQUIRED_IN_SRC) / sizeof(ID_NOT_REQUIRED_IN_SRC[0]); i++) {
        if (strcmp(s, ID_NOT_REQUIRED_IN_SRC[i]) == 0) {
            return 1;
        }
    }
    return 0;
}

/* Finds `"OB` followed by exactly 4 digits then `"` in `line`, writing it
 * (without quotes) to `out` (7 bytes). Returns a pointer just past the
 * match in `line` to resume scanning for more, or NULL if none found. */
static const char *find_ob_id(const char *line, char *out) {
    const char *p = line;
    while ((p = strstr(p, "\"OB")) != NULL) {
        const char *digits = p + 3;
        int ok = 1;
        for (int k = 0; k < 4; k++) {
            if (digits[k] < '0' || digits[k] > '9') {
                ok = 0;
                break;
            }
        }
        if (ok && digits[4] == '"') {
            memcpy(out, p + 1, 6);
            out[6] = '\0';
            return digits + 5;
        }
        p += 3;
    }
    return NULL;
}

TEST(lint_every_spec_id_appears_in_src) {
    src_file files[MAX_FILES];
    size_t n = load_all(files);
    int seen[N_SPEC_IDS];
    memset(seen, 0, sizeof(seen));

    for (size_t i = 0; i < n; i++) {
        for (size_t j = 0; j < files[i].nlines; j++) {
            const char *cursor = files[i].lines[j];
            char id[8];
            while ((cursor = find_ob_id(cursor, id)) != NULL) {
                for (size_t k = 0; k < N_SPEC_IDS; k++) {
                    if (strcmp(id, SPEC_IDS[k]) == 0) {
                        seen[k] = 1;
                    }
                }
            }
        }
    }

    for (size_t k = 0; k < N_SPEC_IDS; k++) {
        if (!seen[k] && !is_exempt(SPEC_IDS[k])) {
            char msg[128];
            snprintf(msg, sizeof(msg), "%s is in 01-SPEC-audit.md but never appears in src/",
                     SPEC_IDS[k]);
            test_fail(__FILE__, __LINE__, msg);
        }
    }
    free_files(files, n);
}

TEST(lint_no_invented_ids_in_src) {
    src_file files[MAX_FILES];
    size_t n = load_all(files);

    for (size_t i = 0; i < n; i++) {
        for (size_t j = 0; j < files[i].nlines; j++) {
            const char *cursor = files[i].lines[j];
            char id[8];
            while ((cursor = find_ob_id(cursor, id)) != NULL) {
                if (!is_spec_id(id)) {
                    char msg[1024];
                    snprintf(msg, sizeof(msg),
                             "%s:%zu: %s is used but not in 01-SPEC-audit.md's registry",
                             files[i].path, j + 1, id);
                    test_fail(__FILE__, __LINE__, msg);
                }
            }
        }
    }
    free_files(files, n);
}

/* --------------------------------------------------------------- rule 10 */

TEST(lint_every_src_c_file_is_in_makefile) {
    src_file files[MAX_FILES];
    size_t n = load_all(files);

    FILE *mf = fopen("Makefile", "r");
    ASSERT_NOT_NULL(mf);
    char *makefile_text = malloc(1);
    if (!makefile_text) {
        abort();
    }
    size_t total = 0;
    makefile_text[0] = '\0';
    char buf[4096];
    size_t rd;
    while ((rd = fread(buf, 1, sizeof(buf), mf)) > 0) {
        char *p = realloc(makefile_text, total + rd + 1);
        if (!p) {
            abort();
        }
        makefile_text = p;
        memcpy(makefile_text + total, buf, rd);
        total += rd;
        makefile_text[total] = '\0';
    }
    fclose(mf);

    for (size_t i = 0; i < n; i++) {
        if (!ends_with(files[i].path, ".c")) {
            continue;
        }
        if (!strstr(makefile_text, files[i].path)) {
            char msg[1024];
            snprintf(msg, sizeof(msg), "%s is not referenced by Makefile", files[i].path);
            free(makefile_text);
            test_fail(__FILE__, __LINE__, msg);
        }
    }
    free(makefile_text);
    free_files(files, n);
}
