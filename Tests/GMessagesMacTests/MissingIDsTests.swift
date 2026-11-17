import XCTest
@testable import GMessagesMac

/// Regression: phone sends conversations/messages with IDs only in nested fields (libgm b580a1a1).
final class MissingIDsTests: XCTestCase {
    private func nestedMessage(id: String, conv: String) -> GMMessage {
        var m = GMMessage()
        m.anotherMessageID.messageID = id
        m.someKindOfGroupID.conversationID = conv
        return m
    }

    private func nestedConversation(id: String, latest: String) -> GMConversation {
        var c = GMConversation()
        c.someKindOfGroupID.conversationID = id
        c.latestMessageAnotherID.messageID = latest
        return c
    }

    func testListMessagesFillsNestedIDs() throws {
        var resp = Client_ListMessagesResponse()
        resp.messages = [nestedMessage(id: "m1", conv: "c1")]
        // Round-trip through the wire format like a real response.
        let decoded = try Client_ListMessagesResponse(serializedData: resp.serializedData())
        let filled = MissingIDs.fill(decoded)
        XCTAssertEqual(filled.messages.first?.messageID, "m1")
        XCTAssertEqual(filled.messages.first?.conversationID, "c1")
    }

    func testListConversationsFillsNestedIDs() {
        var resp = Client_ListConversationsResponse()
        resp.conversations = [nestedConversation(id: "c1", latest: "m9")]
        let filled = MissingIDs.fill(resp)
        XCTAssertEqual(filled.conversations.first?.conversationID, "c1")
        XCTAssertEqual(filled.conversations.first?.latestMessageID, "m9")
    }

    func testExistingTopLevelIDsWin() {
        var m = nestedMessage(id: "nested", conv: "nestedConv")
        m.messageID = "top"; m.conversationID = "topConv"
        var resp = Client_ListMessagesResponse(); resp.messages = [m]
        let filled = MissingIDs.fill(resp)
        XCTAssertEqual(filled.messages.first?.messageID, "top")
        XCTAssertEqual(filled.messages.first?.conversationID, "topConv")
    }

    func testUpdateEventsFillNestedIDs() {
        var me = Events_MessageEvent(); me.data = [nestedMessage(id: "m2", conv: "c2")]
        var ev = GMUpdateEvents(); ev.event = .messageEvent(me)
        guard case .messageEvent(let out)? = MissingIDs.fill(ev).event else { return XCTFail("event type changed") }
        XCTAssertEqual(out.data.first?.messageID, "m2")
        XCTAssertEqual(out.data.first?.conversationID, "c2")

        var ce = Events_ConversationEvent(); ce.data = [nestedConversation(id: "c3", latest: "m3")]
        ev.event = .conversationEvent(ce)
        guard case .conversationEvent(let outC)? = MissingIDs.fill(ev).event else { return XCTFail("event type changed") }
        XCTAssertEqual(outC.data.first?.conversationID, "c3")
    }

    func testUnrelatedMessageUnchanged() {
        var c = GMConversation(); c.name = "x"
        XCTAssertEqual(MissingIDs.fill(c), c)
    }
}
