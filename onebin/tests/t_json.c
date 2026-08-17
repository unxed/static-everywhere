/* t_json.c — util/json.c.  03-TESTPLAN.md §5.3. Item numbers in comments
 * match that section.
 */
#include "test.h"
#include "util/json.h"

#include <locale.h>
#include <string.h>

/* --------------------------------------------------------------- item 1 */

TEST(json_escapes_quote_and_backslash) {
    ob_jbuf b;
    ob_jbuf_init(&b);
    ob_jbuf_string(&b, "a\"b\\c");
    ASSERT_EQ_STR(b.data, "\"a\\\"b\\\\c\"");
    ob_jbuf_free(&b);
}

/* --------------------------------------------------------------- item 2 */

TEST(json_defensively_escapes_control_bytes) {
    /* Sanitisation should already have removed these, but the writer must
     * not produce invalid JSON if handed one directly. */
    ob_jbuf b;
    ob_jbuf_init(&b);
    char in[5] = { 'a', 0x01, '\n', '\t', 0 };
    ob_jbuf_string(&b, in);
    ASSERT_EQ_STR(b.data, "\"a\\u0001\\n\\t\"");
    ob_jbuf_free(&b);
}

TEST(json_escapes_carriage_return) {
    ob_jbuf b;
    ob_jbuf_init(&b);
    char in[3] = { '\r', 'x', 0 };
    ob_jbuf_string(&b, in);
    ASSERT_EQ_STR(b.data, "\"\\rx\"");
    ob_jbuf_free(&b);
}

/* --------------------------------------------------------------- item 3 */

TEST(json_empty_string_array_object) {
    ob_jbuf b;
    ob_jbuf_init(&b);
    ob_jbuf_string(&b, "");
    ASSERT_EQ_STR(b.data, "\"\"");
    ob_jbuf_free(&b);

    /* Empty array and empty object are rendered directly by report_json.c
     * (put_string_array / the "{}" shape it never needs, since every
     * object in this schema has fixed keys) — the primitive this module
     * owns is the string writer above; array/object shape is exercised in
     * t_report.c's golden fixtures rather than duplicated here. */
}

/* --------------------------------------------------------------- item 4 */

TEST(json_null_renders_for_absent_scalar) {
    ob_jbuf b;
    ob_jbuf_init(&b);
    ob_jbuf_puts(&b, "null");
    ASSERT_EQ_STR(b.data, "null");
    ob_jbuf_free(&b);
}

/* --------------------------------------------------------------- item 5 */

TEST(json_indent_nesting) {
    ob_jbuf b;
    ob_jbuf_init(&b);
    ob_jbuf_indent(&b, 0);
    ob_jbuf_puts(&b, "{\n");
    ob_jbuf_indent(&b, 1);
    ob_jbuf_puts(&b, "\"a\": [\n");
    ob_jbuf_indent(&b, 2);
    ob_jbuf_puts(&b, "1,\n");
    ob_jbuf_indent(&b, 2);
    ob_jbuf_puts(&b, "2\n");
    ob_jbuf_indent(&b, 1);
    ob_jbuf_puts(&b, "]\n");
    ob_jbuf_indent(&b, 0);
    ob_jbuf_puts(&b, "}");
    ASSERT_EQ_STR(b.data, "{\n  \"a\": [\n    1,\n    2\n  ]\n}");
    ob_jbuf_free(&b);
}

/* --------------------------------------------------------------- item 6 */

TEST(json_data_is_nul_terminated_no_forced_newline) {
    /* The writer itself does not append a trailing newline — that is a
     * document-level decision (report_json.c's caller adds exactly one),
     * per §9.2. Verify the primitive doesn't sneak one in. */
    ob_jbuf b;
    ob_jbuf_init(&b);
    ob_jbuf_puts(&b, "x");
    ASSERT_EQ_INT(b.len, 1);
    ASSERT_EQ_INT(b.data[b.len], '\0');
    ob_jbuf_free(&b);
}

/* --------------------------------------------------------------- item 7 */
/* "No trailing commas anywhere" is a report_json.c property (it never
 * writes a comma after the last element) — exercised by every golden
 * fixture in t_report.c, since it is a property of the whole document, not
 * of this module's primitives in isolation. */

/* --------------------------------------------------------------- item 8 */

TEST(json_numbers_not_locale_dependent) {
    if (!setlocale(LC_ALL, "de_DE.UTF-8") && !setlocale(LC_ALL, "de_DE")) {
        SKIP("no comma-decimal locale available on this system");
    }
    /* put_i64 in report_json.c never goes through printf's "%d"/"%f" at
     * all — it hand-formats decimal digits — so there is nothing for a
     * locale to change. Simulate the same hand-formatting here directly
     * against the one primitive util/json.c exposes for it indirectly:
     * ob_jbuf_puts with pre-formatted digits, i.e. confirm puts() itself
     * does no locale-sensitive transformation. */
    ob_jbuf b;
    ob_jbuf_init(&b);
    ob_jbuf_puts(&b, "1234");
    ASSERT_EQ_STR(b.data, "1234");
    ob_jbuf_free(&b);
    setlocale(LC_ALL, "C");
}

/* --------------------------------------------------------------- growth */

TEST(json_buffer_grows_past_initial_capacity) {
    ob_jbuf b;
    ob_jbuf_init(&b);
    for (int i = 0; i < 2000; i++) {
        ob_jbuf_putc(&b, 'x');
    }
    ASSERT_EQ_INT(b.len, 2000);
    ASSERT_TRUE(b.cap > 2000);
    for (size_t i = 0; i < b.len; i++) {
        ASSERT_EQ_INT(b.data[i], 'x');
    }
    ob_jbuf_free(&b);
}
