/* audit/checks/c_host.c — 01-SPEC-audit.md §7.7. 00-AGENT-TASK.md Task 8.
 *
 * Two pattern checks, both implemented by hand (the spec insists: "Do not
 * write a regex engine"):
 *   - OB0070: the string starts with one of the known host-contract
 *     library names (a plain, anchored prefix check).
 *   - OB0071: the string matches ^lib[A-Za-z0-9_+.-]+\.so(\.[0-9]+)*$ and
 *     is neither on that list nor an actual DT_NEEDED entry nor on the
 *     needed-allowlist. Matched by stripping trailing ".<digits>" groups
 *     from the end, then requiring exactly ".so" and >=1 name byte before
 *     it — see match_dlopen_pattern()'s comment for why this is equivalent
 *     to the regex for every case that matters here.
 */
#include "audit/checks.h"
#include "elf/strings.h"
#include "util/limits.h"

#include <stdio.h>
#include <string.h>

#define OB0071_CAP 20

/* GPU/audio (the original fifteen) plus windowing/desktop-integration
 * sonames added building far2l-sdl (contrib/far2l/deps.lock's SDL2
 * entry): SDL2's SDL_X11_SHARED/SDL_WAYLAND_SHARED design dlopens its
 * windowing backend rather than linking it, so a real GUI reference
 * build needs these recognized too, not just GPU/audio. See
 * 01-SPEC-audit.md §7.7 for the full rationale. */
static const char *const KNOWN_HOST_LIBS[] = {
    "libGL.so", "libGLX.so", "libGLESv2.so", "libEGL.so", "libOpenGL.so",
    "libvulkan.so", "libcuda.so", "libnvidia-ml.so",
    "libOpenCL.so", "libva.so", "libvdpau.so",
    "libasound.so", "libpulse.so", "libpipewire-0.3.so", "libjack.so",
    "libudev.so",
    "libGLES_CM.so", "libGLESv1_CM.so",
    "libX11.so", "libX11-xcb.so", "libXext.so", "libXcursor.so",
    "libXfixes.so", "libXrandr.so", "libXss.so", "libXi.so",
    "libwayland-client.so", "libwayland-cursor.so", "libwayland-egl.so",
    "libxkbcommon.so",
    "libdbus-1.so",
};
#define N_KNOWN_HOST_LIBS (sizeof(KNOWN_HOST_LIBS) / sizeof(KNOWN_HOST_LIBS[0]))

static int class_byte_ok(char c) {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
           (c >= '0' && c <= '9') || c == '_' || c == '+' || c == '.' || c == '-';
}

/* ^lib[A-Za-z0-9_+.-]+\.so(\.[0-9]+)*$
 *
 * Strip trailing ".<digits>" groups one at a time from the end (each one
 * only if every byte after that '.' to the current end is a digit and
 * there is at least one). What remains must end in exactly ".so", with at
 * least one class-valid byte between "lib" and that ".so". Because the
 * character class already includes '.', this never needs to backtrack: a
 * numeric group can only ever be a *trailing* group (its content is pure
 * digits, so it can never itself contain the ".so" the match requires),
 * so stripping greedily from the end and stopping at the first
 * non-all-digit trailing group lands on the same split the regex would. */
static int matches_dlopen_pattern(const char *s, size_t len) {
    if (len < 3 || memcmp(s, "lib", 3) != 0) {
        return 0;
    }
    size_t end = len;
    for (;;) {
        if (end < 2) {
            break;
        }
        size_t dot = end; /* search for the last '.' strictly before `end` */
        for (size_t i = end; i > 0; i--) {
            if (s[i - 1] == '.') {
                dot = i - 1;
                break;
            }
        }
        if (dot == end) {
            break; /* no '.' found */
        }
        size_t digits = end - (dot + 1);
        if (digits == 0) {
            break;
        }
        int all_digits = 1;
        for (size_t i = dot + 1; i < end; i++) {
            if (s[i] < '0' || s[i] > '9') {
                all_digits = 0;
                break;
            }
        }
        if (!all_digits) {
            break;
        }
        end = dot;
    }

    if (end < 3 + 1 + 3) { /* "lib" + >=1 name byte + ".so" */
        return 0;
    }
    if (s[end - 3] != '.' || s[end - 2] != 's' || s[end - 1] != 'o') {
        return 0;
    }
    for (size_t i = 3; i < end - 3; i++) {
        if (!class_byte_ok(s[i])) {
            return 0;
        }
    }
    return 1;
}

