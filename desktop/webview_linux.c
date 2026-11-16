// Keeps the main window's WebKitGTK view alive. Wails doesn't handle a crashed or hung web process, which leaves
// the window blank (or frozen) until the app is restarted. This finds the main web view and:
//  - reloads the page when the web process dies (crash, out of memory, or killed by us below);
//  - kills the web process if it stays unresponsive for HANG_SECONDS, so it gets reloaded.
// The Go side is authoritative, so a reload just re-fetches state from it (the open chat is lost, nothing else).
#include <gtk/gtk.h>
#include <webkit2/webkit2.h>
#include <string.h>
#include <stdarg.h>
#include "webview_linux.h"

extern void goWebviewLog(char *msg);

#define HANG_SECONDS 12
#define GUARD_KEY "goob-webview-guard"

static void wlog(const char *fmt, ...) G_GNUC_PRINTF(1, 2);
static void wlog(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    char *m = g_strdup_vprintf(fmt, ap);
    va_end(ap);
    goWebviewLog(m);
    g_free(m);
}

typedef struct {
    WebKitWebView *view;
    guint hang_timer;
    gint64 reload_times[4]; // recent reloads, to back off from a crash loop
} Guard;

static gboolean do_reload(gpointer data) {
    Guard *g = data;
    webkit_web_view_reload(g->view);
    return G_SOURCE_REMOVE;
}

static void on_terminated(WebKitWebView *view, WebKitWebProcessTerminationReason reason, gpointer data) {
    Guard *g = data;
    if (g->hang_timer) { g_source_remove(g->hang_timer); g->hang_timer = 0; }
    const char *why = reason == WEBKIT_WEB_PROCESS_CRASHED ? "crashed"
        : reason == WEBKIT_WEB_PROCESS_EXCEEDED_MEMORY_LIMIT ? "exceeded memory limit" : "was stopped (unresponsive)";
    // Four reloads within a minute means something keeps killing it: wait longer before the next try.
    gint64 now = g_get_monotonic_time();
    guint delay = 500;
    if (g->reload_times[0] && now - g->reload_times[0] < 60 * G_USEC_PER_SEC) delay = 15000;
    memmove(g->reload_times, g->reload_times + 1, sizeof(g->reload_times) - sizeof(gint64));
    g->reload_times[3] = now;
    wlog("web view process %s, reloading in %u ms", why, delay);
    g_timeout_add(delay, do_reload, g);
}

static gboolean on_hang_timeout(gpointer data) {
    Guard *g = data;
    g->hang_timer = 0;
    if (!webkit_web_view_get_is_web_process_responsive(g->view)) {
        wlog("web view unresponsive for %d s, restarting it", HANG_SECONDS);
        webkit_web_view_terminate_web_process(g->view); // emits web-process-terminated -> reload
    }
    return G_SOURCE_REMOVE;
}

static void on_responsive(GObject *obj, GParamSpec *pspec, gpointer data) {
    Guard *g = data;
    gboolean ok = webkit_web_view_get_is_web_process_responsive(g->view);
    if (!ok && !g->hang_timer) {
        wlog("web view stopped responding");
        g->hang_timer = g_timeout_add_seconds(HANG_SECONDS, on_hang_timeout, g);
    } else if (ok && g->hang_timer) {
        wlog("web view responding again");
        g_source_remove(g->hang_timer);
        g->hang_timer = 0;
    }
}

static WebKitWebView *find_view(GtkWidget *w) {
    if (WEBKIT_IS_WEB_VIEW(w)) return WEBKIT_WEB_VIEW(w);
    if (!GTK_IS_CONTAINER(w)) return NULL;
    WebKitWebView *found = NULL;
    GList *kids = gtk_container_get_children(GTK_CONTAINER(w));
    for (GList *l = kids; l && !found; l = l->next) found = find_view(l->data);
    g_list_free(kids);
    return found;
}

static int attempts;

static gboolean install(gpointer unused) {
    // The main window is the first toplevel holding a web view; the sign-in window doesn't exist yet at startup.
    GList *tops = gtk_window_list_toplevels();
    WebKitWebView *view = NULL;
    for (GList *l = tops; l && !view; l = l->next) view = find_view(l->data);
    g_list_free(tops);
    if (!view) {
        if (++attempts < 50) return G_SOURCE_CONTINUE; // retried every 200 ms
        wlog("web view guard: main web view not found");
        return G_SOURCE_REMOVE;
    }
    if (g_object_get_data(G_OBJECT(view), GUARD_KEY)) return G_SOURCE_REMOVE;
    Guard *g = g_new0(Guard, 1);
    g->view = view;
    g_object_set_data_full(G_OBJECT(view), GUARD_KEY, g, g_free);
    g_signal_connect(view, "web-process-terminated", G_CALLBACK(on_terminated), g);
    g_signal_connect(view, "notify::is-web-process-responsive", G_CALLBACK(on_responsive), g);
    return G_SOURCE_REMOVE;
}

void goob_webview_guard_start(void) {
    g_timeout_add(200, install, NULL); // thread-safe; runs on the GTK main loop
}
