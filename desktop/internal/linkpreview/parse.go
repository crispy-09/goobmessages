// Package linkpreview builds link cards for URLs taken from message text. Those URLs are chosen by the sender, so
// the network is treated as hostile: see fetch.go for the request rules. Port of the Mac app's LinkPreview.swift.
package linkpreview

import (
	"encoding/json"
	"html"
	"net/url"
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/goobmessages/desktop/internal/urlsafe"
)

// Metadata is what a page says about itself (Open Graph / Twitter card / <title>).
type Metadata struct {
	Title    string
	SiteName string
	ImageURL string
	IconURL  string
}

const maxTitleLength = 300

var (
	metaTag   = regexp.MustCompile(`(?i)<meta\s[^>]*>`)
	linkTag   = regexp.MustCompile(`(?i)<link\s[^>]*>`)
	titleTag  = regexp.MustCompile(`(?i)<title[^>]*>([\s\S]*?)</title>`)
	attribute = regexp.MustCompile(`([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>` + "`" + `]+))`)
	headEnd   = regexp.MustCompile(`(?i)</head`)
)

// ParseHTML extracts metadata from a page. Only <head> is considered, so markup later in the body can't override it.
func ParseHTML(doc string, base *url.URL) Metadata {
	if loc := headEnd.FindStringIndex(doc); loc != nil {
		doc = doc[:loc[0]]
	}
	meta := map[string]string{}
	for _, tag := range metaTag.FindAllString(doc, 400) {
		a := Attributes(tag)
		content, ok := a["content"]
		if !ok {
			continue
		}
		key := a["property"]
		if key == "" {
			key = a["name"]
		}
		if key == "" {
			key = a["itemprop"]
		}
		key = strings.ToLower(key)
		if key == "" {
			continue
		}
		if _, dup := meta[key]; !dup {
			meta[key] = content
		}
	}
	var htmlTitle string
	if m := titleTag.FindStringSubmatch(doc); len(m) > 1 {
		htmlTitle = m[1]
	}
	var touchIcon, plainIcon string
	for _, tag := range linkTag.FindAllString(doc, 400) {
		a := Attributes(tag)
		rel, href := strings.ToLower(a["rel"]), a["href"]
		if rel == "" || href == "" {
			continue
		}
		// SVG can carry script; never fetch it as an icon.
		if strings.Contains(strings.ToLower(a["type"]), "svg") || strings.HasSuffix(strings.ToLower(strings.SplitN(href, "?", 2)[0]), ".svg") {
			continue
		}
		rels := strings.Fields(rel)
		switch {
		case contains(rels, "apple-touch-icon") || contains(rels, "apple-touch-icon-precomposed"):
			if touchIcon == "" {
				touchIcon = Resolve(href, base)
			}
		case contains(rels, "icon"):
			if plainIcon == "" {
				plainIcon = Resolve(href, base)
			}
		}
	}
	var md Metadata
	for _, t := range []string{meta["og:title"], meta["twitter:title"], htmlTitle} {
		if c := Clean(t); c != "" {
			md.Title = c
			break
		}
	}
	for _, k := range []string{"og:image:secure_url", "og:image", "og:image:url", "twitter:image", "twitter:image:src"} {
		if v, ok := meta[k]; ok {
			if u := Resolve(v, base); u != "" {
				md.ImageURL = u
				break
			}
		}
	}
	md.SiteName = Clean(meta["og:site_name"])
	md.IconURL = touchIcon
	if md.IconURL == "" {
		md.IconURL = plainIcon
	}
	if md.IconURL == "" {
		md.IconURL = Resolve("/favicon.ico", base)
	}
	return md
}

// Attributes parses a tag's attributes (lower-cased names, entity-decoded values, first occurrence wins).
func Attributes(tag string) map[string]string {
	out := map[string]string{}
	for _, m := range attribute.FindAllStringSubmatch(tag, 64) {
		name := strings.ToLower(m[1])
		if _, dup := out[name]; dup {
			continue
		}
		for _, v := range m[2:] {
			if v != "" {
				out[name] = html.UnescapeString(v)
				break
			}
		}
		if _, ok := out[name]; !ok {
			out[name] = ""
		}
	}
	return out
}

