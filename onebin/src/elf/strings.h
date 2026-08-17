/* elf/strings.h — the one string scanner every check that needs "does this
 * byte sequence appear printable in the file" shares.
 * 01-SPEC-audit.md §6.5. 00-AGENT-TASK.md Task 8.
 *
 * Deliberately whole-buffer, not section-restricted: section headers may be
 * absent, and the point is to catch things wherever they physically are.
 */
#ifndef ELF_STRINGS_H
#define ELF_STRINGS_H

#include "util/buf.h"

/* Called once per string found. `s` points into the buffer, is NOT
 * NUL-terminated by the buffer itself but IS safe to treat as one for up to
 * `len` bytes (the scanner never hands out a run touching an unmapped
 * byte). `off` is the string's starting file offset. Do not retain `s`
 * beyond the callback — it aliases the caller's buffer. */
typedef void (*ob_strings_cb)(const char *s, size_t len, size_t off, void *user);

/* Walks `buf` once. A string is a maximal run of bytes in 0x20..0x7E of
 * length >= 4, terminated by a byte outside that range or end of buffer.
 * Runs longer than ONEBIN_MAX_STRING are split into successive callbacks
 * rather than one large one — no allocation, no materialised list, so a
 * 400 MiB binary costs O(1) extra memory here regardless of content. */
void ob_strings_scan(const ob_buf *buf, ob_strings_cb cb, void *user);

#endif /* ELF_STRINGS_H */
