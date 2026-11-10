// Google sign-in window for Linux: WebKitGTK in an ephemeral (in-memory) context. When navigation reaches
// messages.google.com the cookies are read through WebKitCookieManager (they are HttpOnly) and handed to Go.
#include <gtk/gtk.h>
#include <webkit2/webkit2.h>
#include <string.h>
#include <stdarg.h>
#include "signin_linux.h"

extern void goSignInResult(uintptr_t handle, char *cookies, int ok);
extern void goSignInLog(char *msg);

static void slog(const char *fmt, ...) G_GNUC_PRINTF(1, 2);
static void slog(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    char *m = g_strdup_vprintf(fmt, ap);
    va_end(ap);
    goSignInLog(m);
    g_free(m);
}

// Log URLs without query strings (they can carry tokens).
static char *strip_query(const char *uri) {
    if (!uri) return g_strdup("(null)");
    const char *q = strpbrk(uri, "?#");
    return q ? g_strndup(uri, q - uri) : g_strdup(uri);
}

typedef struct {
    uintptr_t handle;
    char *url, *cookie_uri, *ua, *title;
    GtkWidget *window;
    WebKitWebView *view;
    gboolean finished;
    gboolean fetching;
    int attempts;
    guint retry_source;
    GCancellable *cancel;
} SignIn;

static void fetch_cookies(SignIn *s);
static gboolean close_idle(gpointer data);

static GHashTable *windows_by_handle; // handle -> SignIn*, only touched on the GTK thread

static void finish(SignIn *s, char *cookies, int ok) {
    if (s->finished) return;
    s->finished = TRUE;
    goSignInResult(s->handle, cookies, ok);
}

static gboolean retry_cb(gpointer data) {
    SignIn *s = data;
    s->retry_source = 0;
    fetch_cookies(s);
    return G_SOURCE_REMOVE;
}

static void on_cookies(GObject *src, GAsyncResult *res, gpointer data) {
    GError *err = NULL;
    GList *list = webkit_cookie_manager_get_cookies_finish(WEBKIT_COOKIE_MANAGER(src), res, &err);
    if (err && g_error_matches(err, G_IO_ERROR, G_IO_ERROR_CANCELLED)) { g_error_free(err); return; } // window gone: data is freed
    SignIn *s = data;
    s->fetching = FALSE;
    if (err) { slog("get_cookies failed: %s", err->message); g_error_free(err); return; }
    GString *out = g_string_new(NULL);
    GString *names = g_string_new(NULL);
    gboolean has_sapisid = FALSE;
    for (GList *l = list; l; l = l->next) {
        SoupCookie *c = l->data;
        const char *name = soup_cookie_get_name(c), *value = soup_cookie_get_value(c), *domain = soup_cookie_get_domain(c);
        if (!name || !value || !domain) continue;
        if (strpbrk(name, "\t\n") || strpbrk(value, "\t\n") || strpbrk(domain, "\t\n")) continue;
        if (strcmp(name, "SAPISID") == 0) has_sapisid = TRUE;
        g_string_append_printf(names, "%s%s@%s", names->len ? "," : "", name, domain);
        g_string_append_printf(out, "%s\t%s\t%s\n", name, value, domain);
    }
    g_list_free_full(list, (GDestroyNotify)soup_cookie_free);
    slog("cookies read (attempt %d), SAPISID %s: %s", s->attempts, has_sapisid ? "present" : "missing", names->str);
    g_string_free(names, TRUE);
    if (has_sapisid && !s->finished) {
        finish(s, out->str, 1);
        g_string_free(out, TRUE);
        g_idle_add(close_idle, (gpointer)s->handle);
        return;
    }
    g_string_free(out, TRUE);
    // Cookies can land a moment after the redirect: keep trying for ~20 s.
    if (!s->finished && s->attempts < 20 && !s->retry_source)
        s->retry_source = g_timeout_add(1000, retry_cb, s);
}

static void on_load_changed(WebKitWebView *view, WebKitLoadEvent event, gpointer data) {
    SignIn *s = data;
    const char *uri = webkit_web_view_get_uri(view);
    { char *u = strip_query(uri); slog("load-changed %d %s", (int)event, u); g_free(u); }
    if (event < WEBKIT_LOAD_COMMITTED || s->finished) return;
    if (!uri || strncmp(uri, "https://messages.google.com/", 28) != 0) return;
    fetch_cookies(s);
}

static void fetch_cookies(SignIn *s) {
    if (s->finished || s->fetching || !s->view) return;
    s->fetching = TRUE;
    s->attempts++;
    WebKitCookieManager *mgr = webkit_web_context_get_cookie_manager(webkit_web_view_get_context(s->view));
    webkit_cookie_manager_get_cookies(mgr, s->cookie_uri, s->cancel, on_cookies, s);
}

