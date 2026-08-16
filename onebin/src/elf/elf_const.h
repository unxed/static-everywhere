/* elf_const.h — every ELF constant this project uses, defined here and nowhere
 * else.
 *
 * Do NOT #include <elf.h>: it may be absent, and its contents vary between
 * libcs.  Every value below is copied from 02-REFERENCE-elf.md.  If you need a
 * constant that is not here, check that the reference lists it; if it does not,
 * you do not need it.
 *
 * Created in Task 4 because the fixture generator needs these before the parser
 * exists.  Task 5 extends it; nothing here is removed.
 */
#ifndef ONEBIN_ELF_CONST_H
#define ONEBIN_ELF_CONST_H

/* ---- e_ident ---------------------------------------------------------- */
#define EI_MAG0        0
#define EI_MAG1        1
#define EI_MAG2        2
#define EI_MAG3        3
#define EI_CLASS       4
#define EI_DATA        5
#define EI_VERSION     6
#define EI_OSABI       7
#define EI_ABIVERSION  8
#define EI_PAD         9
#define EI_NIDENT     16

#define ELFMAG0     0x7F
#define ELFMAG1     'E'
#define ELFMAG2     'L'
#define ELFMAG3     'F'

#define ELFCLASSNONE 0
#define ELFCLASS32   1
#define ELFCLASS64   2

#define ELFDATANONE  0
#define ELFDATA2LSB  1
#define ELFDATA2MSB  2

#define EV_CURRENT   1

#define ELFOSABI_NONE 0

/* ---- header sizes ----------------------------------------------------- */
#define EHDR32_SIZE  52
#define EHDR64_SIZE  64
#define PHDR32_SIZE  32
#define PHDR64_SIZE  56
#define SHDR32_SIZE  40
#define SHDR64_SIZE  64
#define SYM32_SIZE   16
#define SYM64_SIZE   24
#define DYN32_SIZE    8
#define DYN64_SIZE   16
#define VERNEED_SIZE 16
#define VERNAUX_SIZE 16

/* ---- e_type ----------------------------------------------------------- */
#define ET_NONE 0
#define ET_REL  1
#define ET_EXEC 2
#define ET_DYN  3
#define ET_CORE 4

/* ---- e_machine (only the ones we name) -------------------------------- */
#define EM_386        3
#define EM_MIPS       8
#define EM_PPC       20
#define EM_PPC64     21
#define EM_S390      22
#define EM_ARM       40
#define EM_X86_64    62
#define EM_AARCH64  183
#define EM_RISCV    243
#define EM_LOONGARCH 258

/* ---- p_type ----------------------------------------------------------- */
#define PT_NULL          0
#define PT_LOAD          1
#define PT_DYNAMIC       2
#define PT_INTERP        3
#define PT_NOTE          4
#define PT_SHLIB         5
#define PT_PHDR          6
#define PT_TLS           7
#define PT_GNU_EH_FRAME  0x6474E550
#define PT_GNU_STACK     0x6474E551
#define PT_GNU_RELRO     0x6474E552
#define PT_GNU_PROPERTY  0x6474E553

/* ---- p_flags ---------------------------------------------------------- */
#define PF_X 0x1
#define PF_W 0x2
#define PF_R 0x4

/* ---- sh_type ---------------------------------------------------------- */
#define SHT_NULL      0
#define SHT_PROGBITS  1
#define SHT_SYMTAB    2
#define SHT_STRTAB    3
#define SHT_RELA      4
#define SHT_HASH      5
#define SHT_DYNAMIC   6
#define SHT_NOTE      7
#define SHT_NOBITS    8
#define SHT_REL       9
#define SHT_DYNSYM   11
#define SHT_GNU_HASH  0x6FFFFFF6
#define SHT_GNU_VERDEF 0x6FFFFFFD
#define SHT_GNU_VERNEED 0x6FFFFFFE
#define SHT_GNU_VERSYM  0x6FFFFFFF

/* ---- d_tag ------------------------------------------------------------ */
#define DT_NULL             0
#define DT_NEEDED           1
#define DT_PLTRELSZ         2
#define DT_HASH             4
#define DT_STRTAB           5
#define DT_SYMTAB           6
#define DT_STRSZ           10
#define DT_SYMENT          11
#define DT_SONAME          14
#define DT_RPATH           15
#define DT_SYMBOLIC        16
#define DT_TEXTREL         22
#define DT_BIND_NOW        24
#define DT_RUNPATH         29
#define DT_FLAGS           30
#define DT_GNU_HASH        0x6FFFFEF5
#define DT_VERSYM          0x6FFFFFF0
#define DT_FLAGS_1         0x6FFFFFFB
#define DT_VERNEED         0x6FFFFFFE
#define DT_VERNEEDNUM      0x6FFFFFFF

/* ---- DT_FLAGS bits ---------------------------------------------------- */
#define DF_ORIGIN     0x1
#define DF_SYMBOLIC   0x2
#define DF_TEXTREL    0x4
#define DF_BIND_NOW   0x8
#define DF_STATIC_TLS 0x10

/* ---- DT_FLAGS_1 bits -------------------------------------------------- */
#define DF_1_NOW    0x00000001
#define DF_1_GLOBAL 0x00000002
#define DF_1_NODELETE 0x00000008
#define DF_1_ORIGIN 0x00000080
#define DF_1_NODEFLIB 0x00000800
#define DF_1_PIE    0x08000000

/* ---- symbols ---------------------------------------------------------- */
#define STB_LOCAL   0
#define STB_GLOBAL  1
#define STB_WEAK    2
#define STT_NOTYPE  0
#define STT_OBJECT  1
#define STT_FUNC    2
#define ELF_ST_INFO(bind, type) ((uint8_t)(((bind) << 4) | ((type) & 0xF)))

#define SHN_UNDEF 0

/* ---- versym special values -------------------------------------------- */
#define VER_NDX_LOCAL   0
#define VER_NDX_GLOBAL  1

#endif /* ONEBIN_ELF_CONST_H */
