import XCTest
@testable import GMessagesMac

final class LinkMetadataParserTests: XCTestCase {
    let base = URL(string: "https://www.example.com/articles/42?x=1")!

    func testOpenGraphPreferredOverTitle() {
        let html = """
        <html><head><title>Fallback</title>
        <meta property="og:title" content="Big &amp; Bold &#8212; News">
        <meta property='og:site_name' content='Example'>
        <meta property="og:image" content="/img/hero.jpg">
        <link rel="icon" href="/favicon.png"><link rel="apple-touch-icon" href="https://cdn.example.com/touch.png">
        </head><body><meta property="og:title" content="body override"></body></html>
        """
        let md = LinkMetadataParser.parse(html: html, baseURL: base)
        XCTAssertEqual(md.title, "Big & Bold — News")
        XCTAssertEqual(md.siteName, "Example")
        XCTAssertEqual(md.imageURL?.absoluteString, "https://www.example.com/img/hero.jpg")
        XCTAssertEqual(md.iconURL?.absoluteString, "https://cdn.example.com/touch.png")
    }

    func testFallbacks() {
        let html = "<HEAD><TITLE>\n  Plain   title\n</TITLE><meta name=twitter:image content=//img.example.net/a.png></HEAD>"
        let md = LinkMetadataParser.parse(html: html, baseURL: base)
        XCTAssertEqual(md.title, "Plain title")
        XCTAssertEqual(md.imageURL?.absoluteString, "https://img.example.net/a.png")
        XCTAssertEqual(md.iconURL?.absoluteString, "https://www.example.com/favicon.ico")
    }

    func testRejectsNonHTTPSchemesAndUpgradesCleartext() {
        let html = """
        <meta property="og:image" content="javascript:alert(1)">
        <meta name="twitter:image" content="http://img.example.com/x.jpg">
        <link rel="icon" href="data:image/png;base64,AAAA">
        <link rel="icon" href="/i.svg">
        """
        let md = LinkMetadataParser.parse(html: html, baseURL: base)
        XCTAssertEqual(md.imageURL?.absoluteString, "https://img.example.com/x.jpg")
        XCTAssertEqual(md.iconURL?.absoluteString, "https://www.example.com/favicon.ico")
    }

    func testCleanStripsControlAndBidiAndCaps() {
        XCTAssertEqual(LinkMetadataParser.clean("a\u{202E}b\u{0007}c\u{2066}"), "abc")
        XCTAssertEqual(LinkMetadataParser.clean("&#x41;&#66;&lt;&unknown;&#0;"), "AB<&unknown;&#0;")
        let long = LinkMetadataParser.clean(String(repeating: "x", count: 1000))
        XCTAssertEqual(long.count, LinkMetadataParser.maxTitleLength + 1)
    }

    func testMalformedInputDoesNotCrash() {
        for html in ["", "<meta", "<meta content=\"x", "<title>unterminated", "&", "&#xFFFFFFFFFF;", "<link rel=icon>"] {
            _ = LinkMetadataParser.parse(html: html, baseURL: base)
        }
    }
}

final class LinkPreviewSafetyTests: XCTestCase {
    func testNumericAndAlternateIPFormsBlocked() {
        let bad = ["https://0x7f.0.0.1/", "https://127.1/", "https://017.0.0.1/", "https://2130706433/",
                   "https://100.64.0.1/", "https://198.18.0.1/", "https://localhost./", "https://foo.localhost/",
                   "https://router.home.arpa/", "https://a..b/", "https://1.2.3.256/", "https://0.0.0.0/"]
        for u in bad { XCTAssertFalse(URLSafety.isPublicHTTPS(URL(string: u)!), u) }
        XCTAssertTrue(URLSafety.isPublicHTTPS(URL(string: "https://8.8.8.8/")!))
        XCTAssertTrue(URLSafety.isPublicHTTPS(URL(string: "https://www.example.com./x")!))
        XCTAssertTrue(URLSafety.isPublicHTTPS(URL(string: "https://123.example.com/")!))
    }

