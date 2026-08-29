/*
 * gt-probe -- exercise everything GNOME Terminal pulls in, and prove it loaded.
 *
 * Why this exists
 * ---------------
 * Building GNOME Terminal statically is a multi-hour job. Almost every way it
 * can go wrong, however, is visible in seconds from a much smaller program that
 * links the same libraries and *uses* them: a soname that never got mapped, a
 * loadable module that came from the host instead of from us, a schema that
 * would not compile in, a font stack that shapes nothing, an app-id that hands
 * our window to somebody else's process.
 *
 * So this probe is deliberately not a hello-world. It links exactly GNOME
 * Terminal's own DT_NEEDED set and then drives each dependency hard enough that
 * a lazily-resolved or lazily-dlopen'd piece cannot stay unloaded and pass:
 *
 *   libvte-2.91  -- spawn a real child on a real PTY and check its exit status
 *   pcre2        -- compile a VteRegex, which is the only thing that pulls it
 *   libhandy-1   -- hdy_init + a real widget (GNOME Terminal's GTK3 adwaita)
 *   pango/HB/FT  -- shape mixed-script text and require non-zero ink extents
 *   gdk-pixbuf   -- encode a PNG, which forces a loader module to be dlopen'd
 *   GSettings    -- look up GNOME Terminal's own schemas, relocatable included
 *   libuuid      -- generate a profile UUID the way GNOME Terminal does
 *   GApplication -- register org.gnome.Terminal and report whether we were
 *                   answered by somebody else (the hijack in report I, §E)
 *
 * Then it reads /proc/self/maps and checks the result against a declared
 * contract file, which is the actual point: "everything loaded" is a
 * measurement, not a hope. Undeclared mappings are reported by name, because
 * that list *is* the host contract for this application and nobody has written
 * it down before.
 *
 * Exit codes:  0 = all assertions held   1 = an assertion failed
 *              2 = the environment could not answer the question (fail fast)
 *
 * Deliberately does NOT link libX11 directly even though GNOME Terminal does:
 * GTK3 brings it, and asserting on a mapping is stronger than asserting on a
 * link line we wrote ourselves.
 */

#define _GNU_SOURCE
#include <gtk/gtk.h>
#include <vte/vte.h>
#include <handy.h>
#include <gio/gio.h>
#include <uuid/uuid.h>
#include <pango/pangocairo.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------ */
/* reporting                                                          */
/* ------------------------------------------------------------------ */

static int  n_pass, n_fail, n_warn;
static FILE *report_fp;          /* optional second sink, for CI artifacts */
static gboolean strict_mode;

/* printf-style, but every call site here passes a literal first argument.
 * f4-diag lost a whole section to a format string that began with a dash
 * (05-REFERENCE-f4-qt.md); using fputs-style helpers with an explicit
 * format keeps that class out. */
static void emit(const char *line)
{
    fputs(line, stdout);
    fputc('\n', stdout);
    if (report_fp) { fputs(line, report_fp); fputc('\n', report_fp); }
}

static void emitf(const char *fmt, ...) G_GNUC_PRINTF(1, 2);
static void emitf(const char *fmt, ...)
{
    va_list ap; va_start(ap, fmt);
    char *s = g_strdup_vprintf(fmt, ap);
    va_end(ap);
    emit(s);
    g_free(s);
}

static void ok(const char *what, const char *detail)
{
    n_pass++;
    emitf("  ok    %-34s %s", what, detail ? detail : "");
}

static void bad(const char *what, const char *detail)
{
    n_fail++;
    emitf("  FAIL  %-34s %s", what, detail ? detail : "");
}

static void warn(const char *what, const char *detail)
{
    n_warn++;
    emitf("  warn  %-34s %s", what, detail ? detail : "");
}

/* ------------------------------------------------------------------ */
/* /proc/self/maps                                                     */
/* ------------------------------------------------------------------ */

/* Collect the basename of every mapped file that looks like a shared
 * object. Basename, not path: the contract is about sonames, and the
 * directory differs between a distro build and a bundled one -- which is
 * exactly the difference this whole project exists to make irrelevant. */
