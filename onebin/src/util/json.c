/* util/json.c — see util/json.h. */
#include "util/json.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void ob_jbuf_init(ob_jbuf *b) {
    b->data = NULL;
    b->len = 0;
    b->cap = 0;
}

void ob_jbuf_free(ob_jbuf *b) {
    free(b->data);
    b->data = NULL;
    b->len = 0;
    b->cap = 0;
}

static void jbuf_need(ob_jbuf *b, size_t extra) {
    if (b->len + extra + 1 <= b->cap) {
        return;
    }
    size_t cap = b->cap ? b->cap : 256;
    while (cap < b->len + extra + 1) {
        cap *= 2;
    }
    char *p = realloc(b->data, cap);
    if (!p) {
        /* This buffer is bounded by what a single audit report contains —
         * findings capped at ONEBIN_MAX_FINDINGS, every string sanitised to
         * OB_STR_MAXLEN — so realistic sizes are a few hundred KiB at most.
         * Treat exhaustion as unrecoverable rather than silently truncating
         * a report: a truncated JSON document is worse than a crash, the
         * same reasoning tests/mkelf.c uses for its own allocations. */
        fprintf(stderr, "onebin: out of memory building JSON output\n");
        abort();
    }
    b->data = p;
    b->cap = cap;
}

void ob_jbuf_putc(ob_jbuf *b, char c) {
    jbuf_need(b, 1);
    b->data[b->len++] = c;
    b->data[b->len] = '\0';
}

void ob_jbuf_puts(ob_jbuf *b, const char *s) {
    if (!s) {
        return;
    }
    size_t n = strlen(s);
    jbuf_need(b, n);
    memcpy(b->data + b->len, s, n);
    b->len += n;
    b->data[b->len] = '\0';
}

void ob_jbuf_indent(ob_jbuf *b, int level) {
    for (int i = 0; i < level; i++) {
        ob_jbuf_puts(b, "  ");
    }
}

void ob_jbuf_string(ob_jbuf *b, const char *s) {
    ob_jbuf_putc(b, '"');
    if (s) {
        for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
            unsigned char c = *p;
            switch (c) {
            case '"':  ob_jbuf_puts(b, "\\\""); break;
            case '\\': ob_jbuf_puts(b, "\\\\"); break;
            case '\n': ob_jbuf_puts(b, "\\n"); break;
            case '\t': ob_jbuf_puts(b, "\\t"); break;
            case '\r': ob_jbuf_puts(b, "\\r"); break;
            default:
                if (c < 0x20) {
                    char esc[8];
                    snprintf(esc, sizeof(esc), "\\u%04x", (unsigned)c);
                    ob_jbuf_puts(b, esc);
                } else {
                    ob_jbuf_putc(b, (char)c);
                }
            }
        }
    }
    ob_jbuf_putc(b, '"');
}
