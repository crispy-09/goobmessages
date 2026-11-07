import XCTest
@testable import GMessagesMac

final class CryptoTests: XCTestCase {
    func testAESCTRRoundTrip() throws {
        let h = AESCTRHelper.generate()
        let msg = Data("hello, phone".utf8)
        XCTAssertEqual(try h.decrypt(try h.encrypt(msg)), msg)
    }

    func testAESCTRRejectsTampering() throws {
        let h = AESCTRHelper.generate()
        var enc = try h.encrypt(Data(repeating: 7, count: 64))
        enc[3] ^= 0xff
        XCTAssertThrowsError(try h.decrypt(enc))
    }

    func testAESCTRRejectsWrongKey() throws {
        let enc = try AESCTRHelper.generate().encrypt(Data("secret".utf8))
        XCTAssertThrowsError(try AESCTRHelper.generate().decrypt(enc))
    }

    func testChunkedGCMRoundTripAcrossChunkBoundaries() throws {
        let key = randomBytes(32)
        let m = try AESGCMMedia(keyData: key)
        for size in [0, 1, 1000, 32768 - 28, 32768 - 27, 100_000] {
            let plain = randomBytes(size)
            XCTAssertEqual(try m.decrypt(try m.encrypt(plain)), plain, "size \(size)")
        }
    }

    func testChunkedGCMDetectsTruncation() throws {
        let m = try AESGCMMedia(keyData: randomBytes(32))
        let enc = try m.encrypt(randomBytes(100_000))
        XCTAssertThrowsError(try m.decrypt(enc.prefix(enc.count - 40)))
    }

    func testHKDFIsDeterministic() {
        let a = GMKDF.hkdf(key: Data([1]), salt: Data([2]), info: Data([3]))
        XCTAssertEqual(a, GMKDF.hkdf(key: Data([1]), salt: Data([2]), info: Data([3])))
        XCTAssertNotEqual(a, GMKDF.hkdf(key: Data([1]), salt: Data([2]), info: Data([4])))
        XCTAssertEqual(a.count, 32)
    }

    func testSAPISIDHashFormat() {
        let h = sapisidHash(origin: "https://messages.google.com", sapisid: "abc")
        XCTAssertTrue(h.hasPrefix("SAPISIDHASH "))
        XCTAssertEqual(h.split(separator: "_").last?.count, 40)   // SHA-1 hex
    }
}

final class LinkSafetyTests: XCTestCase {
    @MainActor func testPreviewGuardBlocksPrivateAndCleartext() {
        let bad = ["http://example.com", "https://localhost/x", "https://192.168.1.5/", "https://10.0.0.1/",
                   "https://127.0.0.1/", "https://169.254.169.254/latest", "https://printer.local/", "https://[::1]/", "https://intranet/"]
        for u in bad { XCTAssertFalse(LinkPreviewStore.isSafe(URL(string: u)!), u) }
        XCTAssertTrue(LinkPreviewStore.isSafe(URL(string: "https://apps.microsoft.com/detail/x")!))
    }
}

final class URLSafetyTests: XCTestCase {
    func testPublicHTTPSRules() {
        XCTAssertTrue(URLSafety.isPublicHTTPS(URL(string: "https://lh3.googleusercontent.com/abc")!))
        XCTAssertFalse(URLSafety.isPublicHTTPS(URL(string: "http://lh3.googleusercontent.com/abc")!))
        XCTAssertFalse(URLSafety.isPublicHTTPS(URL(string: "https://192.168.0.2/a")!))
        XCTAssertTrue(URLSafety.isGoogleOwned(URL(string: "https://lh3.googleusercontent.com/abc")!))
        XCTAssertFalse(URLSafety.isGoogleOwned(URL(string: "https://evilgoogle.com/abc")!))
    }
}