static GHashTable *read_mapped_sonames(void)
{
    GHashTable *set = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    FILE *f = fopen("/proc/self/maps", "r");
    if (!f) return set;
    char line[8192];
    while (fgets(line, sizeof line, f)) {
        char *slash = strchr(line, '/');
        if (!slash) continue;
        char *nl = strchr(slash, '\n');
        if (nl) *nl = '\0';
        if (!strstr(slash, ".so")) continue;
        char *base = g_path_get_basename(slash);
        if (!g_hash_table_contains(set, base)) g_hash_table_add(set, base);
        else g_free(base);
    }
    fclose(f);
    return set;
}

static GList *sorted_keys(GHashTable *set)
{
    GList *l = g_hash_table_get_keys(set);
    return g_list_sort(l, (GCompareFunc)g_strcmp0);
}

/* A contract entry matches a mapping if the mapping's basename starts with
 * the entry. "libvte-2.91.so.0" matches "libvte-2.91.so.0.7600.0", which is
 * what the loader actually maps. */
static const char *find_mapping(GHashTable *maps, const char *soname)
{
    GList *keys = sorted_keys(maps), *i;
    const char *hit = NULL;
    for (i = keys; i; i = i->next)
        if (g_str_has_prefix((const char *)i->data, soname)) { hit = i->data; break; }
    g_list_free(keys);
    return hit;
}

/* ------------------------------------------------------------------ */
/* contract file                                                       */
/* ------------------------------------------------------------------ */

typedef struct { GPtrArray *require, *allow; } Contract;

static Contract *contract_load(const char *path, GError **err)
{
    char *text = NULL;
    if (!g_file_get_contents(path, &text, NULL, err)) return NULL;
    Contract *c = g_new0(Contract, 1);
    c->require = g_ptr_array_new_with_free_func(g_free);
    c->allow   = g_ptr_array_new_with_free_func(g_free);
    char **lines = g_strsplit(text, "\n", -1);
    for (int i = 0; lines[i]; i++) {
        char *s = g_strstrip(lines[i]);
        if (!*s || *s == '#') continue;
        char **f = g_strsplit_set(s, " \t", 2);
        if (f[0] && f[1]) {
            char *v = g_strstrip(g_strdup(f[1]));
            if (!g_strcmp0(f[0], "require"))   g_ptr_array_add(c->require, v);
            else if (!g_strcmp0(f[0], "allow")) g_ptr_array_add(c->allow, v);
            else g_free(v);
        }
        g_strfreev(f);
    }
    g_strfreev(lines);
    g_free(text);
    return c;
}

/* ------------------------------------------------------------------ */
/* exercises                                                           */
/* ------------------------------------------------------------------ */

typedef struct { GMainLoop *loop; int status; gboolean spawned; char *err; } SpawnCtx;

static void on_child_exited(VteTerminal *t, int status, gpointer user)
{
    (void)t;
    SpawnCtx *c = user;
    c->status = status;
    g_main_loop_quit(c->loop);
}

static void on_spawned(VteTerminal *t, GPid pid, GError *error, gpointer user)
{
    (void)t; (void)pid;
    SpawnCtx *c = user;
    if (error) {
        c->err = g_strdup(error->message);
        g_main_loop_quit(c->loop);
        return;
    }
    c->spawned = TRUE;
}

static gboolean spawn_timeout(gpointer user)
{
    SpawnCtx *c = user;
    if (!c->err) c->err = g_strdup("timed out waiting for the child");
    g_main_loop_quit(c->loop);
    return G_SOURCE_REMOVE;
}

/* VTE on a real PTY. This is the single most load-bearing exercise here:
 * it is the only one that opens a pty, forks, and runs the terminal's own
 * main loop, so a VTE that linked but cannot actually spawn -- the shape a
 * broken static build takes -- is caught. Checked by exit status rather
 * than by reading back the screen, because vte_terminal_get_text_range has
 * churned across 0.72/0.76 and a probe that fails to compile next year
 * teaches nobody anything. */
