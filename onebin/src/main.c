#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "onebin/audit.h"

static void print_version(void) {
    printf("onebin %s\n", ONEBIN_VERSION);
}

static void print_usage(FILE *out) {
    fprintf(out,
        "Usage:\n"
        "  onebin audit [OPTIONS] FILE...\n"
        "  onebin --version\n"
        "  onebin --help\n"
        "  onebin audit --help\n"
        "\n"
        "Subcommands:\n"
        "  audit    Audit ELF binaries against the Static Everywhere manifesto\n"
        "\n"
        "Options:\n"
        "  --help       Show this help message\n"
        "  --version    Show version string\n"
    );
}

static void print_audit_usage(FILE *out) {
    fprintf(out,
        "Usage: onebin audit [OPTIONS] FILE...\n"
        "\n"
        "Audit ELF binaries against the Static Everywhere manifesto.\n"
        "\n"
        "Options:\n"
        "  --profile <auto|static|hybrid>  Target profile (default: auto)\n"
        "  --glibc-max <version>           Maximum allowed GLIBC requirement (default: 2.28)\n"
        "  --level <0|1|2|3>               Conformance level (default: 1)\n"
        "  --allow <soname>                Add soname to DT_NEEDED allowlist (repeatable)\n"
        "  --baseline <path>               Load baseline to suppress findings\n"
        "  --write-baseline <path>         Write findings to baseline file\n"
        "  --format <text|json>            Output format (default: text)\n"
        "  --strict                        Treat warnings as errors\n"
        "  --quiet                         Print only summary and errors\n"
        "  --verbose                       Print info findings and diagnostics\n"
        "  --no-color                      Disable ANSI color\n"
        "  --max-file <bytes>              Max file size to audit (default: 512MiB)\n"
        "  --help                          Show this help message\n"
    );
}

int main(int argc, char **argv) {
    if (argc < 2) {
        print_usage(stderr);
        return 2;
    }

    if (strcmp(argv[1], "--version") == 0) {
        print_version();
        return 0;
    }

    if (strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0) {
        print_usage(stdout);
        return 0;
    }

    if (strcmp(argv[1], "audit") == 0) {
        if (argc >= 3 && (strcmp(argv[2], "--help") == 0 || strcmp(argv[2], "-h") == 0)) {
            print_audit_usage(stdout);
            return 0;
        }
        if (argc < 3) {
            fprintf(stderr, "error: 'audit' requires at least one file path\n");
            print_audit_usage(stderr);
            return 2;
        }
        fprintf(stderr, "onebin: audit subcommand implementation in progress\n");
        return 0;
    }

    fprintf(stderr, "error: unknown option or command '%s'\n", argv[1]);
    print_usage(stderr);
    return 2;
}
