/* audit/audit.c — see audit/audit.h. */
#define _POSIX_C_SOURCE 200809L
#include "audit/audit.h"
#include "audit/checks.h"
#include "elf/image.h"
#include "elf/dynamic.h"
#include "elf/verneed.h"
#include "elf/symbols.h"
#include "elf/elf_const.h"
#include "util/limits.h"
#include "util/str.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/stat.h>

void ob_audit_options_init(ob_audit_options *opts) {
    memset(opts, 0, sizeof(*opts));
    opts->level = OB_LEVEL_1;
}

static const char *machine_name(uint16_t m, char *buf, size_t bufsz) {
    switch (m) {
    case EM_386:        return "x86";
    case EM_X86_64:      return "x86_64";
    case EM_ARM:         return "arm";
    case EM_AARCH64:     return "aarch64";
    case EM_MIPS:        return "mips";
    case EM_PPC:         return "ppc";
    case EM_PPC64:       return "ppc64";
    case EM_S390:        return "s390";
    case EM_RISCV:       return "riscv";
    case EM_LOONGARCH:   return "loongarch";
    default:
        snprintf(buf, bufsz, "0x%x", (unsigned)m);
        return buf;
    }
}

static const char *type_name(uint16_t t, char *buf, size_t bufsz) {
    switch (t) {
    case ET_NONE: return "ET_NONE";
    case ET_REL:  return "ET_REL";
    case ET_EXEC: return "ET_EXEC";
    case ET_DYN:  return "ET_DYN";
    case ET_CORE: return "ET_CORE";
    default:
        snprintf(buf, bufsz, "0x%x", (unsigned)t);
        return buf;
    }
}

static const char *profile_name(ob_profile p) {
    switch (p) {
    case OB_PROFILE_S: return "static";
    case OB_PROFILE_H: return "hybrid";
    case OB_PROFILE_M: return "module";
    case OB_PROFILE_U: return "universal";
    }
    return "?";
}

/* Splits `value` on ':' and adds every component (including empty ones —
 * an empty component is itself a fact about the file, flagged separately
 * by c_rpath.c's OB0043; the descriptive field should reflect what's
 * really there). */
static void split_and_add(ob_report *r, const char *value,
                           void (*add)(ob_report *, const char *)) {
    size_t len = strlen(value);
    size_t start = 0;
    for (size_t i = 0; i <= len; i++) {
        if (i != len && value[i] != ':') {
            continue;
        }
        char comp[ONEBIN_MAX_STRING + 1];
        size_t complen = i - start;
        size_t n = complen < sizeof(comp) - 1 ? complen : sizeof(comp) - 1;
        memcpy(comp, value + start, n);
        comp[n] = '\0';
        add(r, comp);
        start = i + 1;
    }
}

static void fatal_from_img_err(ob_report *r, ob_img_err e) {
    switch (e) {
    case OB_IMG_ERR_BAD_MAGIC:
        ob_report_add_finding(r, "OB0001", "elf.notelf", OB_SEV_FATAL, "",
                               "not an ELF file (bad magic)");
        return;
    case OB_IMG_ERR_BAD_CLASS:
        ob_report_add_finding(r, "OB0002", "elf.class", OB_SEV_FATAL, "EI_CLASS",
                               "invalid EI_CLASS byte");
        return;
    default:
        ob_report_add_finding(r, "OB0003", "elf.truncated", OB_SEV_FATAL, "ehdr",
                               ob_img_err_str(e));
        return;
    }
}

static ob_audit_status fatal(ob_report *out, const char *id, const char *check,
                              const char *subject, const char *message) {
    ob_report_add_finding(out, id, check, OB_SEV_FATAL, subject, message);
    ob_report_finalize(out, NULL, 0);
    return OB_AUDIT_FATAL;
}

