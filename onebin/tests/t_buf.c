#include "test.h"
#include "util/buf.h"

TEST(buf_empty_buffer) {
    ob_buf b = { .p = NULL, .len = 0, .be = 0, .c64 = 1 };
    uint8_t  u8  = 0xAA;
    uint16_t u16 = 0xAAAA;
    uint32_t u32 = 0xAAAAAAAA;
    uint64_t u64 = 0xAAAAAAAAAAAAAAAAULL;
    char dst[16] = "sentinel";

    ASSERT_EQ_INT(ob_range(&b, 0, 0), 0);
    ASSERT_EQ_INT(ob_range(&b, 1, 0), -1);
    ASSERT_EQ_INT(ob_range(&b, 0, 1), -1);

    ASSERT_EQ_INT(ob_rd8(&b, 0, &u8), -1);
    ASSERT_EQ_INT(u8, 0xAA);

    ASSERT_EQ_INT(ob_rd16(&b, 0, &u16), -1);
    ASSERT_EQ_INT(u16, 0xAAAA);

    ASSERT_EQ_INT(ob_rd32(&b, 0, &u32), -1);
    ASSERT_EQ_U64(u32, 0xAAAAAAAA);

    ASSERT_EQ_INT(ob_rd64(&b, 0, &u64), -1);
    ASSERT_EQ_U64(u64, 0xAAAAAAAAAAAAAAAAULL);

    ASSERT_EQ_INT(ob_rdaddr(&b, 0, &u64), -1);
    ASSERT_EQ_U64(u64, 0xAAAAAAAAAAAAAAAAULL);

    ASSERT_EQ_INT(ob_rdstr(&b, 0, dst, sizeof(dst), 16), -1);
    ASSERT_EQ_STR(dst, "");
}

TEST(buf_null_checks) {
    uint8_t raw[8] = { 1, 2, 3, 4, 5, 6, 7, 8 };
    ob_buf b = { .p = raw, .len = sizeof(raw), .be = 0, .c64 = 1 };
    uint64_t u64 = 42;

    ASSERT_EQ_INT(ob_range(NULL, 0, 1), -1);
    ASSERT_EQ_INT(ob_rd8(&b, 0, NULL), -1);
    ASSERT_EQ_INT(ob_rd16(&b, 0, NULL), -1);
    ASSERT_EQ_INT(ob_rd32(&b, 0, NULL), -1);
    ASSERT_EQ_INT(ob_rd64(&b, 0, NULL), -1);
    ASSERT_EQ_INT(ob_rdaddr(NULL, 0, &u64), -1);
    ASSERT_EQ_INT(ob_rdaddr(&b, 0, NULL), -1);
    ASSERT_EQ_INT(ob_rdstr(NULL, 0, (char *)raw, 8, 8), -1);
    ASSERT_EQ_INT(ob_rdstr(&b, 0, NULL, 8, 8), -1);
    ASSERT_EQ_INT(ob_rdstr(&b, 0, (char *)raw, 0, 8), -1);
}

TEST(buf_overflow_arithmetic) {
    uint8_t raw[16] = {0};
    ob_buf b = { .p = raw, .len = 10, .be = 0, .c64 = 1 };

    ASSERT_EQ_INT(ob_range(&b, (size_t)-1, 1), -1);
    ASSERT_EQ_INT(ob_range(&b, 0, (size_t)-1), -1);
    ASSERT_EQ_INT(ob_range(&b, (size_t)-2, 4), -1);
    ASSERT_EQ_INT(ob_range(&b, 10, 0), 0);
    ASSERT_EQ_INT(ob_range(&b, 11, 0), -1);
    ASSERT_EQ_INT(ob_range(&b, 9, 2), -1);
    ASSERT_EQ_INT(ob_range(&b, 8, 2), 0);
}

