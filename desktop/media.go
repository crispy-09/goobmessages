package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/goobmessages/desktop/internal/model"
	"github.com/google/uuid"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/crypto"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/gmproto"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/util"
	"google.golang.org/protobuf/proto"
)

// Attachments are decrypted into memory and served to the webview from /media/<token> by the Wails asset server
// (AssetServer.Handler). Passing multi-megabyte data: URLs through the Wails bridge is slow and unreliable on
// WebKitGTK, and an <img>/<video> URL also lets the webview stream and seek.

const mediaPathPrefix = "/media/"

type mediaRef struct {
	id   string
	key  []byte
	mime string
}

// mediaServer remembers which tokens map to which attachment, plus the most recent attachment too big for the LRU.
type mediaServer struct {
	mu      sync.Mutex
	refs    map[string]mediaRef
	bigID   string
	bigData []byte
	// in-flight downloads, so the webview's request and GetMedia don't fetch the same file twice
	inflight map[string]*mediaCall
}

type mediaCall struct {
	done chan struct{}
	data []byte
	err  error
}

func newMediaServer() *mediaServer {
	return &mediaServer{refs: map[string]mediaRef{}, inflight: map[string]*mediaCall{}}
}

func mediaToken(mediaID string) string {
	h := sha256.Sum256([]byte("goob-media:" + mediaID))
	return hex.EncodeToString(h[:16])
}

func (s *mediaServer) register(ref mediaRef) string {
	tok := mediaToken(ref.id)
	s.mu.Lock()
	if len(s.refs) > 20000 { // bound memory over very long sessions; URLs are re-registered on demand
		s.refs = map[string]mediaRef{}
	}
	s.refs[tok] = ref
	s.mu.Unlock()
	return tok
}

func (s *mediaServer) lookup(tok string) (mediaRef, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r, ok := s.refs[tok]
	return r, ok
}

func (s *mediaServer) reset() {
	s.mu.Lock()
	s.refs = map[string]mediaRef{}
	s.bigID, s.bigData = "", nil
	s.mu.Unlock()
}

// media returns an attachment's decrypted bytes from memory, or downloads it once (concurrent callers share it).
func (a *App) media(ctx context.Context, ref mediaRef) ([]byte, error) {
	if v, ok := a.mediaCache.Get(ref.id); ok {
		return v, nil
	}
	if strings.HasPrefix(ref.id, model.InlineMediaIDPrefix) {
		return a.inlineMedia(ref.id)
	}
	s := a.mediaSrv
	s.mu.Lock()
	if s.bigID == ref.id && s.bigData != nil {
		d := s.bigData
		s.mu.Unlock()
		return d, nil
	}
	if c, ok := s.inflight[ref.id]; ok {
		s.mu.Unlock()
		select {
		case <-c.done:
			return c.data, c.err
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	c := &mediaCall{done: make(chan struct{})}
	s.inflight[ref.id] = c
	s.mu.Unlock()

	c.data, c.err = a.downloadMedia(ref.id, ref.key)
	if c.err == nil {
		if len(c.data) > mediaCacheBytes/4 {
			s.mu.Lock()
			s.bigID, s.bigData = ref.id, c.data
			s.mu.Unlock()
		} else {
			a.mediaCache.Put(ref.id, c.data)
		}
	}
	s.mu.Lock()
	delete(s.inflight, ref.id)
	s.mu.Unlock()
	close(c.done)
	return c.data, c.err
}

// inlineMedia finds attachment bytes that arrived inside a message ("inline:<conversation>:<message>:<index>").
func (a *App) inlineMedia(id string) ([]byte, error) {
	rest := strings.TrimPrefix(id, model.InlineMediaIDPrefix)
	cid, _, ok := strings.Cut(rest, ":")
	if !ok {
		return nil, errors.New("invalid attachment")
	}
	for _, m := range a.store.Messages(cid) {
		for _, md := range m.Media {
			if md.ID == id && len(md.Inline) > 0 {
				return md.Inline, nil
			}
		}
	}
	return nil, errors.New("attachment is no longer loaded")
}

var mediaHTTP = &http.Client{Timeout: 3 * time.Minute}

// downloadMedia fetches and decrypts an attachment. Mirrors libgm's DownloadMedia (and the Mac app), but checks
// the HTTP status, lets Go negotiate compression (libgm forces "br", which net/http can't decode), caps the size
// and only decrypts when the key is a 32-byte AES key (otherwise the server returns plain bytes).
func (a *App) downloadMedia(mediaID string, key []byte) ([]byte, error) {
	cli, ctx, err := a.client()
	if err != nil {
		return nil, err
	}
	auth := cli.AuthData
	if auth == nil {
		return nil, errors.New("not signed in")
	}
	meta, err := proto.Marshal(&gmproto.DownloadAttachmentRequest{
		Info: &gmproto.AttachmentInfo{AttachmentID: mediaID, Encrypted: true},
		AuthData: &gmproto.AuthMessage{
			RequestID:        uuid.NewString(),
			TachyonAuthToken: auth.TachyonAuthToken,
			Network:          auth.AuthNetwork(),
			ConfigVersion:    util.ConfigMessage,
		},
	})
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Minute)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, util.UploadMediaURL, nil)
	if err != nil {
		return nil, err
	}
	util.BuildUploadHeaders(req, base64.StdEncoding.EncodeToString(meta))
	req.Header.Del("accept-encoding")
	start := time.Now()
	res, err := mediaHTTP.Do(req)
	if err != nil {
		return nil, fmt.Errorf("download failed: %w", err)
	}
	defer res.Body.Close()
	a.log.Info().Int("status", res.StatusCode).Int("key_len", len(key)).Str("content_type", res.Header.Get("Content-Type")).
		Int64("content_length", res.ContentLength).Dur("took", time.Since(start)).Msg("Attachment download response")
	if res.StatusCode < 200 || res.StatusCode > 299 {
		_, _ = io.Copy(io.Discard, io.LimitReader(res.Body, 64<<10))
		return nil, fmt.Errorf("download failed (HTTP %d)", res.StatusCode)
	}
	raw, err := io.ReadAll(io.LimitReader(res.Body, maxDownloadBytes+1))
	if err != nil {
		return nil, fmt.Errorf("download failed: %w", err)
	}
	if len(raw) > maxDownloadBytes {
		return nil, errors.New("attachment is too large")
	}
	if len(key) != 32 {
		return raw, nil
	}
	out, err := decryptMedia(raw, key)
	if err != nil && len(raw) > 0 {
		a.log.Warn().Err(err).Int("bytes", len(raw)).Hex("head", raw[:min(len(raw), 4)]).Msg("Attachment decrypt failed")
	}
	return out, err
}

