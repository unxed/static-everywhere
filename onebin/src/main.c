/* main.c */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "onebin/audit.h"
#include "audit/audit.h"

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
        "  --profile <auto|static|hybrid|module|universal>  Target profile (default: auto)\n"
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
        "  --                              Stop parsing options; the rest are paths\n"
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

        /* Second increment: --format, --level, --profile, --glibc-max,
         * --strict, --quiet, --verbose, --no-color now parse. Still not
         * implemented: --allow, --baseline, --write-baseline, --max-file. */
        int use_json = 0, quiet = 0, verbose = 0, strict = 0, no_color = 0;
        ob_level level = OB_LEVEL_1;
        int profile_forced = 0;
        ob_profile profile = OB_PROFILE_S;
        const char *glibc_max = NULL;
        const char *baseline_path = NULL;
        const char *write_baseline_path = NULL;
        long max_file = -1;
        const char **allow = malloc((size_t)argc * sizeof(char *));
        if (!allow) {
            fprintf(stderr, "error: out of memory\n");
            return 2;
        }
        int nallow = 0;
        const char **files = malloc((size_t)argc * sizeof(char *));
        if (!files) {
            fprintf(stderr, "error: out of memory\n");
            free(allow);
            return 2;
        }
        int nfiles = 0;
        int no_more_opts = 0;

        for (int i = 2; i < argc; i++) {
            if (!no_more_opts && strcmp(argv[i], "--") == 0) {
                no_more_opts = 1;
                continue;
            }
            if (no_more_opts) {
                files[nfiles++] = argv[i];
                continue;
            }
            if (strcmp(argv[i], "--format") == 0) {
                if (i + 1 >= argc) { fprintf(stderr, "error: --format requires an argument\n"); free(files); free(allow); return 2; }
                i++;
                if (strcmp(argv[i], "json") == 0) use_json = 1;
                else if (strcmp(argv[i], "text") == 0) use_json = 0;
                else { fprintf(stderr, "error: --format must be text or json\n"); free(files); free(allow); return 2; }
            } else if (strcmp(argv[i], "--level") == 0) {
                if (i + 1 >= argc) { fprintf(stderr, "error: --level requires an argument\n"); free(files); free(allow); return 2; }
                i++;
                int lv = atoi(argv[i]);
                if (lv < 0 || lv > 3) { fprintf(stderr, "error: --level must be 0-3\n"); free(files); free(allow); return 2; }
                level = (ob_level)lv;
            } else if (strcmp(argv[i], "--glibc-max") == 0) {
                if (i + 1 >= argc) { fprintf(stderr, "error: --glibc-max requires an argument\n"); free(files); free(allow); return 2; }
                glibc_max = argv[++i];
            } else if (strcmp(argv[i], "--profile") == 0) {
                if (i + 1 >= argc) { fprintf(stderr, "error: --profile requires an argument\n"); free(files); free(allow); return 2; }
                i++;
                if (strcmp(argv[i], "auto") == 0) {
                    profile_forced = 0;
                } else {
                    profile_forced = 1;
                    if (strcmp(argv[i], "static") == 0) profile = OB_PROFILE_S;
                    else if (strcmp(argv[i], "hybrid") == 0) profile = OB_PROFILE_H;
                    else if (strcmp(argv[i], "module") == 0) profile = OB_PROFILE_M;
                    else if (strcmp(argv[i], "universal") == 0) profile = OB_PROFILE_U;
                    else { fprintf(stderr, "error: --profile must be auto, static, hybrid, module, or universal\n"); free(files); free(allow); return 2; }
                }
            } else if (strcmp(argv[i], "--allow") == 0) {
                if (i + 1 >= argc) { fprintf(stderr, "error: --allow requires an argument\n"); free(files); free(allow); return 2; }
                allow[nallow++] = argv[++i];
            } else if (strcmp(argv[i], "--baseline") == 0) {
                if (i + 1 >= argc) { fprintf(stderr, "error: --baseline requires an argument\n"); free(files); free(allow); return 2; }
                baseline_path = argv[++i];
            } else if (strcmp(argv[i], "--write-baseline") == 0) {
                if (i + 1 >= argc) { fprintf(stderr, "error: --write-baseline requires an argument\n"); free(files); free(allow); return 2; }
                write_baseline_path = argv[++i];
            } else if (strcmp(argv[i], "--max-file") == 0) {
                if (i + 1 >= argc) { fprintf(stderr, "error: --max-file requires an argument\n"); free(files); free(allow); return 2; }
                max_file = atol(argv[++i]);
                if (max_file < 0) { fprintf(stderr, "error: --max-file must be non-negative\n"); free(files); free(allow); return 2; }
            } else if (strcmp(argv[i], "--strict") == 0) {
                strict = 1;
            } else if (strcmp(argv[i], "--quiet") == 0) {
                quiet = 1;
            } else if (strcmp(argv[i], "--verbose") == 0) {
                verbose = 1;
            } else if (strcmp(argv[i], "--no-color") == 0) {
                no_color = 1;
            } else if (argv[i][0] == '-' && strcmp(argv[i], "-") != 0) {
                fprintf(stderr, "error: unknown option '%s'\n", argv[i]);
                free(files); free(allow);
                return 2;
            } else {
                files[nfiles++] = argv[i];
            }
        }
        (void)max_file; /* accepted for grammar compatibility; per-file cap
                          * enforcement stays at ONEBIN_MAX_FILE until
                          * ob_audit_options grows a max_file field */
        if (nfiles == 0) {
            fprintf(stderr, "error: 'audit' requires at least one file path\n");
            free(files); free(allow);
            return 2;
        }

        ob_baseline bl;
        int have_baseline = 0;
        if (baseline_path) {
            if (ob_baseline_load(baseline_path, &bl) != OB_BASELINE_OK) {
                fprintf(stderr, "error: cannot read baseline '%s'\n", baseline_path);
                free(files); free(allow);
                return 2;
            }
            have_baseline = 1;
        }

        int use_color = !no_color && !use_json && !getenv("NO_COLOR") && isatty(fileno(stdout));

        if (write_baseline_path) {
            ob_finding_list all;
            ob_finding_list_init(&all);
            for (int fi = 0; fi < nfiles; fi++) {
                ob_audit_options opts;
                ob_audit_options_init(&opts);
                opts.file_path = files[fi];
                opts.level = level;
                opts.glibc_max = glibc_max;
                opts.strict = strict;
                opts.allow = allow; opts.nallow = (size_t)nallow;
                if (profile_forced) { opts.profile_forced = 1; opts.profile = profile; }

                ob_report r;
                ob_audit_file(&opts, &r);
                size_t n = ob_finding_list_count(&r.findings);
                for (size_t k = 0; k < n; k++) {
                    const ob_finding *fnd = ob_finding_list_at(&r.findings, k);
                    ob_finding_list_add(&all, fnd->id, fnd->check, fnd->severity, fnd->subject, fnd->message);
                }
                ob_report_free(&r);
            }
            ob_finding_list_sort_and_dedup(&all);
            if (ob_baseline_write(write_baseline_path, &all) != 0) {
                fprintf(stderr, "error: cannot write baseline '%s'\n", write_baseline_path);
                ob_finding_list_free(&all);
                if (have_baseline) ob_baseline_free(&bl);
                free(files); free(allow);
                return 2;
            }
            ob_finding_list_free(&all);
            if (have_baseline) ob_baseline_free(&bl);
            free(files); free(allow);
            return 0;
        }

        int worst = 0; /* 0 = all passed, 1 = a FAIL, 2 = a fatal */
        ob_jbuf jarr;
        if (use_json) {
            ob_jbuf_init(&jarr);
            ob_jbuf_puts(&jarr, nfiles > 1 ? "[\n" : "");
        }

        for (int fi = 0; fi < nfiles; fi++) {
            ob_audit_options opts;
            ob_audit_options_init(&opts);
            opts.file_path = files[fi];
            opts.level = level;
            opts.glibc_max = glibc_max;
            opts.strict = strict;
            opts.allow = allow; opts.nallow = (size_t)nallow;
            if (have_baseline) opts.baseline = &bl;
            if (profile_forced) {
                opts.profile_forced = 1;
                opts.profile = profile;
            }

            ob_report r;
            ob_audit_status st = ob_audit_file(&opts, &r);

            if (use_json) {
                ob_report_render_json(&r, &jarr, nfiles > 1 ? 1 : 0);
                ob_jbuf_puts(&jarr, fi + 1 < nfiles ? ",\n" : (nfiles > 1 ? "\n" : ""));
            } else {
                ob_jbuf out;
                ob_jbuf_init(&out);
                ob_report_render_text(&r, &out, verbose, quiet, use_color);
                fputs(out.data, stdout);
                ob_jbuf_free(&out);
            }

            if (st == OB_AUDIT_FATAL) {
                worst = 2;
            } else if (!r.passed && worst < 1) {
                worst = 1;
            }
            ob_report_free(&r);
        }

        if (use_json) {
            if (nfiles > 1) {
                ob_jbuf_puts(&jarr, "]\n");
            } else {
                ob_jbuf_putc(&jarr, '\n');
            }
            fputs(jarr.data, stdout);
            ob_jbuf_free(&jarr);
        }

        if (have_baseline) {
            ob_baseline_free(&bl);
        }
        free(files);
        free(allow);
        return worst;
    }

    fprintf(stderr, "error: unknown option or command '%s'\n", argv[1]);
    print_usage(stderr);
    return 2;
}
