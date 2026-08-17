/* elf/image.c — see elf/image.h for scope. 00-AGENT-TASK.md Task 5. */
#include "elf/image.h"
#include "elf/elf_const.h"
#include "util/limits.h"

#include <stdlib.h>
#include <string.h>

const char *ob_img_err_str(ob_img_err err) {
    switch (err) {
    case OB_IMG_OK:                        return "ok";
    case OB_IMG_ERR_TOO_SHORT:             return "file too short";
    case OB_IMG_ERR_BAD_MAGIC:             return "bad ELF magic";
    case OB_IMG_ERR_BAD_CLASS:             return "invalid EI_CLASS";
    case OB_IMG_ERR_BAD_DATA:              return "invalid EI_DATA";
    case OB_IMG_ERR_BAD_PHENTSIZE:         return "e_phentsize does not match the class";
    case OB_IMG_ERR_PHDR_RANGE:            return "program header table out of range";
    case OB_IMG_ERR_PHDR_OVERFLOW:         return "program header table offset overflows";
    case OB_IMG_ERR_PN_XNUM_UNSUPPORTED:   return "e_phnum is PN_XNUM but no section header 0 is reachable";
    }
    return "unknown error";
}

/* Zero everything so a caller who ignores the return value at least gets an
 * empty, harmless image rather than uninitialised pointers. */
static void image_zero(ob_image *img) {
    memset(img, 0, sizeof(*img));
}

/* ELF64 Phdr field offsets within one entry (02-REFERENCE-elf.md §4). */
enum {
    PH64_TYPE = 0, PH64_FLAGS = 4, PH64_OFFSET = 8, PH64_VADDR = 16,
    PH64_PADDR = 24, PH64_FILESZ = 32, PH64_MEMSZ = 40, PH64_ALIGN = 48
};
/* ELF32 Phdr field offsets — note p_flags is the LAST-but-one field, not the
 * second: 02-REFERENCE-elf.md calls this out as the most common bug. */
enum {
    PH32_TYPE = 0, PH32_OFFSET = 4, PH32_VADDR = 8, PH32_PADDR = 12,
    PH32_FILESZ = 16, PH32_MEMSZ = 20, PH32_FLAGS = 24, PH32_ALIGN = 28
};

static ob_img_err read_phdr(const ob_buf *b, size_t base, int c64, ob_phdr *out) {
    uint32_t type32 = 0, flags32 = 0;
    uint64_t off = 0, vaddr = 0, paddr = 0, filesz = 0, memsz = 0, align = 0;

    if (c64) {
        if (ob_rd32(b, base + PH64_TYPE,   &type32)  != 0) return OB_IMG_ERR_PHDR_RANGE;
        if (ob_rd32(b, base + PH64_FLAGS,  &flags32) != 0) return OB_IMG_ERR_PHDR_RANGE;
        if (ob_rd64(b, base + PH64_OFFSET, &off)     != 0) return OB_IMG_ERR_PHDR_RANGE;
        if (ob_rd64(b, base + PH64_VADDR,  &vaddr)   != 0) return OB_IMG_ERR_PHDR_RANGE;
        if (ob_rd64(b, base + PH64_PADDR,  &paddr)   != 0) return OB_IMG_ERR_PHDR_RANGE;
        if (ob_rd64(b, base + PH64_FILESZ, &filesz)  != 0) return OB_IMG_ERR_PHDR_RANGE;
        if (ob_rd64(b, base + PH64_MEMSZ,  &memsz)   != 0) return OB_IMG_ERR_PHDR_RANGE;
        if (ob_rd64(b, base + PH64_ALIGN,  &align)   != 0) return OB_IMG_ERR_PHDR_RANGE;
    } else {
        uint32_t off32 = 0, vaddr32 = 0, paddr32 = 0, filesz32 = 0, memsz32 = 0, align32 = 0;
        if (ob_rd32(b, base + PH32_TYPE,   &type32)   != 0) return OB_IMG_ERR_PHDR_RANGE;
        if (ob_rd32(b, base + PH32_OFFSET, &off32)    != 0) return OB_IMG_ERR_PHDR_RANGE;
        if (ob_rd32(b, base + PH32_VADDR,  &vaddr32)  != 0) return OB_IMG_ERR_PHDR_RANGE;
        if (ob_rd32(b, base + PH32_PADDR,  &paddr32)  != 0) return OB_IMG_ERR_PHDR_RANGE;
        if (ob_rd32(b, base + PH32_FILESZ, &filesz32) != 0) return OB_IMG_ERR_PHDR_RANGE;
        if (ob_rd32(b, base + PH32_MEMSZ,  &memsz32)  != 0) return OB_IMG_ERR_PHDR_RANGE;
        if (ob_rd32(b, base + PH32_FLAGS,  &flags32)  != 0) return OB_IMG_ERR_PHDR_RANGE;
        if (ob_rd32(b, base + PH32_ALIGN,  &align32)  != 0) return OB_IMG_ERR_PHDR_RANGE;
        off = off32; vaddr = vaddr32; paddr = paddr32;
        filesz = filesz32; memsz = memsz32; align = align32;
    }

    out->p_type   = type32;
    out->p_flags  = flags32;
    out->p_offset = off;
    out->p_vaddr  = vaddr;
    out->p_paddr  = paddr;
    out->p_filesz = filesz;
    out->p_memsz  = memsz;
    out->p_align  = align;
    return OB_IMG_OK;
}

