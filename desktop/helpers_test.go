package main

import (
	"strings"
	"testing"
)

func TestSanitizeFilename(t *testing.T) {
	cases := map[string]string{
		"../../etc/passwd":       "passwd",
		`..\..\Windows\evil.exe`: "evil.exe",
		"photo.jpg":              "photo.jpg",
		".bashrc":                "bashrc",
		"":                       "attachment",
		"CON.txt":                "_CON.txt",
		"a\x00b\nc.png":          "a_b_c.png",
		"invoice‮txt.exe":        "invoice_txt.exe",
		"what?.jpg":              "what_.jpg",
		"trailing. ":             "trailing",
	}
	for in, want := range cases {
		if got := sanitizeFilename(in); got != want {
			t.Errorf("sanitizeFilename(%q) = %q, want %q", in, got, want)
		}
	}
	long := strings.Repeat("a", 300) + ".png"
	if got := sanitizeFilename(long); len([]rune(got)) > 120 || !strings.HasSuffix(got, ".png") {
		t.Errorf("long name not bounded: %d %q", len(got), got[len(got)-8:])
	}
}

func TestByteLRUEvicts(t *testing.T) {
	c := newByteLRU(100)
	c.Put("a", make([]byte, 20))
	c.Put("b", make([]byte, 20))
	c.Get("a")
	for _, k := range []string{"c", "d", "e", "f"} {
		c.Put(k, make([]byte, 20))
	}
	if _, ok := c.Get("b"); ok {
		t.Error("least recently used entry should be evicted")
	}
	if _, ok := c.Get("f"); !ok {
		t.Error("newest entry missing")
	}
	c.Put("huge", make([]byte, 60)) // > max/4: not cached
	if _, ok := c.Get("huge"); ok {
		t.Error("oversized entries must not be cached")
	}
}

func TestDataURLRejectsInjectedMime(t *testing.T) {
	png := []byte("\x89PNG\r\n\x1a\n0000")
	if got := dataURL(`image/png"><script>`, png); !strings.HasPrefix(got, "data:image/png;base64,") {
		t.Errorf("mime not sanitised: %s", got[:30])
	}
}

func TestDetectMime(t *testing.T) {
	if m := detectMime("v.m4a", nil); m != "audio/mp4" {
		t.Errorf("m4a -> %s", m)
	}
	if m := detectMime("noext", []byte("\x89PNG\r\n\x1a\n")); m != "image/png" {
		t.Errorf("sniff -> %s", m)
	}
}

func TestParseCookieLines(t *testing.T) {
	in := "SID\ta\t.google.com\nHSID\tb\t.google.com\nSSID\tc\t.google.com\nAPISID\td\t.google.com\n" +
		"SAPISID\te\t.google.com\nOSID\tf\tmessages.google.com\nEVIL\tx\t.evil.com\nbroken line\n"
	c, ok := parseCookieLines(in)
	if !ok || c["SAPISID"] != "e" || c["OSID"] != "f" {
		t.Fatalf("bad parse: %v %v", ok, c)
	}
	if _, leaked := c["EVIL"]; leaked {
		t.Fatal("non-Google cookie kept")
	}
	if _, ok := parseCookieLines("SID\ta\t.google.com\n"); ok {
		t.Fatal("incomplete cookie set accepted")
	}
	for _, d := range []string{"google.com.evil.net", "evilgoogle.com", ""} {
		if isGoogleCookieDomain(d) {
			t.Errorf("%q accepted", d)
		}
	}
	if !isMessagesURL("https://messages.google.com/web/conversations") || isMessagesURL("https://messages.google.com.evil.net/") {
		t.Error("isMessagesURL wrong")
	}
}
