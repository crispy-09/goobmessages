package linkpreview

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"image"
	_ "image/gif" // register decoders for DecodeConfig (dimension checks only)
	_ "image/jpeg"
	_ "image/png"
	"io"
	"mime"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/net/html/charset"

	"github.com/goobmessages/desktop/internal/urlsafe"
)

// Request rules (sender-chosen URLs):
//   - https only, to public host names (urlsafe.IsPublicHTTPS), on every redirect hop too (max 5);
//   - the dialer refuses non-public IPs at connect time, so DNS answers (including rebinding) can't reach the LAN;
//   - no proxy, no cookies, no cache, no credentials; only User-Agent / Accept / Accept-Language are sent;
//   - bodies are capped (HTML 512 KB, JSON 64 KB, images 5 MB) and images must be a raster type whose declared
//     dimensions are checked before the webview ever decodes them (no SVG, no decompression bombs).

const (
	maxHTMLBytes   = 512 << 10
	maxJSONBytes   = 64 << 10
	maxImageBytes  = 5 << 20
	maxImagePixels = 40_000_000
	userAgent      = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
)

var errBlocked = errors.New("blocked address")

// Image is a validated preview image.
type Image struct {
	Mime string
	Data []byte
}

// Result is a fetched preview. Title may be empty when the link is a direct image (then Image is set).
type Result struct {
	URL      string // final URL after redirects
	Title    string
	SiteName string
	Host     string
	Image    *Image
	Icon     *Image
}

// Fetcher fetches previews. The zero value is not usable; use New.
type Fetcher struct {
	client *http.Client
}

func New() *Fetcher {
	dialer := &net.Dialer{
		Timeout: 8 * time.Second,
		// Runs after DNS resolution, for the exact address being connected to.
		Control: func(network, address string, _ syscall.RawConn) error {
			host, _, err := net.SplitHostPort(address)
			if err != nil {
				return errBlocked
			}
			ip := net.ParseIP(host)
			if ip == nil || !urlsafe.IsPublicIP(ip) {
				return errBlocked
			}
			return nil
		},
	}
	tr := &http.Transport{
		Proxy:                  nil,
		DialContext:            dialer.DialContext,
		ForceAttemptHTTP2:      true,
		MaxIdleConns:           8,
		MaxConnsPerHost:        2,
		IdleConnTimeout:        30 * time.Second,
		TLSHandshakeTimeout:    8 * time.Second,
		ResponseHeaderTimeout:  10 * time.Second,
		MaxResponseHeaderBytes: 64 << 10,
	}
	return &Fetcher{client: &http.Client{
		Transport: tr,
		Timeout:   15 * time.Second,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 5 || !urlsafe.IsPublicHTTPS(req.URL.String()) {
				return errBlocked
			}
			for k := range req.Header {
				switch strings.ToLower(k) {
				case "user-agent", "accept", "accept-language":
				default:
					req.Header.Del(k)
				}
			}
			return nil
		},
	}}
}

type response struct {
	data     []byte
	complete bool
	final    *url.URL
	mime     string
	charset  string
}

