import Foundation
import AppKit
import ImageIO

// Link previews fetch URLs chosen by the message sender, so everything here treats the network as hostile:
// all requests go through `SafeFetch` (https only, every hop a public host resolving to public addresses, size caps),
// on a session with no cookies/credentials/cache; images are decoded downsampled; text is sanitised.
// LinkPresentation (LPMetadataProvider) is deliberately not used: it follows redirects and loads
// sub-resources on its own, so none of these checks could be enforced.

struct LinkMetadata: Equatable {
    var title: String?
    var siteName: String?
    var imageURL: URL?
    var iconURL: URL?
}

/// Pure Open Graph / Twitter card / <title> extraction. Tested in `LinkPreviewTests`.
enum LinkMetadataParser {
    static let maxTitleLength = 300

    private static let metaTag = try! NSRegularExpression(pattern: #"<meta\s[^>]*>"#, options: [.caseInsensitive])
    private static let linkTag = try! NSRegularExpression(pattern: #"<link\s[^>]*>"#, options: [.caseInsensitive])
    private static let titleTag = try! NSRegularExpression(pattern: #"<title[^>]*>([\s\S]*?)</title>"#, options: [.caseInsensitive])
    private static let attribute = try! NSRegularExpression(
        pattern: #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#)

    static func parse(html: String, baseURL: URL) -> LinkMetadata {
        // Metadata lives in <head>; ignore the body so later markup can't override it.
        var doc = html
        if let r = html.range(of: "</head", options: .caseInsensitive) { doc = String(html[..<r.lowerBound]) }
        let ns = doc as NSString

        var meta: [String: String] = [:]
        for m in metaTag.matches(in: doc, range: NSRange(location: 0, length: ns.length)) {
            let attrs = attributes(of: ns.substring(with: m.range))
            guard let content = attrs["content"],
                  let key = (attrs["property"] ?? attrs["name"] ?? attrs["itemprop"])?.lowercased(),
                  meta[key] == nil else { continue }
            meta[key] = content
        }

        var htmlTitle: String?
        if let m = titleTag.firstMatch(in: doc, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 {
            htmlTitle = ns.substring(with: m.range(at: 1))
        }

        var touchIcon: URL?, plainIcon: URL?
        for m in linkTag.matches(in: doc, range: NSRange(location: 0, length: ns.length)) {
            let attrs = attributes(of: ns.substring(with: m.range))
            guard let rel = attrs["rel"]?.lowercased(), let href = attrs["href"] else { continue }
            let rels = rel.split(whereSeparator: \.isWhitespace)
            // ImageIO can't render SVG.
            if (attrs["type"]?.lowercased().contains("svg") ?? false) || href.lowercased().hasSuffix(".svg") { continue }
            if rels.contains("apple-touch-icon") || rels.contains("apple-touch-icon-precomposed") {
                if touchIcon == nil { touchIcon = resolve(href, against: baseURL) }
            } else if rels.contains("icon") {
                if plainIcon == nil { plainIcon = resolve(href, against: baseURL) }
            }
        }

        let title = [meta["og:title"], meta["twitter:title"], htmlTitle].lazy.compactMap { $0.map(clean) }.first { !$0.isEmpty }
        let image = ["og:image:secure_url", "og:image", "og:image:url", "twitter:image", "twitter:image:src"]
            .lazy.compactMap { meta[$0].flatMap { resolve($0, against: baseURL) } }.first
        let site = meta["og:site_name"].map(clean).flatMap { $0.isEmpty ? nil : $0 }
        let icon = touchIcon ?? plainIcon ?? resolve("/favicon.ico", against: baseURL)
        return LinkMetadata(title: title, siteName: site, imageURL: image, iconURL: icon)
    }

    static func attributes(of tag: String) -> [String: String] {
        let ns = tag as NSString
        var out: [String: String] = [:]
        for m in attribute.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            guard out[name] == nil else { continue }
            for g in 2...4 where m.range(at: g).location != NSNotFound {
                out[name] = decodeEntities(ns.substring(with: m.range(at: g)))
                break
            }
        }
        return out
    }

    /// Resolves a (possibly relative / protocol-relative) reference. Cleartext is upgraded; result must be https.
    static func resolve(_ raw: String, against base: URL) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "%20")
        guard !s.isEmpty, s.count < 2048, var c = URL(string: s, relativeTo: base).flatMap({
            URLComponents(url: $0.absoluteURL, resolvingAgainstBaseURL: false) }) else { return nil }
        if c.scheme?.lowercased() == "http" { c.scheme = "https"; if c.port == 80 { c.port = nil } }
        guard let u = c.url, u.scheme?.lowercased() == "https" else { return nil }
        return u
    }

    /// Decodes entities, strips control/bidi-override characters (spoofing), collapses whitespace, caps length.
    static func clean(_ s: String) -> String {
        let decoded = decodeEntities(s)
        let scalars = decoded.unicodeScalars.filter { u in
            !(u.properties.generalCategory == .control && !u.properties.isWhitespace)
                && !(0x202A...0x202E).contains(u.value) && !(0x2066...0x2069).contains(u.value)
        }
        let collapsed = String(String.UnicodeScalarView(scalars))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.count > maxTitleLength ? String(collapsed.prefix(maxTitleLength)) + "…" : collapsed
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(12).firstIndex(of: ";"),
               let rep = entity(String(s[s.index(after: i)..<semi])) {
                out += rep
                i = s.index(after: semi)
                continue
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }

    private static func entity(_ name: String) -> String? {
        switch name.lowercased() {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        case "mdash": return "—"
        case "ndash": return "–"
        case "hellip": return "…"
        case "rsquo": return "’"
        case "lsquo": return "‘"
        case "rdquo": return "”"
        case "ldquo": return "“"
        default: break
        }
        guard name.hasPrefix("#") else { return nil }
        let digits = name.dropFirst()
        let value: UInt32?
        if digits.first == "x" || digits.first == "X" { value = UInt32(digits.dropFirst(), radix: 16) }
        else { value = UInt32(digits, radix: 10) }
        guard let v = value, v != 0, let scalar = Unicode.Scalar(v) else { return nil }
        return String(Character(scalar))
    }
}

/// oEmbed for sites whose pages are heavy, script-rendered or consent-gated (YouTube serves a ~1 MB page, or a
/// captcha/consent wall, to non-browsers). Their oEmbed JSON endpoints return title + thumbnail directly.
enum OEmbed {
    struct Provider { var hosts: [String]; var endpoint: String; var icon: String }

    static let providers = [
        Provider(hosts: ["youtube.com", "youtu.be"], endpoint: "https://www.youtube.com/oembed",
                 icon: "https://www.youtube.com/favicon.ico"),
        Provider(hosts: ["vimeo.com"], endpoint: "https://vimeo.com/api/oembed.json", icon: "https://vimeo.com/favicon.ico"),
    ]

    static func provider(for url: URL) -> Provider? {
        guard let host = url.host?.lowercased() else { return nil }
        return providers.first { $0.hosts.contains { host == $0 || host.hasSuffix("." + $0) } }
    }

    static func endpoint(for url: URL) -> URL? {
        guard let p = provider(for: url), var c = URLComponents(string: p.endpoint) else { return nil }
        c.queryItems = [URLQueryItem(name: "url", value: url.absoluteString), URLQueryItem(name: "format", value: "json")]
        return c.url
    }

    /// Pure: parses an oEmbed JSON response. Thumbnail must be https (cleartext is upgraded).
    static func parse(_ data: Data, provider: Provider) -> LinkMetadata? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let title = (obj["title"] as? String).map(LinkMetadataParser.clean).flatMap { $0.isEmpty ? nil : $0 }
        let site = (obj["provider_name"] as? String).map(LinkMetadataParser.clean)
        let thumb = (obj["thumbnail_url"] as? String).flatMap { LinkMetadataParser.resolve($0, against: URL(string: provider.endpoint)!) }
        guard title != nil || thumb != nil else { return nil }
        return LinkMetadata(title: title, siteName: site, imageURL: thumb, iconURL: URL(string: provider.icon))
    }
}

struct LinkPreviewResult {
    var title: String
    var siteName: String?
    var image: NSImage?
    var icon: NSImage?
    var finalURL: URL
}

final class LinkPreviewFetcher {
    static let shared = LinkPreviewFetcher()

    static let maxHTMLBytes = 512 * 1024
    static let maxJSONBytes = 64 * 1024
    static let maxImageBytes = 5 * 1024 * 1024
    static let maxImagePixels = 40_000_000
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.urlCredentialStorage = nil
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 15
        c.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: c)
    }()

