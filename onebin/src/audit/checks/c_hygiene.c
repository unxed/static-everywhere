/* audit/checks/c_hygiene.c — 01-SPEC-audit.md §7.6. 00-AGENT-TASK.md Task 8.
 *
 * Two independent halves: the string scanner drives OB0060/OB0061, and a
 * small local section-header scan (the one place besides elf/symbols.c's
 * SHT_DYNSYM lookup that this project reads the section-header array —
 * still "optional bonus", 02-REFERENCE-elf.md §1, and still fine to be
 * absent) drives OB0062/OB0063.
 */
#include "audit/checks.h"
#include "elf/strings.h"
#include "util/limits.h"

#include <stdio.h>
#include <string.h>

#define OB0060_CAP 10

typedef struct {
    ob_report *r;
    size_t     ob0060_reported;
    size_t     ob0060_total;
} scan_state;

static const char *const BUILD_PREFIXES[] = {
    "/home/", "/root/", "/build/", "/Users/", "/tmp/", "/var/tmp/",
};
#define N_BUILD_PREFIXES (sizeof(BUILD_PREFIXES) / sizeof(BUILD_PREFIXES[0]))

static const char *const TOOLCHAIN_SUBSTRINGS[] = {
    "/usr/lib/x86_64-linux-gnu/", "/usr/lib/aarch64-linux-gnu/",
    "/usr/lib64/", "/nix/store/", "/opt/rh/",
};
#define N_TOOLCHAIN_SUBSTRINGS (sizeof(TOOLCHAIN_SUBSTRINGS) / sizeof(TOOLCHAIN_SUBSTRINGS[0]))

static int starts_with(const char *s, size_t len, const char *prefix) {
    size_t plen = strlen(prefix);
    return len >= plen && memcmp(s, prefix, plen) == 0;
}

static int contains(const char *s, size_t len, const char *needle) {
    size_t nlen = strlen(needle);
    if (nlen == 0 || len < nlen) {
        return 0;
    }
    for (size_t i = 0; i + nlen <= len; i++) {
        if (memcmp(s + i, needle, nlen) == 0) {
            return 1;
        }
    }
    return 0;
}

static void hygiene_cb(const char *s, size_t len, size_t off, void *user) {
    (void)off;
    scan_state *st = (scan_state *)user;

    for (size_t i = 0; i < N_BUILD_PREFIXES; i++) {
        if (starts_with(s, len, BUILD_PREFIXES[i])) {
            st->ob0060_total++;
            if (st->ob0060_reported < OB0060_CAP) {
                /* subject truncated to 120 characters, per §7.6 */
                char subj[121];
                size_t n = len < 120 ? len : 120;
                memcpy(subj, s, n);
                subj[n] = '\0';
                ob_report_add_finding(st->r, "OB0060", "hygiene.buildpath", OB_SEV_WARN, subj,
                                       "embedded build-time path; use -ffile-prefix-map to strip it");
                st->ob0060_reported++;
            }
            break; /* one prefix match is enough for this string */
        }
    }

    for (size_t i = 0; i < N_TOOLCHAIN_SUBSTRINGS; i++) {
        if (contains(s, len, TOOLCHAIN_SUBSTRINGS[i])) {
            char subj[ONEBIN_MAX_STRING + 1];
            size_t n = len < ONEBIN_MAX_STRING ? len : ONEBIN_MAX_STRING;
            memcpy(subj, s, n);
            subj[n] = '\0';
            ob_report_add_finding(st->r, "OB0061", "hygiene.toolchainpath", OB_SEV_WARN, subj,
                                   "embedded host-toolchain path");
            break;
        }
    }
}

/* ---- section headers: .debug_* total size, .gnu_debuglink presence ----- */