static gboolean on_load_failed(WebKitWebView *v, WebKitLoadEvent e, gchar *uri, GError *err, gpointer d) {
    char *u = strip_query(uri); slog("load-failed %s: %s", u, err ? err->message : "?"); g_free(u);
    return FALSE;
}
static void on_crashed(WebKitWebView *v, WebKitWebProcessTerminationReason r, gpointer d) {
    slog("web process terminated (reason %d)", (int)r);
}

// Popups (e.g. "Learn more") open in the same view instead of new windows.
static GtkWidget *on_create(WebKitWebView *view, WebKitNavigationAction *action, gpointer data) {
    WebKitURIRequest *req = webkit_navigation_action_get_request(action);
    if (req) webkit_web_view_load_uri(view, webkit_uri_request_get_uri(req));
    return NULL;
}

static void on_destroy(GtkWidget *w, gpointer data) {
    SignIn *s = data;
    if (s->retry_source) g_source_remove(s->retry_source);
    g_cancellable_cancel(s->cancel);
    g_object_unref(s->cancel);
    if (s->view) {
        // The view can outlive the window and keep emitting signals; they must never reach freed state.
        g_signal_handlers_disconnect_by_data(s->view, s);
        webkit_web_view_stop_loading(s->view);
        g_object_unref(s->view);
        s->view = NULL;
    }
    g_hash_table_remove(windows_by_handle, (gpointer)s->handle);
    finish(s, "", 0);
    g_free(s->url); g_free(s->cookie_uri); g_free(s->ua); g_free(s->title);
    g_free(s);
}

static gboolean start_idle(gpointer data) {
    SignIn *s = data;
    if (!windows_by_handle) windows_by_handle = g_hash_table_new(g_direct_hash, g_direct_equal);

    WebKitWebContext *ctx = webkit_web_context_new_ephemeral(); // nothing written to disk
    s->view = WEBKIT_WEB_VIEW(webkit_web_view_new_with_context(ctx));
    g_object_ref_sink(s->view); // our reference: lets on_destroy disconnect handlers safely
    g_object_unref(ctx);
    WebKitSettings *settings = webkit_web_view_get_settings(s->view);
    webkit_settings_set_user_agent(settings, s->ua);
    webkit_settings_set_enable_developer_extras(settings, FALSE);
    webkit_settings_set_javascript_can_open_windows_automatically(settings, FALSE);
    g_signal_connect(s->view, "load-changed", G_CALLBACK(on_load_changed), s);
    g_signal_connect(s->view, "create", G_CALLBACK(on_create), s);
    g_signal_connect(s->view, "load-failed", G_CALLBACK(on_load_failed), s);
    g_signal_connect(s->view, "web-process-terminated", G_CALLBACK(on_crashed), s);

    s->window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_title(GTK_WINDOW(s->window), s->title);
    gtk_window_set_default_size(GTK_WINDOW(s->window), 520, 720);
    gtk_window_set_position(GTK_WINDOW(s->window), GTK_WIN_POS_CENTER);
    gtk_container_add(GTK_CONTAINER(s->window), GTK_WIDGET(s->view));
    g_signal_connect(s->window, "destroy", G_CALLBACK(on_destroy), s);
    g_hash_table_insert(windows_by_handle, (gpointer)s->handle, s);

    webkit_web_view_load_uri(s->view, s->url);
    gtk_widget_show_all(s->window);
    gtk_window_present(GTK_WINDOW(s->window));
    return G_SOURCE_REMOVE;
}

void goob_signin_start(uintptr_t handle, const char *url, const char *cookie_uri, const char *user_agent, const char *title) {
    SignIn *s = g_new0(SignIn, 1);
    s->handle = handle;
    s->url = g_strdup(url);
    s->cookie_uri = g_strdup(cookie_uri);
    s->ua = g_strdup(user_agent);
    s->title = g_strdup(title);
    s->cancel = g_cancellable_new();
    g_idle_add(start_idle, s);
}

static gboolean close_idle(gpointer data) {
    uintptr_t handle = (uintptr_t)data;
    if (!windows_by_handle) return G_SOURCE_REMOVE;
    SignIn *s = g_hash_table_lookup(windows_by_handle, (gpointer)handle);
    if (s && s->window) gtk_widget_destroy(s->window);
    return G_SOURCE_REMOVE;
}

void goob_signin_close(uintptr_t handle) {
    g_idle_add(close_idle, (gpointer)handle);
}