static void exercise_vte(void)
{
    emit("");
    emit("== vte: real child on a real pty ==");

    emitf("  vte runtime %d.%d.%d, features: %s",
          vte_get_major_version(), vte_get_minor_version(),
          vte_get_micro_version(), vte_get_features());

    GtkWidget *term = vte_terminal_new();
    if (!term) { bad("vte_terminal_new", "returned NULL"); return; }
    g_object_ref_sink(term);

    /* Parent it into an offscreen window: VTE needs a realized widget with
     * a GdkWindow before it will size its pty, and an offscreen window
     * gives us that without mapping anything on the display. */
    GtkWidget *win = gtk_offscreen_window_new();
    gtk_container_add(GTK_CONTAINER(win), term);
    gtk_widget_show_all(win);

    SpawnCtx ctx = { g_main_loop_new(NULL, FALSE), -1, FALSE, NULL };
    g_signal_connect(term, "child-exited", G_CALLBACK(on_child_exited), &ctx);

    /* Exit 42: a value nothing else in the pipeline produces, so a false
     * pass cannot come from a shell that failed for its own reasons. */
    char *argv[] = { (char *)"/bin/sh", (char *)"-c", (char *)"exit 42", NULL };
    vte_terminal_spawn_async(VTE_TERMINAL(term), VTE_PTY_DEFAULT, NULL,
                             argv, NULL, G_SPAWN_DEFAULT,
                             NULL, NULL, NULL, 5000, NULL,
                             on_spawned, &ctx);

    guint to = g_timeout_add(10000, spawn_timeout, &ctx);
    g_main_loop_run(ctx.loop);
    g_source_remove(to);

    if (ctx.err) {
        bad("vte spawn", ctx.err);
    } else if (!ctx.spawned) {
        bad("vte spawn", "callback never reported success");
    } else if (WIFEXITED(ctx.status) && WEXITSTATUS(ctx.status) == 42) {
        ok("vte spawn + pty + child-exited", "child exited 42 as asked");
    } else {
        emitf("  FAIL  %-34s raw wait status %d", "vte child status", ctx.status);
        n_fail++;
    }

    /* PCRE2 is reachable from nothing else in this program, and in GNOME
     * Terminal itself only from search. If pcre2 failed to link in, this is
     * where it shows. */
    /* VTE *requires* the multiline flag on a search regex and prints a
     * runtime-check warning without it -- found by running this probe, not
     * by reading the header. The constant is spelled out rather than taken
     * from pcre2.h so the probe does not additionally depend on pcre2-dev,
     * which need not be installed: VTE is what links pcre2. The value is
     * part of PCRE2's stable public ABI. */
#define GT_PCRE2_MULTILINE 0x00000400u
    GError *e = NULL;
    VteRegex *re = vte_regex_new_for_search("\\bmarker[0-9]+\\b", -1,
                                            GT_PCRE2_MULTILINE, &e);
    if (re) {
        vte_terminal_search_set_regex(VTE_TERMINAL(term), re, 0);
        ok("pcre2 via VteRegex", "compiled and installed a search regex");
        vte_regex_unref(re);
    } else {
        bad("pcre2 via VteRegex", e ? e->message : "unknown error");
    }
    g_clear_error(&e);

    g_main_loop_unref(ctx.loop);
    g_free(ctx.err);
    gtk_widget_destroy(win);
    g_object_unref(term);
}

static void exercise_handy(void)
{
    emit("");
    emit("== libhandy: GNOME Terminal's GTK3 adwaita ==");
    hdy_init();
    GtkWidget *hb = hdy_header_bar_new();
    if (!hb) { bad("hdy_header_bar_new", "returned NULL"); return; }
    g_object_ref_sink(hb);
    hdy_header_bar_set_title(HDY_HEADER_BAR(hb), "probe");
    const char *t = hdy_header_bar_get_title(HDY_HEADER_BAR(hb));
    if (!g_strcmp0(t, "probe")) ok("libhandy widget round-trip", "hdy_init + HdyHeaderBar");
    else                        bad("libhandy widget round-trip", "title did not round-trip");
    g_object_unref(hb);
}

/* Mixed scripts on purpose: Latin needs nothing special, Cyrillic needs the
 * font to actually have the coverage, and the combining mark needs HarfBuzz
 * to do real work. Zero ink extents means the font stack resolved to
 * nothing, which is the classic symptom of a bundled fontconfig that was
 * not pointed at the host's fonts (Layer 2 in the manifesto). */
