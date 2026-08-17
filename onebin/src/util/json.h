/* util/json.h — hand-written JSON writer, low-level half.
 *
 * This is deliberately NOT a generic streaming JSON API with automatic
 * nesting/comma tracking: 01-SPEC-audit.md §9.2's schema is fixed and known
 * in advance, so audit/report_json.c hand-assembles it directly, the way
 * real "emit one specific document" code usually does. What genuinely needs
 * to be written once, carefully, and shared is string escaping and a
 * growable output buffer — the two parts easy to get subtly wrong — so
 * that's what lives here.
 */
#ifndef UTIL_JSON_H
#define UTIL_JSON_H

#include <stddef.h>

typedef struct {
    char  *data;
    size_t len;
    size_t cap;
} ob_jbuf;

void ob_jbuf_init(ob_jbuf *b);
void ob_jbuf_free(ob_jbuf *b);

void ob_jbuf_putc(ob_jbuf *b, char c);
void ob_jbuf_puts(ob_jbuf *b, const char *s); /* raw append, NOT escaped */
void ob_jbuf_indent(ob_jbuf *b, int level);   /* 2 spaces per level */

/* Writes a JSON string literal, quotes included: escapes '"' and '\\', and
 * — defensively, in case a caller bypasses util/str's sanitiser — every
 * byte below 0x20 as \n, \t, \r or \u00XX. 03-TESTPLAN.md §5.3 items 1-2. */
void ob_jbuf_string(ob_jbuf *b, const char *s);

#endif /* UTIL_JSON_H */
