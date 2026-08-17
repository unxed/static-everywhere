/* util/str.h — safe string ops, the ASCII sanitiser.
 * 01-SPEC-audit.md §9.3, 03-TESTPLAN.md §5.2.
 *
 * "Every string that came from the audited file must be sanitised before it
 * reaches any output." A hostile binary can put arbitrary bytes, ANSI
 * escapes, or newlines in a DT_NEEDED entry.
 */
#ifndef UTIL_STR_H
#define UTIL_STR_H

#include <stddef.h>

/* Longest a sanitised string is allowed to be, INCLUDING the " [sanitised]"
 * marker and the "..." truncation suffix — 01-SPEC-audit.md §9.3's "200
 * bytes". */
#define OB_STR_MAXLEN 200

/* Replaces every byte outside 0x20..0x7E with '?'. If any byte was
 * replaced, appends " [sanitised]". Then truncates the result to
 * OB_STR_MAXLEN bytes total, replacing the last 3 with "..." if truncation
 * was needed.
 *
 * `dst` is always NUL-terminated, even if `src` is NULL (dst becomes "") or
 * `dstsz` is too small to hold the full result (whatever fits, still
 * NUL-terminated). Recommended dstsz is >= OB_STR_MAXLEN + 1.
 *
 * Returns 1 if at least one byte was replaced (independent of whether
 * truncation also happened), 0 if `src` was copied through unchanged. */
int ob_str_sanitize(const char *src, char *dst, size_t dstsz);

#endif /* UTIL_STR_H */