func (f *Fetcher) get(ctx context.Context, raw, accept string, limit int, allowTruncation bool) (*response, error) {
	if !urlsafe.IsPublicHTTPS(raw) {
		return nil, errBlocked
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, raw, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", userAgent)
	req.Header.Set("Accept", accept)
	req.Header.Set("Accept-Language", "en-US,en;q=0.8")
	res, err := f.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	if res.StatusCode < 200 || res.StatusCode > 299 {
		return nil, errors.New(res.Status)
	}
	if !urlsafe.IsPublicHTTPS(res.Request.URL.String()) {
		return nil, errBlocked
	}
	if !allowTruncation && res.ContentLength > int64(limit) {
		return nil, errors.New("too large")
	}
	data, err := io.ReadAll(io.LimitReader(res.Body, int64(limit)+1))
	if err != nil {
		return nil, err
	}
	complete := len(data) <= limit
	if !complete {
		if !allowTruncation {
			return nil, errors.New("too large")
		}
		data = data[:limit]
	}
	mt, params, _ := mime.ParseMediaType(res.Header.Get("Content-Type"))
	return &response{data: data, complete: complete, final: res.Request.URL, mime: strings.ToLower(mt), charset: params["charset"]}, nil
}

// Preview fetches a link card for a public https URL.
func (f *Fetcher) Preview(ctx context.Context, target string) (*Result, error) {
	u, err := url.Parse(target)
	if err != nil {
		return nil, err
	}
	if p, endpoint, ok := oembedFor(u); ok {
		if r, err := f.get(ctx, endpoint, "application/json", maxJSONBytes, false); err == nil {
			if md, ok := ParseOEmbed(r.data, p); ok {
				return f.result(ctx, md, u)
			}
		}
	}
	r, err := f.get(ctx, target, "text/html,application/xhtml+xml;q=0.9,image/*;q=0.8", maxHTMLBytes, true)
	if err != nil {
		return nil, err
	}
	if strings.HasPrefix(r.mime, "image/") {
		if !r.complete {
			return nil, errors.New("image too large")
		}
		img, err := ValidateImage(r.data)
		if err != nil {
			return nil, err
		}
		return &Result{URL: r.final.String(), Host: displayHost(r.final), Image: img}, nil
	}
	if r.mime != "text/html" && r.mime != "application/xhtml+xml" {
		return nil, errors.New("not a web page")
	}
	return f.result(ctx, ParseHTML(decodeText(r.data, r.charset), r.final), r.final)
}

func (f *Fetcher) result(ctx context.Context, md Metadata, final *url.URL) (*Result, error) {
	var wg sync.WaitGroup
	var img, icon *Image
	if md.ImageURL != "" {
		wg.Add(1)
		go func() { defer wg.Done(); img = f.image(ctx, md.ImageURL) }()
	}
	if md.IconURL != "" {
		wg.Add(1)
		go func() { defer wg.Done(); icon = f.image(ctx, md.IconURL) }()
	}
	wg.Wait()
	if md.Title == "" && img == nil {
		return nil, errors.New("nothing to show")
	}
	return &Result{URL: final.String(), Title: md.Title, SiteName: md.SiteName, Host: displayHost(final), Image: img, Icon: icon}, nil
}

func (f *Fetcher) image(ctx context.Context, raw string) *Image {
	r, err := f.get(ctx, raw, "image/avif;q=0,image/webp,image/png,image/jpeg,image/gif,image/x-icon;q=0.8", maxImageBytes, false)
	if err != nil {
		return nil
	}
	img, err := ValidateImage(r.data)
	if err != nil {
		return nil
	}
	return img
}

func displayHost(u *url.URL) string {
	return strings.TrimPrefix(strings.ToLower(u.Hostname()), "www.")
}

func decodeText(data []byte, cs string) string {
	if cs != "" && !strings.EqualFold(cs, "utf-8") && !strings.EqualFold(cs, "utf8") {
		if enc, _ := charset.Lookup(cs); enc != nil {
			if out, err := enc.NewDecoder().Bytes(data); err == nil {
				return string(out)
			}
		}
	}
	return strings.ToValidUTF8(string(data), "�")
}

// ValidateImage sniffs the real format (the server's Content-Type is ignored) and checks the declared dimensions.
// Only raster formats the webview decodes are allowed; SVG and anything unknown are refused.
func ValidateImage(data []byte) (*Image, error) {
	var w, h int
	var mt string
	switch {
	case bytes.HasPrefix(data, []byte("\x89PNG\r\n\x1a\n")), bytes.HasPrefix(data, []byte("\xff\xd8\xff")),
		bytes.HasPrefix(data, []byte("GIF87a")), bytes.HasPrefix(data, []byte("GIF89a")):
		cfg, format, err := image.DecodeConfig(bytes.NewReader(data))
		if err != nil {
			return nil, err
		}
		w, h, mt = cfg.Width, cfg.Height, "image/"+format
	case len(data) > 30 && string(data[:4]) == "RIFF" && string(data[8:12]) == "WEBP":
		var ok bool
		if w, h, ok = webpSize(data); !ok {
			return nil, errors.New("bad webp")
		}
		mt = "image/webp"
	case len(data) > 6 && binary.LittleEndian.Uint16(data[0:2]) == 0 && binary.LittleEndian.Uint16(data[2:4]) == 1:
		var ok bool
		if w, h, ok = icoSize(data); !ok {
			return nil, errors.New("bad ico")
		}
		mt = "image/x-icon"
	default:
		return nil, errors.New("unsupported image")
	}
	if w <= 0 || h <= 0 || int64(w)*int64(h) > maxImagePixels {
		return nil, errors.New("image dimensions out of range")
	}
	return &Image{Mime: mt, Data: data}, nil
}

func webpSize(b []byte) (int, int, bool) {
	switch string(b[12:16]) {
	case "VP8 ":
		if len(b) < 30 || b[23] != 0x9d || b[24] != 0x01 || b[25] != 0x2a {
			return 0, 0, false
		}
		return int(binary.LittleEndian.Uint16(b[26:28]) & 0x3fff), int(binary.LittleEndian.Uint16(b[28:30]) & 0x3fff), true
	case "VP8L":
		if len(b) < 25 || b[20] != 0x2f {
			return 0, 0, false
		}
		v := binary.LittleEndian.Uint32(b[21:25])
		return int(v&0x3fff) + 1, int((v>>14)&0x3fff) + 1, true
	case "VP8X":
		if len(b) < 30 {
			return 0, 0, false
		}
		w := int(b[24]) | int(b[25])<<8 | int(b[26])<<16
		h := int(b[27]) | int(b[28])<<8 | int(b[29])<<16
		return w + 1, h + 1, true
	}
	return 0, 0, false
}

// icoSize returns the largest entry's size. Entries that embed a PNG are checked with the PNG's own header.
func icoSize(b []byte) (int, int, bool) {
	n := int(binary.LittleEndian.Uint16(b[4:6]))
	if n == 0 || n > 64 || len(b) < 6+16*n {
		return 0, 0, false
	}
	bw, bh := 0, 0
	for i := 0; i < n; i++ {
		e := b[6+16*i : 6+16*(i+1)]
		w, h := int(e[0]), int(e[1])
		if w == 0 {
			w = 256
		}
		if h == 0 {
			h = 256
		}
		size, off := binary.LittleEndian.Uint32(e[8:12]), binary.LittleEndian.Uint32(e[12:16])
		if uint64(off)+uint64(size) > uint64(len(b)) {
			return 0, 0, false
		}
		if sub := b[off : off+size]; bytes.HasPrefix(sub, []byte("\x89PNG")) {
			cfg, _, err := image.DecodeConfig(bytes.NewReader(sub))
			if err != nil || cfg.Width > 1024 || cfg.Height > 1024 {
				return 0, 0, false
			}
			w, h = cfg.Width, cfg.Height
		}
		if w*h > bw*bh {
			bw, bh = w, h
		}
	}
	return bw, bh, true
}