typedef struct {
    const ob_check_ctx *ctx;
    ob_report *r;
    size_t     ob0071_reported;
    size_t     ob0071_total;
} scan_state;

static int is_needed(const ob_check_ctx *ctx, const char *s, size_t len) {
    if (!ctx->dyn) {
        return 0;
    }
    for (size_t i = 0; i < ctx->dyn->nneeded; i++) {
        char other[ONEBIN_MAX_STRING + 1];
        if (ob_dynamic_string(ctx->img, ctx->dyn, ctx->dyn->needed[i], other, sizeof(other)) != OB_STR_OK) {
            continue;
        }
        if (strlen(other) == len && memcmp(other, s, len) == 0) {
            return 1;
        }
    }
    return 0;
}

static int is_allowlisted(const ob_check_ctx *ctx, const char *s, size_t len) {
    for (size_t i = 0; i < OB_N_DEFAULT_ALLOWLIST; i++) {
        size_t l = strlen(OB_DEFAULT_ALLOWLIST[i]);
        if (l == len && memcmp(OB_DEFAULT_ALLOWLIST[i], s, len) == 0) {
            return 1;
        }
    }
    for (size_t i = 0; i < ctx->nallow; i++) {
        size_t l = strlen(ctx->allow[i]);
        if (l == len && memcmp(ctx->allow[i], s, len) == 0) {
            return 1;
        }
    }
    return 0;
}

static void host_cb(const char *s, size_t len, size_t off, void *user) {
    (void)off;
    scan_state *st = (scan_state *)user;

    for (size_t i = 0; i < N_KNOWN_HOST_LIBS; i++) {
        size_t plen = strlen(KNOWN_HOST_LIBS[i]);
        if (len >= plen && memcmp(s, KNOWN_HOST_LIBS[i], plen) == 0) {
            char subj[ONEBIN_MAX_STRING + 1];
            size_t n = len < ONEBIN_MAX_STRING ? len : ONEBIN_MAX_STRING;
            memcpy(subj, s, n);
            subj[n] = '\0';
            ob_report_add_finding(st->r, "OB0070", "host.known_lib", OB_SEV_INFO, subj,
                                   "matches the host contract");
            return;
        }
    }

    if (!matches_dlopen_pattern(s, len)) {
        return;
    }
    if (is_needed(st->ctx, s, len) || is_allowlisted(st->ctx, s, len)) {
        return;
    }

    st->ob0071_total++;
    if (st->ob0071_reported >= OB0071_CAP) {
        return;
    }
    char subj[ONEBIN_MAX_STRING + 1];
    size_t n = len < ONEBIN_MAX_STRING ? len : ONEBIN_MAX_STRING;
    memcpy(subj, s, n);
    subj[n] = '\0';
    ob_report_add_finding(st->r, "OB0071", "host.unlisted_dlopen", OB_SEV_WARN, subj,
                           "appears to dlopen a library outside the host contract");
    st->ob0071_reported++;
}

void ob_check_host(const ob_check_ctx *ctx, ob_report *r) {
    if (!ctx || !ctx->img || !r) {
        return;
    }

    scan_state st = { ctx, r, 0, 0 };
    ob_strings_scan(&ctx->img->buf, host_cb, &st);

    if (st.ob0071_total > OB0071_CAP) {
        char msg[96];
        snprintf(msg, sizeof(msg), "%zu unlisted libraries total; showing the first %d",
                 st.ob0071_total, OB0071_CAP);
        ob_report_add_finding(r, "OB0071", "host.unlisted_dlopen", OB_SEV_WARN, "", msg);
    }
}