// Resolve resolves a (possibly relative or protocol-relative) reference against base. Cleartext is upgraded to
// https; the result must be a public https URL, otherwise "".
func Resolve(raw string, base *url.URL) string {
	s := strings.ReplaceAll(strings.TrimSpace(raw), " ", "%20")
	if s == "" || len(s) > 2048 {
		return ""
	}
	ref, err := url.Parse(s)
	if err != nil {
		return ""
	}
	u := ref
	if base != nil {
		u = base.ResolveReference(ref)
	}
	return Upgrade(u)
}

// Upgrade turns http into https, drops the fragment and checks the result with urlsafe.IsPublicHTTPS.
func Upgrade(u *url.URL) string {
	if u == nil {
		return ""
	}
	c := *u
	c.Fragment, c.RawFragment = "", ""
	if strings.EqualFold(c.Scheme, "http") {
		c.Scheme = "https"
		if c.Port() == "80" {
			c.Host = c.Hostname()
		}
	}
	out := c.String()
	if !urlsafe.IsPublicHTTPS(out) {
		return ""
	}
	return out
}

// Clean decodes entities, removes control and bidi-override characters (spoofing), collapses whitespace and caps
// the length.
func Clean(s string) string {
	if s == "" {
		return ""
	}
	s = html.UnescapeString(s)
	s = strings.ToValidUTF8(s, "")
	s = strings.Map(func(r rune) rune {
		switch {
		case r >= 0x202A && r <= 0x202E, r >= 0x2066 && r <= 0x2069, r == 0x200E, r == 0x200F:
			return -1
		case unicode.IsSpace(r):
			return ' '
		case unicode.IsControl(r):
			return -1
		}
		return r
	}, s)
	s = strings.Join(strings.Fields(s), " ")
	if utf8.RuneCountInString(s) > maxTitleLength {
		r := []rune(s)
		s = string(r[:maxTitleLength]) + "…"
	}
	return s
}

// ---- oEmbed for sites whose pages are heavy, script-rendered or consent-gated (YouTube, Vimeo).

type oembedProvider struct {
	hosts    []string
	endpoint string
	icon     string
}

var oembedProviders = []oembedProvider{
	{[]string{"youtube.com", "youtu.be"}, "https://www.youtube.com/oembed", "https://www.youtube.com/favicon.ico"},
	{[]string{"vimeo.com"}, "https://vimeo.com/api/oembed.json", "https://vimeo.com/favicon.ico"},
}

func oembedFor(u *url.URL) (oembedProvider, string, bool) {
	host := strings.ToLower(u.Hostname())
	for _, p := range oembedProviders {
		for _, h := range p.hosts {
			if host == h || strings.HasSuffix(host, "."+h) {
				q := url.Values{"url": {u.String()}, "format": {"json"}}
				return p, p.endpoint + "?" + q.Encode(), true
			}
		}
	}
	return oembedProvider{}, "", false
}

// ParseOEmbed reads an oEmbed JSON response.
func ParseOEmbed(data []byte, p oembedProvider) (Metadata, bool) {
	var obj struct {
		Title        string `json:"title"`
		ProviderName string `json:"provider_name"`
		ThumbnailURL string `json:"thumbnail_url"`
	}
	if json.Unmarshal(data, &obj) != nil {
		return Metadata{}, false
	}
	base, _ := url.Parse(p.endpoint)
	md := Metadata{Title: Clean(obj.Title), SiteName: Clean(obj.ProviderName), ImageURL: Resolve(obj.ThumbnailURL, base), IconURL: p.icon}
	if obj.ThumbnailURL == "" {
		md.ImageURL = ""
	}
	return md, md.Title != "" || md.ImageURL != ""
}

func contains(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}