/* PN_XNUM (02-REFERENCE-elf.md §3, "Sanity checks on the header"): when
 * e_phnum == 0xFFFF the real count lives in sh_info of section header 0.
 * Only this one field of the section-header world is read here; everything
 * else about sections is out of this module's scope. */
static ob_img_err resolve_pn_xnum(const ob_buf *b, uint64_t e_shoff, uint16_t e_shnum,
                                   int c64, uint32_t *real_phnum) {
    if (e_shoff == 0 || e_shnum == 0) {
        return OB_IMG_ERR_PN_XNUM_UNSUPPORTED;
    }
    if (e_shoff > (uint64_t)SIZE_MAX) {
        return OB_IMG_ERR_PN_XNUM_UNSUPPORTED;
    }
    size_t sh0 = (size_t)e_shoff;
    size_t sh_info_off = sh0 + (c64 ? 44u : 28u); /* Elf*_Shdr.sh_info, §5 */
    uint32_t v = 0;
    if (ob_rd32(b, sh_info_off, &v) != 0) {
        return OB_IMG_ERR_PN_XNUM_UNSUPPORTED;
    }
    *real_phnum = v;
    return OB_IMG_OK;
}

ob_img_err ob_image_load(const uint8_t *data, size_t len, ob_image *out) {
    image_zero(out);

    if (!data || !out) {
        return OB_IMG_ERR_TOO_SHORT;
    }

    /* Magic first: it only needs 4 bytes, and a short file with a mangled
     * header should still be told "too short" rather than "bad magic" once
     * we can't even read EI_NIDENT — but a file that IS long enough to hold
     * the magic and gets it wrong is BAD_MAGIC, not TOO_SHORT. */
    if (len < 4) {
        return OB_IMG_ERR_TOO_SHORT;
    }
    if (data[0] != ELFMAG0 || data[1] != ELFMAG1 ||
        data[2] != ELFMAG2 || data[3] != ELFMAG3) {
        return OB_IMG_ERR_BAD_MAGIC;
    }
    if (len < EI_NIDENT) {
        return OB_IMG_ERR_TOO_SHORT;
    }

    uint8_t ei_class = data[EI_CLASS];
    uint8_t ei_data  = data[EI_DATA];
    if (ei_class != ELFCLASS32 && ei_class != ELFCLASS64) {
        return OB_IMG_ERR_BAD_CLASS;
    }
    if (ei_data != ELFDATA2LSB && ei_data != ELFDATA2MSB) {
        return OB_IMG_ERR_BAD_DATA;
    }

    int c64 = (ei_class == ELFCLASS64);
    int be  = (ei_data == ELFDATA2MSB);
    size_t ehdr_size = c64 ? EHDR64_SIZE : EHDR32_SIZE;

    if (len < ehdr_size) {
        return OB_IMG_ERR_TOO_SHORT;
    }

    ob_buf b = { .p = data, .len = len, .be = be, .c64 = c64 };

    uint16_t e_type = 0, e_machine = 0, e_ehsize = 0, e_phentsize = 0,
             e_phnum = 0, e_shentsize = 0, e_shnum = 0, e_shstrndx = 0;
    uint32_t e_version = 0, e_flags = 0;
    uint64_t e_entry = 0, e_phoff = 0, e_shoff = 0;

    size_t off_entry, off_phoff, off_shoff, off_flags,
           off_ehsize, off_phentsize, off_phnum,
           off_shentsize, off_shnum, off_shstrndx;
    if (c64) {
        off_entry = 24; off_phoff = 32; off_shoff = 40; off_flags = 48;
        off_ehsize = 52; off_phentsize = 54; off_phnum = 56;
        off_shentsize = 58; off_shnum = 60; off_shstrndx = 62;
    } else {
        off_entry = 24; off_phoff = 28; off_shoff = 32; off_flags = 36;
        off_ehsize = 40; off_phentsize = 42; off_phnum = 44;
        off_shentsize = 46; off_shnum = 48; off_shstrndx = 50;
    }

    if (ob_rd16(&b, 16, &e_type)    != 0) return OB_IMG_ERR_TOO_SHORT;
    if (ob_rd16(&b, 18, &e_machine) != 0) return OB_IMG_ERR_TOO_SHORT;
    if (ob_rd32(&b, 20, &e_version) != 0) return OB_IMG_ERR_TOO_SHORT;
    if (ob_rdaddr(&b, off_entry, &e_entry) != 0) return OB_IMG_ERR_TOO_SHORT;
    if (ob_rdaddr(&b, off_phoff, &e_phoff) != 0) return OB_IMG_ERR_TOO_SHORT;
    if (ob_rdaddr(&b, off_shoff, &e_shoff) != 0) return OB_IMG_ERR_TOO_SHORT;
    if (ob_rd32(&b, off_flags, &e_flags)             != 0) return OB_IMG_ERR_TOO_SHORT;
    if (ob_rd16(&b, off_ehsize, &e_ehsize)           != 0) return OB_IMG_ERR_TOO_SHORT;
    if (ob_rd16(&b, off_phentsize, &e_phentsize)     != 0) return OB_IMG_ERR_TOO_SHORT;
    if (ob_rd16(&b, off_phnum, &e_phnum)             != 0) return OB_IMG_ERR_TOO_SHORT;
    if (ob_rd16(&b, off_shentsize, &e_shentsize)     != 0) return OB_IMG_ERR_TOO_SHORT;
    if (ob_rd16(&b, off_shnum, &e_shnum)             != 0) return OB_IMG_ERR_TOO_SHORT;
    if (ob_rd16(&b, off_shstrndx, &e_shstrndx)       != 0) return OB_IMG_ERR_TOO_SHORT;

    /* PN_XNUM: resolve the real program-header count before doing anything
     * with it.  02-REFERENCE-elf.md §3 and 01-SPEC-audit.md §12. */
    uint32_t real_phnum = e_phnum;
    int used_pn_xnum = 0;
    if (e_phnum == 0xFFFFu) {
        used_pn_xnum = 1;
        ob_img_err xe = resolve_pn_xnum(&b, e_shoff, e_shnum, c64, &real_phnum);
        if (xe != OB_IMG_OK) {
            return xe;
        }
    }
    if (real_phnum > ONEBIN_MAX_PHNUM) {
        real_phnum = ONEBIN_MAX_PHNUM; /* bounded, never a billion-entry loop */
    }

    size_t canonical_phentsize = c64 ? PHDR64_SIZE : PHDR32_SIZE;
    if (real_phnum > 0 && e_phentsize != canonical_phentsize) {
        return OB_IMG_ERR_BAD_PHENTSIZE;
    }

    ob_phdr *phdrs = NULL;
    size_t nphdrs = 0;

    if (real_phnum > 0) {
        if (e_phoff > (uint64_t)SIZE_MAX) {
            return OB_IMG_ERR_PHDR_RANGE;
        }
        uint64_t total64 = (uint64_t)real_phnum * (uint64_t)e_phentsize;
        if (total64 > (uint64_t)SIZE_MAX) {
            return OB_IMG_ERR_PHDR_OVERFLOW;
        }
        if (e_phoff > UINT64_MAX - total64) {
            return OB_IMG_ERR_PHDR_OVERFLOW;
        }
        size_t phoff = (size_t)e_phoff;
        size_t total = (size_t)total64;
        if (ob_range(&b, phoff, total) != 0) {
            return OB_IMG_ERR_PHDR_RANGE;
        }

        phdrs = calloc((size_t)real_phnum, sizeof(*phdrs));
        if (!phdrs) {
            return OB_IMG_ERR_PHDR_RANGE; /* allocation failure: report, don't crash */
        }

        for (uint32_t i = 0; i < real_phnum; i++) {
            size_t base = phoff + (size_t)i * (size_t)e_phentsize;
            ob_img_err pe = read_phdr(&b, base, c64, &phdrs[i]);
            if (pe != OB_IMG_OK) {
                free(phdrs);
                return pe;
            }
        }
        nphdrs = real_phnum;
    }

    out->buf = b;
    out->osabi = data[EI_OSABI];
    out->abiversion = data[EI_ABIVERSION];
    out->ei_version_is_current = (data[EI_VERSION] == EV_CURRENT);
    out->e_type = e_type;
    out->e_machine = e_machine;
    out->e_version = e_version;
    out->e_entry = e_entry;
    out->e_phoff = e_phoff;
    out->e_shoff = e_shoff;
    out->e_flags = e_flags;
    out->e_ehsize = e_ehsize;
    out->e_phentsize = e_phentsize;
    out->e_phnum = (uint16_t)nphdrs; /* resolved & bounded, see header comment */
    out->e_shentsize = e_shentsize;
    out->e_shnum = e_shnum;
    out->e_shstrndx = e_shstrndx;
    out->e_ehsize_matches_canonical = (e_ehsize == ehdr_size);
    out->used_pn_xnum = used_pn_xnum;
    out->phdrs = phdrs;
    out->nphdrs = nphdrs;

    return OB_IMG_OK;
}