static void exercise_text(void)
{
    emit("");
    emit("== pango / harfbuzz / freetype / fontconfig ==");
    cairo_surface_t *surf = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 400, 80);
    cairo_t *cr = cairo_create(surf);
    PangoLayout *lay = pango_cairo_create_layout(cr);
    pango_layout_set_text(lay, "Terminal Терминал é\xcc\x81 123", -1);
    PangoFontDescription *fd = pango_font_description_from_string("Monospace 12");
    pango_layout_set_font_description(lay, fd);

    int w = 0, h = 0;
    pango_layout_get_pixel_size(lay, &w, &h);
    if (w > 0 && h > 0) {
        char *d = g_strdup_printf("shaped to %dx%d px", w, h);
        ok("pango shaping produces ink", d);
        g_free(d);
    } else {
        bad("pango shaping produces ink",
            "zero extents -- no usable font resolved (check host font paths)");
    }

    PangoContext *pctx = pango_layout_get_context(lay);
    PangoFontMap *fm = pango_context_get_font_map(pctx);
    char *fmname = g_strdup(G_OBJECT_TYPE_NAME(fm));
    emitf("  font map: %s", fmname);
    g_free(fmname);

    pango_font_description_free(fd);
    g_object_unref(lay);
    cairo_destroy(cr);
    cairo_surface_destroy(surf);
}

/* Encoding a PNG is what forces gdk-pixbuf to dlopen a loader module. Just
 * listing the formats does not: the format list is built from the module
 * *cache file*, and a build with a stale or host-provided cache will list
 * formats it cannot actually use. Asking for real bytes back closes that. */
static void exercise_pixbuf(void)
{
    emit("");
    emit("== gdk-pixbuf loader modules ==");
    GSList *formats = gdk_pixbuf_get_formats();
    emitf("  %u formats registered", g_slist_length(formats));
    g_slist_free(formats);

    GdkPixbuf *pb = gdk_pixbuf_new(GDK_COLORSPACE_RGB, TRUE, 8, 4, 4);
    if (!pb) { bad("gdk_pixbuf_new", "returned NULL"); return; }
    gdk_pixbuf_fill(pb, 0x336699ff);

    gchar *buf = NULL; gsize len = 0; GError *e = NULL;
    if (gdk_pixbuf_save_to_buffer(pb, &buf, &len, "png", &e, NULL) && len > 8) {
        char *d = g_strdup_printf("encoded %zu bytes through the png module", (size_t)len);
        ok("gdk-pixbuf module actually runs", d);
        g_free(d);
    } else {
        bad("gdk-pixbuf module actually runs", e ? e->message : "no bytes produced");
    }
    g_clear_error(&e);
    g_free(buf);
    g_object_unref(pb);
}

/* GNOME Terminal keeps its profiles in a *relocatable* schema, instantiated
 * once per profile UUID. That is the awkward case for a bundled build: the
 * schema must be present in our own schema source and the path is composed
 * at runtime. If a static build ships only the non-relocatable schemas this
 * is where it fails, and it fails at the moment the user opens preferences
 * rather than at startup -- so it is worth a check of its own. */
