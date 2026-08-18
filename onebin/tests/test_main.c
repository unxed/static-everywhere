#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <signal.h>
#include "test.h"

/* This harness forks a child process per test for crash isolation (a
 * SIGSEGV in one test must not take down the whole suite), and every child
 * terminates via _exit() rather than returning from main() — which is
 * exactly the path gcov's atexit-registered counter flush never runs.
 * Without this, `make coverage` reports 0% for every line, because every
 * line of library code only ever executes inside a child that _exit()s.
 * __gcov_dump() flushes explicitly; GCC's runtime merges (sums) into the
 * shared .gcda file rather than overwriting it, so sequential children
 * accumulate correctly. Only declared/called when ONEBIN_COVERAGE is
 * defined (the Makefile's `coverage` target defines it) — the symbol does
 * not exist in a non-instrumented build. */
#ifdef ONEBIN_COVERAGE
extern void __gcov_dump(void);
#define OB_GCOV_DUMP() __gcov_dump()
#else
#define OB_GCOV_DUMP() ((void)0)
#endif

test_case_t *g_test_list_head = NULL;
test_case_t *g_test_list_tail = NULL;

static int g_pipe_out_fd = -1;

void test_register(const char *name, test_fn_t fn, const char *file, int line) {
    test_case_t *tc = (test_case_t *)malloc(sizeof(test_case_t));
    if (!tc) {
        perror("malloc");
        exit(1);
    }
    tc->name = name;
    tc->fn = fn;
    tc->file = file;
    tc->line = line;
    tc->next = NULL;

    if (!g_test_list_head) {
        g_test_list_head = tc;
        g_test_list_tail = tc;
    } else {
        g_test_list_tail->next = tc;
        g_test_list_tail = tc;
    }
}

void test_fail(const char *file, int line, const char *msg) {
    if (g_pipe_out_fd >= 0) {
        char buf[1024];
        int len = snprintf(buf, sizeof(buf), "FAIL:%s:%d:%s\n", file, line, msg);
        if (len > 0) {
            ssize_t written = write(g_pipe_out_fd, buf, (size_t)len);
            (void)written;
        }
    }
    OB_GCOV_DUMP();
    _exit(1);
}

void test_skip(const char *file, int line, const char *msg) {
    (void)file;
    (void)line;
    if (g_pipe_out_fd >= 0) {
        char buf[1024];
        int len = snprintf(buf, sizeof(buf), "SKIP:%s\n", msg);
        if (len > 0) {
            ssize_t written = write(g_pipe_out_fd, buf, (size_t)len);
            (void)written;
        }
    }
    OB_GCOV_DUMP();
    _exit(77);
}

static void free_registered_tests(void) {
    test_case_t *cur = g_test_list_head;
    while (cur) {
        test_case_t *next = cur->next;
        free(cur);
        cur = next;
    }
    g_test_list_head = NULL;
    g_test_list_tail = NULL;
}

int main(int argc, char **argv) {
    const char *filter = NULL;
    bool list_only = false;
    bool verbose = false;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--list") == 0) {
            list_only = true;
        } else if (strcmp(argv[i], "--verbose") == 0 || strcmp(argv[i], "-v") == 0) {
            verbose = true;
        } else if (strcmp(argv[i], "--filter") == 0 && i + 1 < argc) {
            filter = argv[++i];
        }
    }

    if (list_only) {
        for (test_case_t *tc = g_test_list_head; tc; tc = tc->next) {
            printf("%s\n", tc->name);
        }
        free_registered_tests();
        return 0;
    }

    int total_passed = 0;
    int total_failed = 0;
    int total_skipped = 0;

    for (test_case_t *tc = g_test_list_head; tc; tc = tc->next) {
        if (filter && strstr(tc->name, filter) == NULL) {
            continue;
        }

        int pfd[2];
        if (pipe(pfd) != 0) {
            perror("pipe");
            free_registered_tests();
            return 1;
        }

        pid_t pid = fork();
        if (pid < 0) {
            perror("fork");
            close(pfd[0]);
            close(pfd[1]);
            free_registered_tests();
            return 1;
        }

        if (pid == 0) {
            close(pfd[0]);
            g_pipe_out_fd = pfd[1];
            alarm(10);
            tc->fn();
            close(pfd[1]);
            OB_GCOV_DUMP();
            _exit(0);
        }

        close(pfd[1]);

        char msg_buf[1024] = {0};
        ssize_t n = read(pfd[0], msg_buf, sizeof(msg_buf) - 1);
        if (n > 0) {
            msg_buf[n] = '\0';
        }
        close(pfd[0]);

        int status = 0;
        waitpid(pid, &status, 0);

        if (WIFEXITED(status)) {
            int code = WEXITSTATUS(status);
            if (code == 0) {
                total_passed++;
                if (verbose) {
                    printf("  PASS  %s\n", tc->name);
                }
            } else if (code == 77) {
                total_skipped++;
                const char *reason = "unknown reason";
                if (strncmp(msg_buf, "SKIP:", 5) == 0) {
                    char *nl = strchr(msg_buf + 5, '\n');
                    if (nl) *nl = '\0';
                    reason = msg_buf + 5;
                }
                printf("  SKIP  %s (%s)\n", tc->name, reason);
            } else {
                total_failed++;
                printf("  FAIL  %s\n", tc->name);
                if (strncmp(msg_buf, "FAIL:", 5) == 0) {
                    printf("        %s", msg_buf + 5);
                }
            }
        } else if (WIFSIGNALED(status)) {
            total_failed++;
            int sig = WTERMSIG(status);
            if (sig == SIGALRM) {
                printf("  FAIL  %s (timeout / hung)\n", tc->name);
            } else if (sig == SIGSEGV) {
                printf("  FAIL  %s (SIGSEGV / segmentation fault)\n", tc->name);
            } else if (sig == SIGABRT) {
                printf("  FAIL  %s (SIGABRT / aborted)\n", tc->name);
            } else {
                printf("  FAIL  %s (terminated with signal %d)\n", tc->name, sig);
            }
        }
    }

    printf("\n%d passed, %d failed, %d skipped\n", total_passed, total_failed, total_skipped);
    free_registered_tests();

    return (total_failed > 0) ? 1 : 0;
}
