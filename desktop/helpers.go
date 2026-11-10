package main

import (
	"container/list"
	"context"
	"errors"
	"io"
	"mime"
	"net/http"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unicode"

	"github.com/wailsapp/wails/v2/pkg/runtime"

	"github.com/goobmessages/desktop/internal/model"
	"github.com/goobmessages/desktop/internal/urlsafe"
)

// ---------------------------------------------------------------- media cache

// byteLRU is a size-bounded in-memory cache (attachments are never written to disk).
type byteLRU struct {
	mu    sync.Mutex
	max   int
	size  int
	ll    *list.List
	items map[string]*list.Element
}

type lruEntry struct {
	key  string
	data []byte
}

func newByteLRU(max int) *byteLRU {
	return &byteLRU{max: max, ll: list.New(), items: map[string]*list.Element{}}
}

func (c *byteLRU) Get(k string) ([]byte, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if e, ok := c.items[k]; ok {
		c.ll.MoveToFront(e)
		return e.Value.(*lruEntry).data, true
	}
	return nil, false
}

func (c *byteLRU) Put(k string, data []byte) {
	if len(data) > c.max/4 {
		return // don't let one huge video evict everything
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if e, ok := c.items[k]; ok {
		c.size -= len(e.Value.(*lruEntry).data)
		c.ll.Remove(e)
	}
	c.items[k] = c.ll.PushFront(&lruEntry{k, data})
	c.size += len(data)
	for c.size > c.max {
		e := c.ll.Back()
		ent := e.Value.(*lruEntry)
		c.ll.Remove(e)
		delete(c.items, ent.key)
		c.size -= len(ent.data)
	}
}

func (c *byteLRU) Reset() {
	c.mu.Lock()
	c.ll.Init()
	c.items = map[string]*list.Element{}
	c.size = 0
	c.mu.Unlock()
}

// ---------------------------------------------------------------- avatars

// avatarLoader batches participant thumbnail requests (one RPC for many ids, to avoid rate limits) and
// fetches group avatars with a plain, cookie-less GET restricted to Google-owned public https hosts.
type avatarLoader struct {
	app *App

	mu      sync.Mutex
	urls    map[string]string // key -> data URL ("" = tried, none)
	queued  map[string]bool
	timer   *time.Timer
	groups  map[string]bool
	plainHC *http.Client
}

func newAvatarLoader(a *App) *avatarLoader {
	l := &avatarLoader{app: a, urls: map[string]string{}, queued: map[string]bool{}, groups: map[string]bool{}}
	l.plainHC = &http.Client{
		Timeout: 20 * time.Second,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) > 3 || !urlsafe.IsPublicHTTPS(req.URL.String()) || !urlsafe.IsGoogleOwned(req.URL.String()) {
				return errors.New("redirect blocked")
			}
			return nil
		},
	}
	return l
}

func (l *avatarLoader) Reset() {
	l.mu.Lock()
	l.urls = map[string]string{}
	l.queued = map[string]bool{}
	l.groups = map[string]bool{}
	l.mu.Unlock()
}

func (l *avatarLoader) Get(key string) string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.urls[key]
}