func decryptMedia(raw, key []byte) ([]byte, error) {
	h, err := crypto.NewAESGCMHelper(key)
	if err != nil {
		return nil, err
	}
	out, err := io.ReadAll(io.LimitReader(h.DecryptStream(io.NopCloser(bytes.NewReader(raw))), maxDownloadBytes+1))
	if err != nil {
		return nil, fmt.Errorf("couldn't decrypt attachment: %w", err)
	}
	return out, nil
}

// handler serves /media/<token> (attachments) and /preview/<token> (link-card images) to the webview (only reachable from the app's own asset server).
func (s *mediaServer) handler(a *App) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			http.NotFound(w, r)
			return
		}
		if tok, ok := strings.CutPrefix(r.URL.Path, previewPathPrefix); ok {
			data, mt, ok := a.previews.image(tok)
			if !ok {
				http.NotFound(w, r)
				return
			}
			w.Header().Set("Content-Type", mt) // sniffed and validated raster type (linkpreview.ValidateImage)
			w.Header().Set("X-Content-Type-Options", "nosniff")
			w.Header().Set("Content-Security-Policy", "default-src 'none'; sandbox")
			http.ServeContent(w, r, "", time.Time{}, bytes.NewReader(data))
			return
		}
		tok, ok := strings.CutPrefix(r.URL.Path, mediaPathPrefix)
		if !ok {
			http.NotFound(w, r)
			return
		}
		ref, ok := s.lookup(tok)
		if !ok {
			http.NotFound(w, r)
			return
		}
		data, err := a.media(r.Context(), ref)
		if err != nil {
			a.log.Warn().Err(err).Msg("Media request failed")
			http.Error(w, "unavailable", http.StatusBadGateway)
			return
		}
		w.Header().Set("Content-Type", servedMime(ref.mime, data))
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Content-Security-Policy", "default-src 'none'; sandbox")
		w.Header().Set("Cache-Control", "private, max-age=3600")
		http.ServeContent(w, r, "", time.Time{}, bytes.NewReader(data))
	})
}

// servedMime prefers the sniffed type when it is a playable image/video/audio type (the declared type can be empty
// or generic), and otherwise falls back to safeMime.
func servedMime(declared string, data []byte) string {
	sniffed := http.DetectContentType(data)
	if i := strings.IndexByte(sniffed, ';'); i >= 0 {
		sniffed = sniffed[:i]
	}
	if m := safeMime(sniffed, nil); m != "application/octet-stream" {
		return m
	}
	return safeMime(declared, data)
}

// safeMime picks the served Content-Type. The sender controls the declared type, so anything that the webview
// could execute (HTML, SVG, XML, JS) is served as an opaque download type instead.
func safeMime(declared string, data []byte) string {
	m := strings.ToLower(strings.TrimSpace(declared))
	if i := strings.IndexByte(m, ';'); i >= 0 {
		m = strings.TrimSpace(m[:i])
	}
	if m == "" || strings.ContainsAny(m, ",\"' <>") {
		m = http.DetectContentType(data)
		if i := strings.IndexByte(m, ';'); i >= 0 {
			m = m[:i]
		}
	}
	switch {
	case strings.HasPrefix(m, "image/svg"), strings.Contains(m, "html"), strings.Contains(m, "xml"),
		strings.Contains(m, "javascript"), strings.Contains(m, "ecmascript"):
		return "application/octet-stream"
	case strings.HasPrefix(m, "image/"), strings.HasPrefix(m, "video/"), strings.HasPrefix(m, "audio/"):
		return m
	}
	return "application/octet-stream"
}