    func testIPv6Classification() {
        func v6(_ s: String) -> [UInt8] {
            var a = in6_addr(); XCTAssertEqual(inet_pton(AF_INET6, s, &a), 1, s)
            return withUnsafeBytes(of: a) { Array($0) }
        }
        for s in ["::", "::1", "fe80::1", "fc00::1", "fd12::1", "ff02::1", "::ffff:127.0.0.1", "::ffff:10.0.0.1",
                  "64:ff9b::192.168.0.1", "2002:c0a8:0001::1"] {
            XCTAssertFalse(URLSafety.isPublicIPv6(v6(s)), s)
        }
        XCTAssertTrue(URLSafety.isPublicIPv6(v6("2001:4860:4860::8888")))
        XCTAssertTrue(URLSafety.isPublicIPv6(v6("::ffff:8.8.8.8")))
    }

    @MainActor func testFetchURLUpgradesSchemeless() {
        // NSDataDetector turns "example.com" into http://example.com
        XCTAssertEqual(LinkPreviewStore.fetchURL(for: URL(string: "http://example.com/a#frag")!)?.absoluteString,
                       "https://example.com/a")
        XCTAssertNil(LinkPreviewStore.fetchURL(for: URL(string: "http://192.168.1.1/")!))
        XCTAssertNil(LinkPreviewStore.fetchURL(for: URL(string: "ftp://example.com/")!))
    }

    func testDNSCheckRejectsLoopbackName() async {
        let ok = await SafeFetch.resolvesToPublicAddresses("localhost")
        XCTAssertFalse(ok)
    }
}

final class OEmbedTests: XCTestCase {
    func testProviderMatching() {
        for u in ["https://www.youtube.com/watch?v=x", "https://youtu.be/x", "https://m.youtube.com/watch?v=x", "https://vimeo.com/1"] {
            XCTAssertNotNil(OEmbed.provider(for: URL(string: u)!), u)
        }
        for u in ["https://notyoutube.com/watch", "https://youtube.com.evil.net/x", "https://example.com/"] {
            XCTAssertNil(OEmbed.provider(for: URL(string: u)!), u)
        }
    }

    func testEndpointEncodesURL() {
        let e = OEmbed.endpoint(for: URL(string: "https://www.youtube.com/watch?v=abc&t=10")!)!
        let c = URLComponents(url: e, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(c.host, "www.youtube.com")
        XCTAssertEqual(c.queryItems?.first { $0.name == "url" }?.value, "https://www.youtube.com/watch?v=abc&t=10")
    }

    func testParse() {
        let p = OEmbed.providers[0]
        let json = #"{"title":"Never \u202eGonna","provider_name":"YouTube","thumbnail_url":"http://i.ytimg.com/vi/x/hq.jpg"}"#
        let md = OEmbed.parse(Data(json.utf8), provider: p)
        XCTAssertEqual(md?.title, "Never Gonna")
        XCTAssertEqual(md?.siteName, "YouTube")
        XCTAssertEqual(md?.imageURL?.absoluteString, "https://i.ytimg.com/vi/x/hq.jpg")
        XCTAssertNil(OEmbed.parse(Data("[]".utf8), provider: p))
        XCTAssertNil(OEmbed.parse(Data(#"{"thumbnail_url":"javascript:x"}"#.utf8), provider: p))
    }
}

final class LinkPreviewModeTests: XCTestCase {
    func testAllows() {
        XCTAssertTrue(LinkPreviewMode.everyone.allows(fromMe: false, senderIsContact: false))
        XCTAssertTrue(LinkPreviewMode.contacts.allows(fromMe: true, senderIsContact: false))
        XCTAssertTrue(LinkPreviewMode.contacts.allows(fromMe: false, senderIsContact: true))
        XCTAssertFalse(LinkPreviewMode.contacts.allows(fromMe: false, senderIsContact: false))
        XCTAssertFalse(LinkPreviewMode.off.allows(fromMe: true, senderIsContact: true))
    }

    func testCrossHostRedirectDropsClientHeaders() {
        XCTAssertFalse(SafeFetch.crossHostHeaders.contains("x-goog-api-key"))
        XCTAssertFalse(SafeFetch.crossHostHeaders.contains("origin"))
        XCTAssertTrue(SafeFetch.crossHostHeaders.contains("user-agent"))
    }
}
