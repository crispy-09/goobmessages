package urlsafe

import (
	"net"
	"testing"
)

func TestPublicHTTPS(t *testing.T) {
	bad := []string{
		"http://lh3.googleusercontent.com/abc", "https://192.168.0.2/a", "https://0x7f.0.0.1/", "https://127.1/",
		"https://017.0.0.1/", "https://2130706433/", "https://100.64.0.1/", "https://198.18.0.1/",
		"https://localhost./", "https://foo.localhost/", "https://router.home.arpa/", "https://a..b/",
		"https://1.2.3.256/", "https://0.0.0.0/", "https://[::1]/", "https://user@example.com/",
		"https://example.com:8443/", "https://intranet/", "javascript:alert(1)", "file:///etc/passwd",
		"https://ex%61mple.com/", "https://éxample.com/",
	}
	for _, u := range bad {
		if IsPublicHTTPS(u) {
			t.Errorf("%s should be rejected", u)
		}
	}
	good := []string{"https://lh3.googleusercontent.com/abc", "https://8.8.8.8/", "https://www.example.com./x",
		"https://123.example.com/", "https://example.com:443/"}
	for _, u := range good {
		if !IsPublicHTTPS(u) {
			t.Errorf("%s should be allowed", u)
		}
	}
}

func TestGoogleOwned(t *testing.T) {
	if !IsGoogleOwned("https://lh3.googleusercontent.com/abc") {
		t.Error("googleusercontent should be google-owned")
	}
	for _, u := range []string{"https://evilgoogle.com/abc", "https://google.com.evil.net/", "https://x/google.com"} {
		if IsGoogleOwned(u) {
			t.Errorf("%s is not google-owned", u)
		}
	}
}

func TestOpenableLink(t *testing.T) {
	for _, u := range []string{"https://example.com", "http://example.com/a?b", "mailto:a@b.c", "tel:+15555550100"} {
		if !IsOpenableLink(u) {
			t.Errorf("%s should open", u)
		}
	}
	for _, u := range []string{"javascript:alert(1)", "file:///etc/passwd", "data:text/html,x", "smb://host/share",
		"https://user:pw@example.com", "vbscript:x", "ms-settings:", "https:///nohost"} {
		if IsOpenableLink(u) {
			t.Errorf("%s must not open", u)
		}
	}
}

func TestPublicIP(t *testing.T) {
	cases := map[string]bool{
		"8.8.8.8": true, "2606:4700::1111": true, "127.0.0.1": false, "10.1.2.3": false, "192.168.0.1": false,
		"169.254.169.254": false, "::1": false, "::": false, "fe80::1": false, "fd00::1": false, "ff02::1": false,
		"::ffff:127.0.0.1": false, "::ffff:8.8.8.8": true, "64:ff9b::a00:1": false, "2002:c0a8:0101::1": false,
		"100.64.0.1": false,
	}
	for s, want := range cases {
		if got := IsPublicIP(net.ParseIP(s)); got != want {
			t.Errorf("IsPublicIP(%s) = %v, want %v", s, got, want)
		}
	}
}