// RequestFor loads the avatar(s) a conversation row needs.
func (l *avatarLoader) RequestFor(c model.Conversation) {
	if c.HasGroupAvatar {
		l.requestGroup(c.ID, c.GroupAvatarURL)
		return
	}
	ids := c.AvatarIDs
	if len(ids) > 4 {
		ids = ids[:4]
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	added := false
	for _, id := range ids {
		if id == "" {
			continue
		}
		if _, done := l.urls[id]; done || l.queued[id] {
			continue
		}
		l.queued[id] = true
		added = true
	}
	if added && l.timer == nil {
		l.timer = time.AfterFunc(400*time.Millisecond, l.flush)
	}
}

func (l *avatarLoader) flush() {
	l.mu.Lock()
	l.timer = nil
	var ids []string
	for id := range l.queued {
		ids = append(ids, id)
		if len(ids) == 50 {
			break
		}
	}
	for _, id := range ids {
		delete(l.queued, id)
		l.urls[id] = "" // mark as tried
	}
	more := len(l.queued) > 0
	if more {
		l.timer = time.AfterFunc(time.Second, l.flush)
	}
	l.mu.Unlock()
	if len(ids) == 0 {
		return
	}
	cli, ctx, err := l.app.client()
	if err != nil {
		return
	}
	resp, err := cli.GetParticipantThumbnail(ctx, ids...)
	if err != nil {
		return
	}
	for _, t := range resp.GetThumbnail() {
		buf := t.GetData().GetImageBuffer()
		if len(buf) == 0 || len(buf) > 2<<20 {
			continue
		}
		l.set(t.GetIdentifier(), dataURL("", buf))
	}
}

func (l *avatarLoader) requestGroup(cid, url string) {
	key := "group:" + cid
	l.mu.Lock()
	if l.groups[key] {
		l.mu.Unlock()
		return
	}
	l.groups[key] = true
	l.mu.Unlock()
	if !urlsafe.IsPublicHTTPS(url) || !urlsafe.IsGoogleOwned(url) {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			return
		}
		resp, err := l.plainHC.Do(req)
		if err != nil {
			return
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return
		}
		data, err := io.ReadAll(io.LimitReader(resp.Body, 5<<20+1))
		if err != nil || len(data) > 5<<20 || !strings.HasPrefix(http.DetectContentType(data), "image/") {
			return
		}
		l.set(key, dataURL("", data))
	}()
}

func (l *avatarLoader) set(key, url string) {
	l.mu.Lock()
	l.urls[key] = url
	l.mu.Unlock()
	runtime.EventsEmit(l.app.ctx, "avatar", map[string]string{"key": key, "url": url})
}

// ---------------------------------------------------------------- files

var mimeOverrides = map[string]string{
	".heic": "image/heic", ".heif": "image/heif", ".m4a": "audio/mp4", ".aac": "audio/aac", ".amr": "audio/amr",
	".3gp": "video/3gpp", ".vcf": "text/x-vcard", ".webp": "image/webp", ".mp4": "video/mp4", ".mov": "video/quicktime",
	".opus": "audio/ogg", ".ogg": "audio/ogg", ".webm": "video/webm",
}

// detectMime picks a MIME type from the extension, falling back to content sniffing.
func detectMime(name string, data []byte) string {
	ext := strings.ToLower(filepath.Ext(name))
	if m, ok := mimeOverrides[ext]; ok {
		return m
	}
	if m := mime.TypeByExtension(ext); m != "" {
		if i := strings.IndexByte(m, ';'); i >= 0 {
			m = m[:i]
		}
		return m
	}
	m := http.DetectContentType(data)
	if i := strings.IndexByte(m, ';'); i >= 0 {
		m = m[:i]
	}
	return m
}

// sanitizeFilename makes a sender-controlled name safe to use as a default save name: no path separators,
// control or reserved characters, no leading dots, bounded length.
func sanitizeFilename(name string) string {
	name = filepath.Base(strings.ReplaceAll(name, "\\", "/"))
	var b strings.Builder
	for _, r := range name {
		switch {
		case unicode.IsControl(r), strings.ContainsRune(`/\:*?"<>|`, r), r == 0x202E || r == 0x202D || (r >= 0x2066 && r <= 0x2069):
			b.WriteRune('_')
		default:
			b.WriteRune(r)
		}
	}
	s := strings.TrimLeft(strings.TrimSpace(b.String()), ".")
	s = strings.TrimRight(s, ". ")
	if r := []rune(s); len(r) > 120 {
		ext := filepath.Ext(s)
		if len([]rune(ext)) > 10 {
			ext = ""
		}
		s = string(r[:120-len([]rune(ext))]) + ext
	}
	base := strings.ToUpper(strings.TrimSuffix(s, filepath.Ext(s)))
	switch base {
	case "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "LPT1", "LPT2", "LPT3":
		s = "_" + s
	}
	if s == "" {
		s = "attachment"
	}
	return s
}