static void scan_sections(const ob_check_ctx *ctx, ob_report *r) {
    const ob_image *img = ctx->img;
    if (img->e_shoff == 0 || img->e_shnum == 0 || img->e_shentsize == 0 ||
        img->e_shstrndx >= img->e_shnum) {
        return; /* no section headers at all: §4.6 #12, no crash, no finding */
    }
    if (img->e_shoff > (uint64_t)SIZE_MAX) {
        return;
    }
    size_t base = (size_t)img->e_shoff;
    size_t entsz = img->e_shentsize;
    size_t shnum = img->e_shnum;
    if (shnum > ONEBIN_MAX_SHNUM) {
        shnum = ONEBIN_MAX_SHNUM;
    }
    int c64 = img->buf.c64;

    /* the string-table section's own sh_offset/sh_size */
    uint64_t str_at64 = (uint64_t)base + (uint64_t)img->e_shstrndx * (uint64_t)entsz;
    if (str_at64 > (uint64_t)SIZE_MAX) {
        return;
    }
    size_t str_at = (size_t)str_at64;
    uint64_t shstr_off = 0, shstr_size = 0;
    if (c64) {
        if (ob_rd64(&img->buf, str_at + 24, &shstr_off) != 0) return;
        if (ob_rd64(&img->buf, str_at + 32, &shstr_size) != 0) return;
    } else {
        uint32_t off32 = 0, sz32 = 0;
        if (ob_rd32(&img->buf, str_at + 16, &off32) != 0) return;
        if (ob_rd32(&img->buf, str_at + 20, &sz32) != 0) return;
        shstr_off = off32;
        shstr_size = sz32;
    }
    if (shstr_off > (uint64_t)SIZE_MAX) {
        return;
    }

    uint64_t debug_total = 0;
    int has_debuglink = 0;

    for (size_t i = 0; i < shnum; i++) {
        uint64_t at64 = (uint64_t)base + (uint64_t)i * (uint64_t)entsz;
        if (at64 > (uint64_t)SIZE_MAX) {
            break;
        }
        size_t at = (size_t)at64;

        uint32_t name_off = 0;
        if (ob_rd32(&img->buf, at + 0, &name_off) != 0) {
            continue;
        }
        uint64_t sh_size = 0;
        if (c64) {
            if (ob_rd64(&img->buf, at + 32, &sh_size) != 0) continue;
        } else {
            uint32_t sz32 = 0;
            if (ob_rd32(&img->buf, at + 20, &sz32) != 0) continue;
            sh_size = sz32;
        }

        if ((uint64_t)name_off >= shstr_size) {
            continue;
        }
        uint64_t nameoff64 = shstr_off + name_off;
        if (nameoff64 > (uint64_t)SIZE_MAX) {
            continue;
        }
        char name[256];
        if (ob_rdstr(&img->buf, (size_t)nameoff64, name, sizeof(name),
                      (size_t)(shstr_size - name_off)) < 0) {
            continue;
        }

        if (strncmp(name, ".debug_", 7) == 0) {
            debug_total += sh_size;
        } else if (strcmp(name, ".gnu_debuglink") == 0) {
            has_debuglink = 1;
        }
    }

    if (debug_total > 0) {
        char msg[96];
        snprintf(msg, sizeof(msg), "debug info not stripped (%llu bytes total)",
                 (unsigned long long)debug_total);
        ob_report_add_finding(r, "OB0062", "hygiene.debuginfo", OB_SEV_INFO, "", msg);
    }
    if (has_debuglink) {
        ob_report_add_finding(r, "OB0063", "hygiene.debuglink", OB_SEV_INFO, "",
                               "stripped with a separate .gnu_debuglink symbol file");
    }
}

void ob_check_hygiene(const ob_check_ctx *ctx, ob_report *r) {
    if (!ctx || !ctx->img || !r) {
        return;
    }

    scan_state st = { r, 0, 0 };
    ob_strings_scan(&ctx->img->buf, hygiene_cb, &st);

    if (st.ob0060_total > OB0060_CAP) {
        char msg[96];
        snprintf(msg, sizeof(msg), "%zu build-path strings total; showing the first %d",
                 st.ob0060_total, OB0060_CAP);
        ob_report_add_finding(r, "OB0060", "hygiene.buildpath", OB_SEV_WARN, "", msg);
    }

    scan_sections(ctx, r);
}
