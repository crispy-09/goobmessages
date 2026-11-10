// Package urlsafe guards fetches and link opens for URLs that come from message or conversation data
// (untrusted). Port of URLSafety from the Mac app.
package urlsafe

import (
	"net"
	"net/url"
	"strconv"
	"strings"
)

var blockedSuffixes = []string{".localhost", ".local", ".internal", ".lan", ".home.arpa", ".intranet", ".corp"}

// IsPublicHTTPS: https only, public host. Refuses localhost/.local/.internal/…, single-label hosts, non-ASCII or
// odd characters, IPv6 literals, userinfo, and IPv4 literals unless canonical dotted-quad in a public range.
// Resolvers also accept forms like 0x7f.0.0.1, 127.1 or 017.0.0.1, so any host whose last label is numeric/hex
// is treated as an IP.
func IsPublicHTTPS(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil || !strings.EqualFold(u.Scheme, "https") || u.User != nil || u.Opaque != "" {
		return false
	}
	if p := u.Port(); p != "" && p != "443" {
		return false
	}
	host := strings.ToLower(u.Hostname())
	host = strings.TrimSuffix(host, ".")
	if host == "" {
		return false
	}
	for _, r := range host {
		if !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '.' || r == '-' || r == '_') {
			return false // also rejects IPv6 literals and percent-encoding
		}
	}
	if host == "localhost" {
		return false
	}
	for _, s := range blockedSuffixes {
		if strings.HasSuffix(host, s) {
			return false
		}
	}
	labels := strings.Split(host, ".")
	if len(labels) < 2 {
		return false
	}
	for _, l := range labels {
		if l == "" {
			return false
		}
	}
	last := labels[len(labels)-1]
	if allDigits(last) || strings.HasPrefix(last, "0x") {
		if len(labels) != 4 {
			return false
		}
		var b [4]byte
		for i, l := range labels {
			if !allDigits(l) || (l != "0" && strings.HasPrefix(l, "0")) {
				return false
			}
			v, err := strconv.Atoi(l)
			if err != nil || v > 255 {
				return false
			}
			b[i] = byte(v)
		}
		return IsPublicIPv4(b)
	}
	return true
}

// IsPublicIPv4 rejects this-network, private, CGNAT, loopback, link-local, IETF, benchmarking, multicast and
// reserved ranges.
func IsPublicIPv4(b [4]byte) bool {
	a, c := b[0], b[1]
	switch {
	case a == 0, a == 10, a == 127:
		return false
	case a == 100 && c >= 64 && c <= 127:
		return false
	case a == 169 && c == 254:
		return false
	case a == 172 && c >= 16 && c <= 31:
		return false
	case a == 192 && c == 168:
		return false
	case a == 192 && c == 0 && b[2] == 0:
		return false
	case a == 198 && (c == 18 || c == 19):
		return false
	case a >= 224:
		return false
	}
	return true
}

// IsPublicIPv6 rejects unspecified, loopback, IPv4-compatible, multicast, unique-local and link/site-local
// addresses, and checks the embedded IPv4 address of mapped, NAT64 and 6to4 forms.
func IsPublicIPv6(b [16]byte) bool {
	zero := func(n int) bool {
		for _, v := range b[:n] {
			if v != 0 {
				return false
			}
		}
		return true
	}
	v4 := func(i int) [4]byte { return [4]byte{b[i], b[i+1], b[i+2], b[i+3]} }
	switch {
	case zero(10) && b[10] == 0xff && b[11] == 0xff:
		return IsPublicIPv4(v4(12))
	case zero(12):
		return false
	case b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xff && b[3] == 0x9b:
		return IsPublicIPv4(v4(12))
	case b[0] == 0x20 && b[1] == 0x02:
		return IsPublicIPv4(v4(2))
	case b[0] == 0xff, b[0]&0xfe == 0xfc, b[0] == 0xfe && b[1]&0x80 == 0x80:
		return false
	}
	return true
}

// IsPublicIP checks a resolved address (used when dialing, so DNS answers can't point fetches at the LAN).
func IsPublicIP(ip net.IP) bool {
	if v4 := ip.To4(); v4 != nil {
		return IsPublicIPv4([4]byte(v4))
	}
	if v6 := ip.To16(); v6 != nil {
		return IsPublicIPv6([16]byte(v6))
	}
	return false
}

var googleOwned = []string{"google.com", "googleusercontent.com", "ggpht.com", "gstatic.com", "googleapis.com"}

// IsGoogleOwned reports whether the URL's host is a Google domain (or subdomain).
func IsGoogleOwned(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil {
		return false
	}
	host := strings.TrimSuffix(strings.ToLower(u.Hostname()), ".")
	for _, d := range googleOwned {
		if host == d || strings.HasSuffix(host, "."+d) {
			return true
		}
	}
	return false
}

// IsOpenableLink allows only http(s) and mailto/tel links to be handed to the OS from message text.
func IsOpenableLink(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil {
		return false
	}
	switch strings.ToLower(u.Scheme) {
	case "http", "https":
		return u.Host != "" && u.User == nil
	case "mailto", "tel":
		return u.Opaque != ""
	}
	return false
}

func allDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}
