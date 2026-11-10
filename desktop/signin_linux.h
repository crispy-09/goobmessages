#ifndef GOOB_SIGNIN_LINUX_H
#define GOOB_SIGNIN_LINUX_H
#include <stdint.h>
// Opens the sign-in window on the GTK main thread. Result arrives via goSignInResult(handle, cookies, ok).
void goob_signin_start(uintptr_t handle, const char *url, const char *cookie_uri, const char *user_agent, const char *title);
// Closes the window (cancel). Safe to call from any thread.
void goob_signin_close(uintptr_t handle);
#endif