    func preview(for url: URL) async -> LinkPreviewResult? {
        if let r = await oembedPreview(for: url) { return r }
        guard let resp = await get(url, accept: "text/html,application/xhtml+xml;q=0.9,image/*;q=0.8",
                                   limit: Self.maxHTMLBytes, allowTruncation: true) else { return nil }
        let final = resp.http.url ?? url
        let mime = resp.http.mimeType?.lowercased() ?? ""

        // A direct link to an image: show the image itself.
        if mime.hasPrefix("image/") {
            guard resp.complete, let img = Self.decodeImage(resp.data, maxPixel: 640) else { return nil }
            return LinkPreviewResult(title: "", siteName: nil, image: img, icon: nil, finalURL: final)
        }
        guard mime == "text/html" || mime == "application/xhtml+xml" else { return nil }

        let html = Self.decodeText(resp.data, encodingName: resp.http.textEncodingName)
        return await result(for: LinkMetadataParser.parse(html: html, baseURL: final), finalURL: final)
    }

    private func oembedPreview(for url: URL) async -> LinkPreviewResult? {
        guard let provider = OEmbed.provider(for: url), let endpoint = OEmbed.endpoint(for: url),
              let resp = await get(endpoint, accept: "application/json", limit: Self.maxJSONBytes),
              let md = OEmbed.parse(resp.data, provider: provider) else { return nil }
        return await result(for: md, finalURL: url)
    }

