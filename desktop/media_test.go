package main

import "testing"

func TestSafeMime(t *testing.T) {
	cases := map[string]string{
		"image/jpeg": "image/jpeg", "IMAGE/PNG; charset=x": "image/png", "video/mp4": "video/mp4", "audio/mp4": "audio/mp4",
		"image/svg+xml": "application/octet-stream", "text/html": "application/octet-stream",
		"application/xhtml+xml": "application/octet-stream", "text/javascript": "application/octet-stream",
		"application/pdf": "application/octet-stream",
	}
	for in, want := range cases {
		if got := safeMime(in, nil); got != want {
			t.Errorf("safeMime(%q) = %q, want %q", in, got, want)
		}
	}
	if got := safeMime("", []byte("<html><script>")); got != "application/octet-stream" {
		t.Errorf("sniffed html served as %q", got)
	}
}

func TestPreviewTarget(t *testing.T) {
	for in, want := range map[string]string{
		"http://example.com/a#x": "https://example.com/a", "https://example.com": "https://example.com",
		"mailto:a@example.com": "", "https://10.0.0.1/": "", "javascript:alert(1)": "", "https://localhost/": "",
	} {
		if got := previewTarget(in); got != want {
			t.Errorf("previewTarget(%q) = %q, want %q", in, got, want)
		}
	}
}
