/* elf/image.h — load and identify.  00-AGENT-TASK.md Task 5.
 *
 * Scope, deliberately narrow: read e_ident, read the ELF header, index the
 * program headers, build the vaddr->offset translation table.  Section
 * headers are NOT parsed here except for the one field PN_XNUM needs
 * (Elf*_Shdr[0].sh_info) — everything else about sections belongs to whatever
 * check needs them (01-SPEC-audit.md §2: program headers are the primary
 * view, section headers "an optional bonus").
 *
 * Never mmap (01-SPEC-audit.md §3.2).  The caller reads the file into memory
 * and owns that buffer; ob_image only ever reads through util/buf, and keeps
 * its own allocation limited to the phdr array.
 *
 * This module produces no findings.  It has no notion of OB-codes, no
 * severity, and does not decide whether e.g. ET_REL is acceptable — that is
 * an audit-level decision (01-SPEC-audit.md §12) made by a caller that has
 * not been written yet.  What it guarantees is: never crash, never hang,
 * never read out of bounds, and tell the truth about what bytes said.
 */
#ifndef ELF_IMAGE_H
#define ELF_IMAGE_H

#include "util/buf.h"

/* ---- errors ------------------------------------------------------------
 * Every one of these must be reachable from a case in 03-TESTPLAN.md §5.5.
 * The enum is deliberately specific rather than "ok/err": a caller that turns
 * this into a finding needs to say *what* was wrong, and a test that asserts
 * "loading fails" should assert *how*, not just that it failed.
 */
typedef enum {
    OB_IMG_OK = 0,
    OB_IMG_ERR_TOO_SHORT,          /* fewer than EI_NIDENT bytes, or ehdr truncated */
    OB_IMG_ERR_BAD_MAGIC,          /* e_ident[0..3] != \x7fELF */
    OB_IMG_ERR_BAD_CLASS,          /* EI_CLASS not 1 or 2 */
    OB_IMG_ERR_BAD_DATA,           /* EI_DATA not 1 or 2 */
    OB_IMG_ERR_BAD_PHENTSIZE,      /* e_phentsize wrong and e_phnum > 0 */
    OB_IMG_ERR_PHDR_RANGE,         /* phdr table (or one entry) does not fit in the file */
    OB_IMG_ERR_PHDR_OVERFLOW,      /* e_phoff + e_phnum*e_phentsize overflows size_t */
    OB_IMG_ERR_PN_XNUM_UNSUPPORTED /* e_phnum == 0xFFFF and section header 0 is not reachable */
} ob_img_err;

const char *ob_img_err_str(ob_img_err err);

/* ---- program header, values already sign/width-normalised -------------- */
typedef struct {
    uint32_t p_type;
    uint32_t p_flags;
    uint64_t p_offset;
    uint64_t p_vaddr;
    uint64_t p_paddr;
    uint64_t p_filesz;
    uint64_t p_memsz;
    uint64_t p_align;
} ob_phdr;

/* ---- the image ----------------------------------------------------------
 * buf.p aliases the caller's storage; ob_image never copies file bytes, only
 * the parsed-out header fields and the phdr array.
 */
typedef struct {
    ob_buf buf; /* .be and .c64 set from e_ident before anything else is read */

    /* e_ident, beyond what ob_buf already captured */
    uint8_t osabi;
    uint8_t abiversion;
    int     ei_version_is_current; /* 0 => EI_VERSION != 1: warn, not fatal */

    /* the ELF header */
    uint16_t e_type;
    uint16_t e_machine;
    uint32_t e_version;
    uint64_t e_entry;
    uint64_t e_phoff;
    uint64_t e_shoff;
    uint32_t e_flags;
    uint16_t e_ehsize;
    uint16_t e_phentsize;
    uint16_t e_phnum;    /* already resolved: PN_XNUM has been expanded */
    uint16_t e_shentsize;
    uint16_t e_shnum;
    uint16_t e_shstrndx;

    int e_ehsize_matches_canonical; /* 0 => informational only, per the reference */
    int used_pn_xnum;               /* 1 => e_phnum in the file was 0xFFFF */

    /* program headers, in file order */
    ob_phdr *phdrs;
    size_t   nphdrs;
} ob_image;

/* Parse `data[0..len)` into `*out`.  On success returns OB_IMG_OK and `*out`
 * is fully populated; the caller must eventually call ob_image_free().  On
 * failure returns the specific error, leaves `*out` zeroed, and frees
 * anything it had allocated — the caller must NOT call ob_image_free() after
 * a failed load. */
ob_img_err ob_image_load(const uint8_t *data, size_t len, ob_image *out);
void       ob_image_free(ob_image *img);

/* Address to file offset, 01-SPEC-audit.md §6.1: the first PT_LOAD, in
 * program-header order, whose [p_vaddr, p_vaddr+p_filesz) contains `vaddr`.
 * An address only reachable via p_memsz (.bss) is NOT_MAPPED, per
 * 02-REFERENCE-elf.md "Things that are true and surprising" #11. */
#define OB_NOT_MAPPED ((uint64_t)-1)
uint64_t ob_image_vaddr_to_offset(const ob_image *img, uint64_t vaddr);

#endif /* ELF_IMAGE_H */
