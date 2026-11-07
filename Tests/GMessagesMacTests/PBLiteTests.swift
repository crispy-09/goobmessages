import XCTest
@testable import GMessagesMac

final class PBLiteTests: XCTestCase {
    private func sampleAuth() -> GMAuthMessage {
        var a = GMAuthMessage()
        a.requestID = "abc"
        a.network = "GDitto"
        a.tachyonAuthToken = Data([1, 2, 3])
        a.configVersion.year = 2026; a.configVersion.month = 9; a.configVersion.day = 2
        a.configVersion.v1 = 4; a.configVersion.v2 = 6
        return a
    }

    func testMarshalMatchesKnownPBLite() throws {
        let data = try PBLite.marshal(sampleAuth())
        let got = try JSONSerialization.jsonObject(with: data) as! NSArray
        let expected = try JSONSerialization.jsonObject(
            with: Data(#"["abc",null,"GDitto",null,null,"AQID",[null,null,2026,9,2,null,4,null,6]]"#.utf8)) as! NSArray
        XCTAssertEqual(got, expected)
    }

    func testRoundTrip() throws {
        let original = sampleAuth()
        let decoded: GMAuthMessage = try PBLite.unmarshal(try PBLite.marshal(original))
        XCTAssertEqual(decoded, original)
    }

    func testBinaryFlaggedRepeatedStringRoundTrips() throws {
        var m = Rpc_OutgoingRPCMessage()
        m.destRegistrationIds = ["reg-1", "reg-2"]      // pblite_binary => base64 on the wire
        m.data.requestID = "r"
        let json = try PBLite.marshal(m)
        let text = String(decoding: json, as: UTF8.self)
        XCTAssertTrue(text.contains(Data("reg-1".utf8).base64EncodedString()))
        let back: Rpc_OutgoingRPCMessage = try PBLite.unmarshal(json)
        XCTAssertEqual(back.destRegistrationIds, ["reg-1", "reg-2"])
    }

    func testDecodeIgnoresUnknownTrailingFieldsAndNulls() throws {
        let json = Data(#"["x",null,"net"]"#.utf8)
        let m: GMAuthMessage = try PBLite.unmarshal(json)
        XCTAssertEqual(m.requestID, "x")
        XCTAssertEqual(m.network, "net")
        XCTAssertFalse(m.hasConfigVersion)
    }

    func testUnknownMessageNameThrows() {
        XCTAssertThrowsError(try PBLite.toSlice(wire: [], message: "does.not.Exist"))
    }
}

final class HostileInputTests: XCTestCase {
    func testHugeLengthVarintDoesNotCrash() {
        // field 1, wire type 2, length = 2^64-1
        let wire: [UInt8] = [0x0a, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01]
        XCTAssertThrowsError(try PBLite.toSlice(wire: wire, message: "authentication.AuthMessage"))
    }

    func testTruncatedVarintThrows() {
        XCTAssertThrowsError(try PBLite.toSlice(wire: [0x0a, 0x80], message: "authentication.AuthMessage"))
    }

    func testGCMHeaderWithBadChunkSizeRejected() {
        let m = try! AESGCMMedia(keyData: randomBytes(32))
        XCTAssertThrowsError(try m.decrypt(Data([0, 0, 1, 2, 3])))     // 2^0 chunk would loop forever
        XCTAssertThrowsError(try m.decrypt(Data([0, 255, 1, 2, 3])))
    }
}
