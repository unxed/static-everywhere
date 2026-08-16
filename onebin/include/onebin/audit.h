#ifndef ONEBIN_AUDIT_H
#define ONEBIN_AUDIT_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#define ONEBIN_VERSION "0.1.0"

typedef enum {
    OB_LEVEL_0 = 0,
    OB_LEVEL_1 = 1,
    OB_LEVEL_2 = 2,
    OB_LEVEL_3 = 3
} ob_level;

typedef enum {
    OB_SEV_OK = 0,
    OB_SEV_INFO,
    OB_SEV_WARN,
    OB_SEV_ERROR,
    OB_SEV_FATAL
} ob_severity;

#endif /* ONEBIN_AUDIT_H */
