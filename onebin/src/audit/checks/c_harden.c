/* audit/checks/c_harden.c — 01-SPEC-audit.md §7.5. 00-AGENT-TASK.md Task 8. */
#include "audit/checks.h"
#include "elf/elf_const.h"

void ob_check_harden(const ob_check_ctx *ctx, ob_report *r) {
    if (!ctx || !ctx->img || !ctx->dyn || !r) {
        return;
    }
    const ob_image *img = ctx->img;
    const ob_dynamic *dyn = ctx->dyn;

    if (!dyn->has_dynamic) {
        /* "OB0050 and OB0051 are skipped entirely when there is no
         * PT_DYNAMIC ... skipping must be visible": OB0056. Everything
         * else in this file (GNU_STACK, TEXTREL, the Profile H ET_EXEC
         * check) is independent of PT_DYNAMIC's presence and still runs;
         * DT_TEXTREL/DT_FLAGS simply can't be set without PT_DYNAMIC
         * either, so those conditions degrade to "false" harmlessly rather
         * than needing an explicit skip of their own. */
        ob_report_add_finding(r, "OB0056", "harden.skipped_no_dynamic", OB_SEV_INFO, "",
                               "no PT_DYNAMIC: RELRO and BIND_NOW checks are not applicable to a fully static binary");
    } else {
        int has_relro = 0;
        for (size_t i = 0; i < img->nphdrs; i++) {
            if (img->phdrs[i].p_type == PT_GNU_RELRO) {
                has_relro = 1;
                break;
            }
        }
        if (!has_relro) {
            ob_report_add_finding(r, "OB0050", "harden.relro", OB_SEV_ERROR, "",
                                   "no PT_GNU_RELRO segment; link with -Wl,-z,relro");
        }

        int bind_now = dyn->has_bind_now ||
                        (dyn->flags & DF_BIND_NOW) ||
                        (dyn->flags_1 & DF_1_NOW);
        if (!bind_now) {
            ob_report_add_finding(r, "OB0051", "harden.bindnow", OB_SEV_ERROR, "",
                                   "no BIND_NOW; link with -Wl,-z,now");
        }
    }

    int has_stack = 0, stack_exec = 0;
    for (size_t i = 0; i < img->nphdrs; i++) {
        if (img->phdrs[i].p_type == PT_GNU_STACK) {
            has_stack = 1;
            stack_exec = (img->phdrs[i].p_flags & PF_X) != 0;
            break;
        }
    }
    if (has_stack && stack_exec) {
        ob_report_add_finding(r, "OB0052", "harden.exec_stack", OB_SEV_ERROR, "",
                               "PT_GNU_STACK is present but executable; link with -Wl,-z,noexecstack");
    } else if (!has_stack) {
        ob_report_add_finding(r, "OB0053", "harden.no_stack_note", OB_SEV_WARN, "",
                               "no PT_GNU_STACK segment; the linker's default may be an executable stack");
    }

    if (ctx->profile == OB_PROFILE_H && img->e_type == ET_EXEC) {
        ob_report_add_finding(r, "OB0054", "harden.nopie_hybrid", OB_SEV_WARN, "",
                               "ET_EXEC in Profile H: not position-independent, so no ASLR; link with -pie");
    }

    int textrel = dyn->has_textrel || (dyn->flags & DF_TEXTREL);
    if (textrel) {
        ob_report_add_finding(r, "OB0055", "harden.textrel", OB_SEV_ERROR, "",
                               "text relocations present (DT_TEXTREL); the binary was not built as PIC/PIE cleanly");
    }
}