static void exercise_schemas(void)
{
    emit("");
    emit("== GSettings: GNOME Terminal's own schemas ==");
    GSettingsSchemaSource *src = g_settings_schema_source_get_default();
    if (!src) { bad("schema source", "no default schema source at all"); return; }

    static const char *fixed[] = {
        "org.gnome.Terminal.Legacy.Settings",
        "org.gnome.Terminal.ProfilesList",
        NULL
    };
    for (int i = 0; fixed[i]; i++) {
        GSettingsSchema *s = g_settings_schema_source_lookup(src, fixed[i], TRUE);
        if (s) { ok("schema present", fixed[i]); g_settings_schema_unref(s); }
        else     bad("schema MISSING", fixed[i]);
    }

    const char *relo = "org.gnome.Terminal.Legacy.Profile";
    GSettingsSchema *s = g_settings_schema_source_lookup(src, relo, TRUE);
    if (!s) { bad("relocatable schema MISSING", relo); return; }

    /* A UUID exactly the way GNOME Terminal makes one, then the path it
     * would build from it. Exercises libuuid at the same time. */
    uuid_t u; char uustr[37];
    uuid_generate(u);
    uuid_unparse_lower(u, uustr);
    char *path = g_strdup_printf(
        "/org/gnome/terminal/legacy/profiles:/:%s/", uustr);

    GSettings *prof = g_settings_new_full(s, NULL, path);
    gchar **keys = g_settings_schema_list_keys(s);
    guint nkeys = keys ? g_strv_length(keys) : 0;
    char *d = g_strdup_printf("%u keys, instantiated at %s", nkeys, path);
    if (prof && nkeys > 0) ok("relocatable profile schema", d);
    else                   bad("relocatable profile schema", d);
    g_free(d);

    g_strfreev(keys);
    g_free(path);
    g_clear_object(&prof);
    g_settings_schema_unref(s);

    /* Which backend answered. GSettingsBackend is a GIO extension point, so
     * on a host with dconf installed this is where a bundled GIO would
     * dlopen the host's libdconfsettings.so -- the two-glib path measured in
     * probe report I, D1. Reported, not asserted: both answers are
     * legitimate, but you must know which one you got. */
    GSettings *legacy = g_settings_new("org.gnome.Terminal.Legacy.Settings");
    GSettingsBackend *be = NULL;
    g_object_get(legacy, "backend", &be, NULL);
    emitf("  settings backend: %s", be ? G_OBJECT_TYPE_NAME(be) : "(unknown)");
    g_clear_object(&be);
    g_object_unref(legacy);
}

/* org.gnome.Terminal is a D-Bus-activated, single-instance application.
 * A bundled build carrying the same app-id will silently be answered by the
 * host's already-running gnome-terminal-server: the user launches our binary
 * and gets theirs, with no error anywhere. Measured in probe report I, §E.
 * Reported by default and fatal under --strict, because in CI there is no
 * host server and being remote there means something is genuinely wrong. */
static void exercise_appid(void)
{
    emit("");
    emit("== GApplication app-id ==");
    GApplication *app = g_application_new("org.gnome.Terminal",
                                          G_APPLICATION_DEFAULT_FLAGS);
    GError *e = NULL;
    if (!g_application_register(app, NULL, &e)) {
        warn("app-id registration failed", e ? e->message : "unknown");
        g_clear_error(&e);
        g_object_unref(app);
        return;
    }
    gboolean remote = g_application_get_is_remote(app);
    if (!remote) {
        ok("app-id org.gnome.Terminal", "we own it; no hijack");
    } else if (strict_mode) {
        bad("app-id org.gnome.Terminal",
            "answered by another process -- a bundled build would hand its window away");
    } else {
        warn("app-id org.gnome.Terminal",
             "answered by another process (a gnome-terminal-server is running)");
    }
    g_object_unref(app);
}

/* ------------------------------------------------------------------ */
/* the contract check                                                  */
/* ------------------------------------------------------------------ */

static void check_contract(Contract *c, GHashTable *before, GHashTable *after)
{
    emit("");
    emit("== contract: everything required is mapped ==");

    for (guint i = 0; i < c->require->len; i++) {
        const char *want = g_ptr_array_index(c->require, i);
        const char *hit = find_mapping(after, want);
        if (hit) ok(want, hit);
        else     bad(want, "NOT MAPPED after the exercise");
    }

    emit("");
    emit("== dlopen delta: mapped only after gtk_init ==");
    GList *keys = sorted_keys(after), *i;
    guint n_delta = 0;
    for (i = keys; i; i = i->next) {
        if (g_hash_table_contains(before, i->data)) continue;
        n_delta++;
        emitf("    %s", (const char *)i->data);
    }
    if (n_delta == 0) emit("    (none -- suspicious; the GPU/driver stack normally appears here)");
    g_list_free(keys);

    emit("");
    emit("== undeclared mappings ==");
    keys = sorted_keys(after);
    guint n_undecl = 0;
    for (i = keys; i; i = i->next) {
        const char *m = i->data;
        gboolean known = FALSE;
        for (guint j = 0; !known && j < c->require->len; j++)
            known = g_str_has_prefix(m, g_ptr_array_index(c->require, j));
        for (guint j = 0; !known && j < c->allow->len; j++)
            known = g_str_has_prefix(m, g_ptr_array_index(c->allow, j));
        if (known) continue;
        n_undecl++;
        emitf("    %s", m);
    }
    g_list_free(keys);
    if (n_undecl == 0) {
        ok("no undeclared mappings", "");
    } else {
        char *d = g_strdup_printf("%u mapping(s) not in the contract file", n_undecl);
        if (strict_mode) bad("undeclared mappings", d);
        else             warn("undeclared mappings", d);
        g_free(d);
    }
}

