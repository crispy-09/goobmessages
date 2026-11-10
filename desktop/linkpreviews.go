package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/goobmessages/desktop/internal/linkpreview"
)

const (
	previewPathPrefix = "/preview/"
	previewMaxEntries = 300
	previewRetryAfter = 5 * time.Minute
)

// LinkPreview is a link card for the UI. Image/Icon are /preview/ URLs served from memory.
type LinkPreview struct {
	URL      string `json:"url"`
	Title    string `json:"title"`
	SiteName string `json:"siteName"`
	Host     string `json:"host"`
	Image    string `json:"image"`
	Icon     string `json:"icon"`
}

type previewEntry struct {
	done     chan struct{}
	result   *LinkPreview
	failedAt time.Time
}

type previewStore struct {
	fetcher *linkpreview.Fetcher
	mu      sync.Mutex
	entries map[string]*previewEntry
	order   []string
	images  *byteLRU
	mimes   map[string]string
}

func newPreviewStore() *previewStore {
	return &previewStore{
		fetcher: linkpreview.New(),
		entries: map[string]*previewEntry{},
		images:  newByteLRU(48 << 20),
		mimes:   map[string]string{},
	}
}

// previewTarget is the URL actually fetched: cleartext is upgraded to https, and it must be a public https host.
func previewTarget(raw string) string {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || (!strings.EqualFold(u.Scheme, "http") && !strings.EqualFold(u.Scheme, "https")) {
		return ""
	}
	return linkpreview.Upgrade(u)
}

// LinkPreview fetches (once) and returns a link card, or null when the link has none or isn't allowed.
func (a *App) LinkPreview(raw string) (*LinkPreview, error) {
	if a.GetPrefs().LinkPreviews == "off" {
		return nil, nil
	}
	target := previewTarget(raw)
	if target == "" {
		return nil, nil
	}
	s := a.previews
	s.mu.Lock()
	e, ok := s.entries[target]
	if ok && e.done == nil && e.result == nil && time.Since(e.failedAt) > previewRetryAfter {
		ok = false // failed a while ago: try again
	}
	if !ok {
		e = &previewEntry{done: make(chan struct{})}
		s.entries[target] = e
		s.order = append(s.order, target)
		for len(s.order) > previewMaxEntries {
			delete(s.entries, s.order[0])
			s.order = s.order[1:]
		}
		s.mu.Unlock()
		a.fetchPreview(target, e)
		s.mu.Lock()
	}
	done := e.done
	s.mu.Unlock()
	if done != nil {
		<-done
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return e.result, nil
}

func (a *App) fetchPreview(target string, e *previewEntry) {
	s := a.previews
	ctx, cancel := context.WithTimeout(a.ctx, 20*time.Second)
	defer cancel()
	r, err := s.fetcher.Preview(ctx, target)
	var out *LinkPreview
	if err == nil {
		out = &LinkPreview{URL: r.URL, Title: r.Title, SiteName: r.SiteName, Host: r.Host}
		if r.Image != nil {
			out.Image = s.putImage(r.Image)
		}
		if r.Icon != nil {
			out.Icon = s.putImage(r.Icon)
		}
	}
	s.mu.Lock()
	e.result = out
	if out == nil {
		e.failedAt = time.Now()
	}
	close(e.done)
	e.done = nil
	s.mu.Unlock()
}

func (s *previewStore) putImage(img *linkpreview.Image) string {
	h := sha256.Sum256(img.Data)
	tok := hex.EncodeToString(h[:16])
	s.images.Put(tok, img.Data)
	s.mu.Lock()
	if len(s.mimes) > 4*previewMaxEntries {
		s.mimes = map[string]string{}
	}
	s.mimes[tok] = img.Mime
	s.mu.Unlock()
	return previewPathPrefix + tok
}

func (s *previewStore) image(tok string) ([]byte, string, bool) {
	data, ok := s.images.Get(tok)
	if !ok {
		return nil, "", false
	}
	s.mu.Lock()
	mt := s.mimes[tok]
	s.mu.Unlock()
	return data, mt, mt != ""
}