TEST(buf_endian_decoding) {
    uint8_t raw[8] = { 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0 };
    ob_buf ble = { .p = raw, .len = 8, .be = 0, .c64 = 1 };
    ob_buf bbe = { .p = raw, .len = 8, .be = 1, .c64 = 1 };

    uint8_t u8 = 0;
    ASSERT_OK(ob_rd8(&ble, 0, &u8));
    ASSERT_EQ_INT(u8, 0x12);

    uint16_t u16 = 0;
    ASSERT_OK(ob_rd16(&ble, 0, &u16));
    ASSERT_EQ_INT(u16, 0x3412);
    ASSERT_OK(ob_rd16(&bbe, 0, &u16));
    ASSERT_EQ_INT(u16, 0x1234);

    uint32_t u32 = 0;
    ASSERT_OK(ob_rd32(&ble, 0, &u32));
    ASSERT_EQ_U64(u32, 0x78563412U);
    ASSERT_OK(ob_rd32(&bbe, 0, &u32));
    ASSERT_EQ_U64(u32, 0x12345678U);

    uint64_t u64 = 0;
    ASSERT_OK(ob_rd64(&ble, 0, &u64));
    ASSERT_EQ_U64(u64, 0xF0DEBC9A78563412ULL);
    ASSERT_OK(ob_rd64(&bbe, 0, &u64));
    ASSERT_EQ_U64(u64, 0x123456789ABCDEF0ULL);
}

TEST(buf_rdaddr_modes) {
    uint8_t raw[8] = { 0x78, 0x56, 0x34, 0x12, 0xEF, 0xCD, 0xAB, 0x90 };
    ob_buf b32 = { .p = raw, .len = 8, .be = 1, .c64 = 0 };
    ob_buf b64 = { .p = raw, .len = 8, .be = 1, .c64 = 1 };
    uint64_t out = 0;

    ASSERT_OK(ob_rdaddr(&b32, 0, &out));
    ASSERT_EQ_U64(out, 0x78563412ULL);

    ASSERT_OK(ob_rdaddr(&b64, 0, &out));
    ASSERT_EQ_U64(out, 0x78563412EFCDAB90ULL);

    ob_buf b32_short = { .p = raw, .len = 3, .be = 1, .c64 = 0 };
    uint64_t sentinel = 0xDEADBEEFULL;
    ASSERT_EQ_INT(ob_rdaddr(&b32_short, 0, &sentinel), -1);
    ASSERT_EQ_U64(sentinel, 0xDEADBEEFULL);

    ob_buf b64_short = { .p = raw, .len = 7, .be = 1, .c64 = 1 };
    ASSERT_EQ_INT(ob_rdaddr(&b64_short, 0, &sentinel), -1);
    ASSERT_EQ_U64(sentinel, 0xDEADBEEFULL);
}

TEST(buf_rdstr_cases) {
    const char *text = "hello world\0extra";
    ob_buf b = { .p = (const uint8_t *)text, .len = 18, .be = 0, .c64 = 1 };
    char dst[32];

    ssize_t len = ob_rdstr(&b, 0, dst, sizeof(dst), 32);
    ASSERT_EQ_INT(len, 11);
    ASSERT_EQ_STR(dst, "hello world");

    ASSERT_EQ_INT(ob_rdstr(&b, 18, dst, sizeof(dst), 32), -1);

    const char *no_nul = "unterminated";
    ob_buf b_no_nul = { .p = (const uint8_t *)no_nul, .len = 12, .be = 0, .c64 = 1 };
    ASSERT_EQ_INT(ob_rdstr(&b_no_nul, 0, dst, sizeof(dst), 12), -1);
    ASSERT_EQ_STR(dst, "");

    /* max limit smaller than string length */
    ASSERT_EQ_INT(ob_rdstr(&b, 0, dst, sizeof(dst), 5), -1);
    ASSERT_EQ_STR(dst, "");

    /* dstsz too small to hold full string */
    char small_dst[5];
    ASSERT_EQ_INT(ob_rdstr(&b, 0, small_dst, sizeof(small_dst), 32), -1);
    ASSERT_EQ_STR(small_dst, "");
}
