/* limits.h — the bound constants from 01-SPEC-audit.md §11.
 *
 * Written once, here, because every parsing module (elf/image, elf/dynamic,
 * elf/verneed, elf/symbols) needs a subset of these to turn a crafted count
 * field into a bounded loop instead of a hang.  Two copies of a limit will
 * drift; see 00-AGENT-TASK.md Task 8's note about the profile ladder for why
 * that rule applies everywhere in this codebase, not just there.
 */
#ifndef UTIL_LIMITS_H
#define UTIL_LIMITS_H

#define ONEBIN_MAX_FILE      536870912u /* 512 MiB */
#define ONEBIN_MAX_PHNUM         65535u
#define ONEBIN_MAX_SHNUM         65535u
#define ONEBIN_MAX_DYNENT        65536u
#define ONEBIN_MAX_NEEDED         4096u
#define ONEBIN_MAX_VERNEED        4096u
#define ONEBIN_MAX_VERNAUX       65536u
#define ONEBIN_MAX_SYMS        1000000u
#define ONEBIN_MAX_STRING         4096u
#define ONEBIN_MAX_FINDINGS      10000u

#endif /* UTIL_LIMITS_H */