ob_audit_status ob_audit_file(const ob_audit_options *opts, ob_report *out) {
    ob_report_init(out);
    ob_report_set_file(out, opts->file_path);
    ob_report_set_format(out, "elf");
    ob_report_set_level(out, opts->level);

    FILE *f = fopen(opts->file_path, "rb");
    if (!f) {
        char msg[256];
        snprintf(msg, sizeof(msg), "cannot open: %s", strerror(errno));
        return fatal(out, "OB0090", "io.open", opts->file_path, msg);
    }

    struct stat st;
    if (fstat(fileno(f), &st) != 0) {
        fclose(f);
        return fatal(out, "OB0090", "io.open", opts->file_path, "cannot stat file");
    }
    if (!S_ISREG(st.st_mode)) {
        fclose(f);
        return fatal(out, "OB0091", "io.nottype", opts->file_path,
                     "not a regular file");
    }
    if ((uint64_t)st.st_size > (uint64_t)ONEBIN_MAX_FILE) {
        fclose(f);
        char msg[128];
        snprintf(msg, sizeof(msg), "%lld bytes exceeds the %u byte limit",
                 (long long)st.st_size, (unsigned)ONEBIN_MAX_FILE);
        return fatal(out, "OB0092", "io.toolarge", opts->file_path, msg);
    }

    size_t size = (size_t)st.st_size;
    uint8_t *buf = malloc(size ? size : 1);
    if (!buf) {
        fclose(f);
        return fatal(out, "OB0093", "io.read", opts->file_path, "out of memory");
    }
    size_t rd = fread(buf, 1, size, f);
    fclose(f);
    if (rd != size) {
        free(buf);
        return fatal(out, "OB0093", "io.read", opts->file_path, "short read");
    }

    ob_image img;
    ob_img_err ie = ob_image_load(buf, size, &img);
    if (ie != OB_IMG_OK) {
        fatal_from_img_err(out, ie);
        ob_report_finalize(out, NULL, 0);
        free(buf);
        return OB_AUDIT_FATAL;
    }

    if (img.e_type == ET_REL || img.e_type == ET_CORE) {
        ob_report_add_finding(out, "OB0001", "elf.notelf", OB_SEV_FATAL, "",
                               "ET_REL/ET_CORE: this tool audits executables and shared objects only");
        ob_report_finalize(out, NULL, 0);
        ob_image_free(&img);
        free(buf);
        return OB_AUDIT_FATAL;
    }

    ob_dynamic dyn;
    ob_dynamic_load(&img, &dyn);
    ob_verneed vn;
    ob_verneed_load(&img, &dyn, &vn);
    ob_symbols syms;
    ob_symbols_count(&img, &dyn, &syms);

    char mbuf[16], tbuf[16];
    ob_report_set_class(out, img.buf.c64 ? 64 : 32);
    ob_report_set_endian(out, img.buf.be ? "big" : "little");
    ob_report_set_machine(out, machine_name(img.e_machine, mbuf, sizeof(mbuf)));
    ob_report_set_type(out, type_name(img.e_type, tbuf, sizeof(tbuf)));

    ob_check_ctx ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.img = &img;
    ctx.dyn = &dyn;
    ctx.verneed = &vn;
    ctx.syms = &syms;
    ctx.glibc_max = opts->glibc_max;
    ctx.allow = opts->allow;
    ctx.nallow = opts->nallow;
    ctx.level = opts->level;
    if (opts->profile_forced) {
        ctx.profile = opts->profile;
        ctx.profile_forced = 1;
    }
    ob_checks_resolve_profile(&ctx);

    ob_report_set_profile(out, profile_name(ctx.profile), opts->profile_forced ? "flag" : "auto");

    if (dyn.has_soname) {
        char soname[ONEBIN_MAX_STRING + 1];
        if (ob_dynamic_string(&img, &dyn, dyn.soname_stroff, soname, sizeof(soname)) == OB_STR_OK) {
            ob_report_set_soname(out, soname);
            ob_report_add_finding(out, "OB0005", "elf.shared", OB_SEV_INFO, soname,
                                   "shared object with a DT_SONAME");
        }
    }
    /* OB0004, 01-SPEC-audit.md §6.1: "If two PT_LOADs claim the same
     * address, the first wins. Emit OB0004 (info) noting the overlap." One
     * finding per offending later segment, subject is its starting vaddr. */
    for (size_t i = 0; i < img.nphdrs; i++) {
        if (img.phdrs[i].p_type != PT_LOAD) {
            continue;
        }
        for (size_t j = 0; j < i; j++) {
            if (img.phdrs[j].p_type != PT_LOAD) {
                continue;
            }
            uint64_t v = img.phdrs[i].p_vaddr;
            if (v >= img.phdrs[j].p_vaddr &&
                v - img.phdrs[j].p_vaddr < img.phdrs[j].p_filesz) {
                char subj[32];
                snprintf(subj, sizeof(subj), "0x%llx", (unsigned long long)v);
                ob_report_add_finding(out, "OB0004", "elf.overlap", OB_SEV_INFO, subj,
                                       "PT_LOAD claims an address an earlier PT_LOAD already maps; the earlier one wins");
                break;
            }
        }
    }
    for (size_t i = 0; i < img.nphdrs; i++) {
        if (img.phdrs[i].p_type == PT_INTERP) {
            char interp[ONEBIN_MAX_STRING + 1];
            if (ob_rdstr(&img.buf, (size_t)img.phdrs[i].p_offset, interp, sizeof(interp),
                         (size_t)img.phdrs[i].p_filesz) >= 0) {
                ob_report_set_interp(out, interp);
            }
            break;
        }
    }
    for (size_t i = 0; i < dyn.nneeded; i++) {
        char soname[ONEBIN_MAX_STRING + 1];
        if (ob_dynamic_string(&img, &dyn, dyn.needed[i], soname, sizeof(soname)) == OB_STR_OK) {
            ob_report_add_needed(out, soname);
        }
    }
    if (dyn.has_runpath) {
        char val[ONEBIN_MAX_STRING + 1];
        if (ob_dynamic_string(&img, &dyn, dyn.runpath_stroff, val, sizeof(val)) == OB_STR_OK) {
            split_and_add(out, val, ob_report_add_runpath);
        }
    }
    if (dyn.has_rpath) {
        char val[ONEBIN_MAX_STRING + 1];
        if (ob_dynamic_string(&img, &dyn, dyn.rpath_stroff, val, sizeof(val)) == OB_STR_OK) {
            split_and_add(out, val, ob_report_add_rpath);
        }
    }

    {
        char reqbuf[ONEBIN_MAX_STRING + 1];
        int found = ob_glibc_compute_max(&ctx, reqbuf, sizeof(reqbuf));
        const char *baseline = ctx.glibc_max ? ctx.glibc_max : OB_DEFAULT_GLIBC_MAX;
        ob_report_set_glibc(out, found ? reqbuf : NULL, baseline);
    }

    ob_check_needed(&ctx, out);
    ob_check_glibc(&ctx, out);
    ob_check_profile(&ctx, out);
    ob_check_rpath(&ctx, out);
    ob_check_harden(&ctx, out);
    ob_check_hygiene(&ctx, out);
    ob_check_host(&ctx, out);
    ob_check_meta(&ctx, out, opts->file_path);

    ob_report_finalize(out, opts->baseline, opts->strict);

    ob_verneed_free(&vn);
    ob_dynamic_free(&dyn);
    ob_image_free(&img);
    free(buf);

    return OB_AUDIT_OK;
}
