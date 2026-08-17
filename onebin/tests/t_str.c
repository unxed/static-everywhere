/* t_str.c — util/str.c.  01-SPEC-audit.md §9.3, 03-TESTPLAN.md §5.2. */
#include "test.h"
#include "util/str.h"

#include <string.h>

TEST(str_sanitize_clean_passthrough) {
    char out[OB_STR_MAXLEN + 1];
    int changed = ob_str_sanitize("libc.so.6", out, sizeof(out));
    ASSERT_EQ_INT(changed, 0);
    ASSERT_EQ_STR(out, "libc.so.6");
}

TEST(str_sanitize_replaces_control_bytes) {
    char in[8] = { 'a', 'b', 0x01, 0x1F, 0x7F, 'c', 0x00 };
    /* Note: the 0x00 terminates the C string at index 6 — every preceding
     * byte (indices 0-5) is scanned. */
    char out[OB_STR_MAXLEN + 1];
    int changed = ob_str_sanitize(in, out, sizeof(out));
    ASSERT_EQ_INT(changed, 1);
    ASSERT_EQ_STR(out, "ab???c [sanitised]");
}

TEST(str_sanitize_replaces_high_bytes_and_marks) {
    char in[6] = { (char)0x80, (char)0xFF, 'x', 0x1B, '[', 0 };
    char out[OB_STR_MAXLEN + 1];
    int changed = ob_str_sanitize(in, out, sizeof(out));
    ASSERT_EQ_INT(changed, 1);
    ASSERT_EQ_STR(out, "??x?[ [sanitised]");
}

TEST(str_sanitize_null_input) {
    char out[OB_STR_MAXLEN + 1] = "unchanged";
    int changed = ob_str_sanitize(NULL, out, sizeof(out));
    ASSERT_EQ_INT(changed, 0);
    ASSERT_EQ_STR(out, "");
}

TEST(str_sanitize_empty_input) {
    char out[OB_STR_MAXLEN + 1];
    int changed = ob_str_sanitize("", out, sizeof(out));
    ASSERT_EQ_INT(changed, 0);
    ASSERT_EQ_STR(out, "");
}

TEST(str_sanitize_truncates_long_clean_string) {
    char in[600];
    for (size_t i = 0; i < sizeof(in) - 1; i++) {
        in[i] = 'a';
    }
    in[sizeof(in) - 1] = '\0';

    char out[OB_STR_MAXLEN + 1];
    ob_str_sanitize(in, out, sizeof(out));
    size_t n = strlen(out);
    ASSERT_TRUE(n <= OB_STR_MAXLEN);
    ASSERT_EQ_STR(out + n - 3, "...");
}

TEST(str_sanitize_truncates_after_marker) {
    /* Long AND dirty: the " [sanitised]" marker itself must be accounted
     * for in the 200-byte cap, not appended after truncation already
     * happened. */
    char in[600];
    for (size_t i = 0; i < sizeof(in) - 1; i++) {
        in[i] = (char)((i % 2 == 0) ? 'a' : 0x01);
    }
    in[sizeof(in) - 1] = '\0';

    char out[OB_STR_MAXLEN + 1];
    int changed = ob_str_sanitize(in, out, sizeof(out));
    ASSERT_EQ_INT(changed, 1);
    size_t n = strlen(out);
    ASSERT_TRUE(n <= OB_STR_MAXLEN);
    ASSERT_EQ_STR(out + n - 3, "...");
}

TEST(str_sanitize_small_dst_buffer) {
    char out[6];
    int changed = ob_str_sanitize("hello world", out, sizeof(out));
    (void)changed;
    ASSERT_TRUE(strlen(out) < sizeof(out));
}

TEST(str_sanitize_zero_size_dst) {
    char out[1] = { 'x' };
    /* Must not crash or write out of bounds; dst is left untouched by
     * contract when dstsz == 0 (nothing safe to write). */
    ob_str_sanitize("hello", out, 0);
    ASSERT_TRUE(1); /* reaching here without a crash is the assertion */
}
