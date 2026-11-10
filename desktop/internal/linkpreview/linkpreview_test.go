package linkpreview

import (
	"bytes"
	"context"
	"encoding/binary"
	"image"
	"image/png"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func mustURL(s string) *url.URL { u, _ := url.Parse(s); return u }

func TestParseHTML(t *testing.T) {
	doc := `<html><head>
<title>Fallback &amp; title</title>
<meta property="og:title" content="OG &quot;Title&quot;">
<meta name="twitter:title" content="Twitter">
<meta property="og:image" content="/img/card.png">
<meta property="og:site_name" content='Example'>
<link rel="icon" type="image/svg+xml" href="/icon.svg">
<link rel="icon" href="//cdn.example.com/fav.png">
<link rel="apple-touch-icon" href="http://example.com/touch.png">
</head><body><meta property="og:title" content="Body override"></body></html>`
	md := ParseHTML(doc, mustURL("https://example.com/a/b"))
	if md.Title != `OG "Title"` {
		t.Errorf("title %q", md.Title)
	}
	if md.ImageURL != "https://example.com/img/card.png" {
		t.Errorf("image %q", md.ImageURL)
	}
	if md.IconURL != "https://example.com/touch.png" {
		t.Errorf("icon %q (cleartext touch icon should be upgraded and preferred)", md.IconURL)
	}
	if md.SiteName != "Example" {
		t.Errorf("site %q", md.SiteName)
	}
}

func TestParseHTMLFallbacks(t *testing.T) {
	md := ParseHTML(`<title>  Just a
	title </title>`, mustURL("https://example.com/"))
	if md.Title != "Just a title" || md.IconURL != "https://example.com/favicon.ico" {
		t.Errorf("%+v", md)
	}
}

func TestResolveRejectsUnsafe(t *testing.T) {
	base := mustURL("https://example.com/")
	for _, s := range []string{"javascript:alert(1)", "data:image/png;base64,AA", "https://127.0.0.1/x", "https://localhost/x",
		"https://192.168.1.1/a", "ftp://example.com/a", "https://example.com:8443/a", "file:///etc/passwd", "https://user@example.com/"} {
		if got := Resolve(s, base); got != "" {
			t.Errorf("Resolve(%q) = %q, want blocked", s, got)
		}
	}
	if got := Resolve("http://example.com:80/x#frag", base); got != "https://example.com/x" {
		t.Errorf("upgrade: %q", got)
	}
}

func TestClean(t *testing.T) {
	in := "a‮evil‬ &lt;b&gt;\x00\n\tz"
	if got := Clean(in); got != "aevil <b> z" {
		t.Errorf("Clean = %q", got)
	}
	if got := Clean(strings.Repeat("x", 400)); len([]rune(got)) != maxTitleLength+1 {
		t.Errorf("length cap: %d", len([]rune(got)))
	}
}

func TestParseOEmbed(t *testing.T) {
	p := oembedProviders[0]
	md, ok := ParseOEmbed([]byte(`{"title":"Video","provider_name":"YouTube","thumbnail_url":"http://i.ytimg.com/vi/x/hq.jpg"}`), p)
	if !ok || md.Title != "Video" || md.ImageURL != "https://i.ytimg.com/vi/x/hq.jpg" {
		t.Errorf("%+v %v", md, ok)
	}
	if _, ok := ParseOEmbed([]byte(`{"html":"<script>"}`), p); ok {
		t.Error("empty oEmbed accepted")
	}
	if _, _, ok := oembedFor(mustURL("https://notyoutube.com/watch")); ok {
		t.Error("suffix match must be on a label boundary")
	}
}

func pngOf(w, h int) []byte {
	var b bytes.Buffer
	_ = png.Encode(&b, image.NewGray(image.Rect(0, 0, w, h)))
	return b.Bytes()
}

func TestValidateImage(t *testing.T) {
	if img, err := ValidateImage(pngOf(4, 3)); err != nil || img.Mime != "image/png" {
		t.Fatalf("png: %v %+v", err, img)
	}
	if _, err := ValidateImage([]byte(`<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>`)); err == nil {
		t.Error("svg accepted")
	}
	if _, err := ValidateImage([]byte("<html>")); err == nil {
		t.Error("html accepted")
	}
	// PNG header claiming 100000x100000 pixels (decompression bomb) is refused from the header alone.
	bomb := pngOf(1, 1)
	binary.BigEndian.PutUint32(bomb[16:20], 100000)
	binary.BigEndian.PutUint32(bomb[20:24], 100000)
	if _, err := ValidateImage(bomb); err == nil {
		t.Error("oversized png accepted")
	}
	// Truncated / malformed WebP and ICO.
	if _, err := ValidateImage([]byte("RIFF\x00\x00\x00\x00WEBPVP8 \x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00")); err == nil {
		t.Error("bad webp accepted")
	}
	ico := []byte{0, 0, 1, 0, 1, 0, 16, 16, 0, 0, 1, 0, 32, 0, 0xff, 0xff, 0, 0, 22, 0, 0, 0}
	if _, err := ValidateImage(ico); err == nil {
		t.Error("ico with out-of-range entry accepted")
	}
}

func TestFetcherRefusesPrivateAddresses(t *testing.T) {
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("<title>secret</title>"))
	}))
	defer srv.Close()
	f := New()
	// Even with TLS verification out of the way, the dialer must refuse loopback.
	f.client.Transport.(*http.Transport).TLSClientConfig = srv.Client().Transport.(*http.Transport).TLSClientConfig
	if _, err := f.Preview(context.Background(), srv.URL); err == nil {
		t.Fatal("fetched a loopback URL")
	}
	// The dialer itself refuses non-public addresses (this is what stops DNS answers pointing at the LAN).
	conn, err := f.client.Transport.(*http.Transport).DialContext(context.Background(), "tcp", srv.Listener.Addr().String())
	if err == nil {
		conn.Close()
		t.Fatal("dialer connected to loopback")
	}
}