void ob_image_free(ob_image *img) {
    if (!img) {
        return;
    }
    free(img->phdrs);
    image_zero(img);
}

uint64_t ob_image_vaddr_to_offset(const ob_image *img, uint64_t vaddr) {
    if (!img) {
        return OB_NOT_MAPPED;
    }
    for (size_t i = 0; i < img->nphdrs; i++) {
        const ob_phdr *ph = &img->phdrs[i];
        if (ph->p_type != PT_LOAD) {
            continue;
        }
        if (vaddr < ph->p_vaddr) {
            continue;
        }
        uint64_t delta = vaddr - ph->p_vaddr;
        if (delta < ph->p_filesz) {
            return ph->p_offset + delta;
        }
    }
    return OB_NOT_MAPPED;
}

ob_profile ob_profile_detect(int has_pt_interp, int df1_pie_set, int et_dyn,
                              int has_soname, int has_needed, int *ambiguous) {
    if (ambiguous) {
        *ambiguous = 0;
    }
    if (has_pt_interp) {
        return OB_PROFILE_H; /* rule 1 */
    }
    if (df1_pie_set) {
        return OB_PROFILE_S; /* rule 2: linker marked it an executable */
    }
    if (et_dyn && (has_soname || has_needed)) {
        return OB_PROFILE_M; /* rule 3 */
    }
    if (et_dyn && !has_soname && !has_needed && ambiguous) {
        *ambiguous = 1; /* OB0039: indistinguishable from static-PIE */
    }
    return OB_PROFILE_S; /* rule 4 */
}