    private func result(for md: LinkMetadata, finalURL: URL) async -> LinkPreviewResult? {
        async let image = loadImage(md.imageURL, maxPixel: 640)
        async let icon = loadImage(md.iconURL, maxPixel: 64)
        let (img, ic) = await (image, icon)
        let title = md.title ?? ""
        guard !title.isEmpty || img != nil else { return nil }
        return LinkPreviewResult(title: title, siteName: md.siteName, image: img, icon: ic, finalURL: finalURL)
    }

    private func loadImage(_ url: URL?, maxPixel: Int) async -> NSImage? {
        guard let url, let resp = await get(url, accept: "image/*", limit: Self.maxImageBytes),
              (resp.http.mimeType?.lowercased() ?? "image/").hasPrefix("image/") else { return nil }
        return Self.decodeImage(resp.data, maxPixel: maxPixel)
    }

    private func get(_ url: URL, accept: String, limit: Int, allowTruncation: Bool = false) async -> SafeFetch.Response? {
        var req = URLRequest(url: url)
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(Locale.preferredLanguages.prefix(3).joined(separator: ", "), forHTTPHeaderField: "Accept-Language")
        return await SafeFetch.get(req, session: session, limit: limit, allowTruncation: allowTruncation)
    }

    static func decodeText(_ data: Data, encodingName: String?) -> String {
        if let name = encodingName?.lowercased(), name != "utf-8", name != "utf8" {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId,
               let s = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) {
                return s
            }
        }
        // Lossy UTF-8 so a body truncated mid-character still decodes.
        return String(decoding: data, as: UTF8.self)
    }

    /// Downsampled decode; refuses decompression bombs. Use for any image whose bytes came from an untrusted URL.
    static func decodeImage(_ data: Data, maxPixel: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        let (pixels, overflow) = w.multipliedReportingOverflow(by: h)
        guard !overflow, pixels <= maxImagePixels else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