/* ------------------------------------------------------------------ */

static void usage(void)
{
    fputs("usage: gt-probe [--contract FILE] [--report FILE] [--strict]\n"
          "\n"
          "  --contract FILE  declared soname contract (require/allow lines)\n"
          "  --report FILE    also write the report here, for CI artifacts\n"
          "  --strict         undeclared mappings and an app-id hijack are errors\n",
          stderr);
}

int main(int argc, char **argv)
{
    const char *contract_path = NULL, *report_path = NULL;

    for (int i = 1; i < argc; i++) {
        if (!g_strcmp0(argv[i], "--contract") && i + 1 < argc) contract_path = argv[++i];
        else if (!g_strcmp0(argv[i], "--report") && i + 1 < argc) report_path = argv[++i];
        else if (!g_strcmp0(argv[i], "--strict")) strict_mode = TRUE;
        else if (!g_strcmp0(argv[i], "--help")) { usage(); return 0; }
        else { usage(); return 2; }
    }

    if (report_path) {
        report_fp = fopen(report_path, "w");
        if (!report_fp) {
            fprintf(stderr, "gt-probe: cannot write report to %s\n", report_path);
            return 2;
        }
    }

    Contract *contract = NULL;
    if (contract_path) {
        GError *e = NULL;
        contract = contract_load(contract_path, &e);
        if (!contract) {
            fprintf(stderr, "gt-probe: %s\n", e ? e->message : "cannot read contract");
            return 2;   /* fail fast: without the contract there is no question to answer */
        }
    }

    emit("== gt-probe: GNOME Terminal dependency load probe ==");
    emitf("  gtk %d.%d.%d  glib %d.%d.%d",
          gtk_get_major_version(), gtk_get_minor_version(), gtk_get_micro_version(),
          glib_major_version, glib_minor_version, glib_micro_version);

    GHashTable *before = read_mapped_sonames();

    if (!gtk_init_check(NULL, NULL)) {
        /* Fail fast and say which of the two it is, because the remedies are
         * completely different: no display is an environment problem, a
         * broken GTK is a build problem. */
        fprintf(stderr,
                "gt-probe: gtk_init_check failed. DISPLAY=%s WAYLAND_DISPLAY=%s\n"
                "          Run under xvfb-run if this is a headless machine.\n",
                g_getenv("DISPLAY") ? g_getenv("DISPLAY") : "(unset)",
                g_getenv("WAYLAND_DISPLAY") ? g_getenv("WAYLAND_DISPLAY") : "(unset)");
        return 2;
    }

    exercise_handy();
    exercise_text();
    exercise_pixbuf();
    exercise_vte();
    exercise_schemas();
    exercise_appid();

    GHashTable *after = read_mapped_sonames();

    if (contract) check_contract(contract, before, after);
    else {
        emit("");
        emit("== mapped sonames (no contract given) ==");
        GList *keys = sorted_keys(after), *i;
        for (i = keys; i; i = i->next) emitf("    %s", (const char *)i->data);
        g_list_free(keys);
    }

    emit("");
    emitf("== gt-probe: %d passed, %d failed, %d warnings ==", n_pass, n_fail, n_warn);

    g_hash_table_destroy(before);
    g_hash_table_destroy(after);
    if (report_fp) fclose(report_fp);
    return n_fail ? 1 : 0;
}
