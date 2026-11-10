package main

import (
	"errors"
	"log"
	"os"
	"strings"
)

// signInLogf logs sign-in progress (URLs without query strings, never cookie values) to stderr.
func signInLogf(format string, args ...any) { log.Printf("signin: "+format, args...) }

// autoSignIn starts the Google sign-in at launch when GOOB_AUTO_SIGNIN=1 (debugging aid).
var autoSignIn = os.Getenv("GOOB_AUTO_SIGNIN") == "1"

// Google sign-in: a native browser window (WebView2 on Windows, WebKitGTK on Linux) shows Google's own login page
// in a throwaway profile. When it lands on messages.google.com the Google cookies are read through the native
// cookie API (they are HttpOnly, so page JavaScript can't see them) and the window closes. libgm then pairs with
// the phone using those cookies (emoji confirmation).

const (
	signInURL   = "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fmessages.google.com%2Fweb%2F"
	cookieURI   = "https://messages.google.com/web/"
	signInTitle = "Sign in to Google"
	// WebKitGTK identifies as Safari, like Epiphany does for Google sign-in (Google rejects unknown embedded browsers).
	safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
)

var (
	errSignInCancelled = errors.New("sign-in was cancelled")
	errSignInFailed    = errors.New("couldn't read the Google sign-in")
)

// requiredCookies are what libgm needs to authenticate as the account (mautrix-gmessages' list).
var requiredCookies = []string{"SID", "HSID", "SSID", "APISID", "SAPISID"}

// isMessagesURL reports whether the sign-in browser reached Google Messages (sign-in finished).
func isMessagesURL(u string) bool {
	return strings.HasPrefix(u, "https://messages.google.com/")
}

// isGoogleCookieDomain keeps only cookies for google.com and its subdomains.
func isGoogleCookieDomain(domain string) bool {
	d := strings.TrimPrefix(strings.ToLower(domain), ".")
	return d == "google.com" || strings.HasSuffix(d, ".google.com")
}

// parseCookieLines decodes "name\tvalue\tdomain\n" lines from the native side and checks the result.
func parseCookieLines(s string) (map[string]string, bool) {
	out := map[string]string{}
	for _, line := range strings.Split(s, "\n") {
		parts := strings.SplitN(line, "\t", 3)
		if len(parts) != 3 || parts[0] == "" || !isGoogleCookieDomain(parts[2]) {
			continue
		}
		// Prefer the messages.google.com-scoped value if a name appears twice (e.g. OSID).
		if _, dup := out[parts[0]]; dup && !strings.Contains(parts[2], "messages.") {
			continue
		}
		out[parts[0]] = parts[1]
	}
	return out, hasRequiredCookies(out)
}

func hasRequiredCookies(c map[string]string) bool {
	for _, k := range requiredCookies {
		if c[k] == "" {
			return false
		}
	}
	return true
}
