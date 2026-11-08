import XCTest
@testable import GMessagesMac

final class NotificationPlannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func alert(_ cid: String, _ name: String, _ text: String, ago: TimeInterval = 5, group: Bool = false, sender: String = "") -> NotificationAlert {
        NotificationAlert(conversationID: cid, conversationName: name, senderName: sender, text: text,
                          isGroup: group, timestamp: now.addingTimeInterval(-ago))
    }

    func testSingleMessageIsOneNotification() {
        let plan = NotificationPlanner.plan([alert("a", "Mom", "Food")], catchUp: false, now: now, previews: true)
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].title, "Mom")
        XCTAssertEqual(plan[0].body, "Food")
        XCTAssertEqual(plan[0].identifier, NotificationPlanner.identifier(for: "a"))
        XCTAssertEqual(plan[0].category, NotificationPlanner.messageCategory)
    }

    func testBurstFromOneConversationCollapsesToLatest() {
        let alerts = [alert("a", "Typer", "one", ago: 9), alert("a", "Typer", "two", ago: 8), alert("a", "Typer", "three", ago: 7)]
        let plan = NotificationPlanner.plan(alerts, catchUp: false, now: now, previews: true)
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].body, "three")
        XCTAssertTrue(plan[0].subtitle.contains("3 new messages"))
    }

    func testGroupShowsSender() {
        let plan = NotificationPlanner.plan([alert("g", "Goob chat", "hi", group: true, sender: "Jonsk")],
                                            catchUp: false, now: now, previews: true)
        XCTAssertEqual(plan[0].subtitle, "Jonsk")
    }

    func testCatchUpWithManyConversationsBecomesOneSummary() {
        let alerts = (0..<6).map { alert("c\($0)", "Person \($0)", "msg", ago: Double(600 - $0)) }
        let plan = NotificationPlanner.plan(alerts, catchUp: true, now: now, previews: true)
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].identifier, NotificationPlanner.summaryIdentifier)
        XCTAssertEqual(plan[0].title, "6 new messages")
        XCTAssertTrue(plan[0].body.hasPrefix("From Person 5"), "most recent conversation listed first")
        XCTAssertTrue(plan[0].body.hasSuffix("and 3 more"))
        XCTAssertNil(plan[0].conversationID)
    }

    func testStaleMessagesAreSummarisedEvenOutsideCatchUp() {
        let alerts = (0..<5).map { alert("c\($0)", "P\($0)", "old", ago: 3600) }
        let plan = NotificationPlanner.plan(alerts, catchUp: false, now: now, previews: true)
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].identifier, NotificationPlanner.summaryIdentifier)
    }

    func testCatchUpWithFewConversationsStaysPerConversation() {
        let alerts = [alert("a", "A", "1"), alert("a", "A", "2"), alert("b", "B", "x")]
        let plan = NotificationPlanner.plan(alerts, catchUp: true, now: now, previews: true)
        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(Set(plan.compactMap(\.conversationID)), ["a", "b"])
    }

    func testPreviewsOffHidesContent() {
        let plan = NotificationPlanner.plan([alert("a", "Mom", "secret")], catchUp: false, now: now, previews: false)
        XCTAssertEqual(plan[0].body, "New message")
        XCTAssertFalse(plan.contains { $0.body.contains("secret") || $0.subtitle.contains("secret") })
    }

    func testEmptyInputPlansNothing() {
        XCTAssertTrue(NotificationPlanner.plan([], catchUp: true, now: now, previews: true).isEmpty)
    }
}

final class MessageMatchingTests: XCTestCase {
    func testEchoConfirmsLocalCopyByTmpID() {
        let local = MessageVM(localText: "hi", tmpID: "tmp_1", conversationID: "c")
        var echo = MessageVM(localText: "hi", tmpID: "tmp_1", conversationID: "c")
        echo.isLocal = false
        echo.id = "server-id"
        XCTAssertTrue(echo.confirms(local))
    }

    func testEchoWithAttachmentConfirmsLocalCopyByContent() {
        let local = MessageVM(localText: "", tmpID: "tmp_2", conversationID: "c", pendingMediaCount: 1)
        var echo = MessageVM(localText: "", tmpID: "", conversationID: "c")
        echo.isLocal = false
        echo.id = "server-id"
        echo.media = [MediaItem(id: "m", key: Data(), mime: "image/jpeg", name: "x.jpg", thumbID: "", thumbKey: Data())]
        XCTAssertTrue(echo.confirms(local))
    }

    func testOtherConversationNeverConfirms() {
        let local = MessageVM(localText: "hi", tmpID: "tmp_3", conversationID: "c1")
        var echo = MessageVM(localText: "hi", tmpID: "tmp_3", conversationID: "c2")
        echo.isLocal = false
        XCTAssertFalse(echo.confirms(local))
    }

    func testSummaryText() {
        var m = MessageVM(localText: "", tmpID: "t", conversationID: "c")
        m.media = [MediaItem(id: "a", key: Data(), mime: "audio/mp4", name: "", thumbID: "", thumbKey: Data())]
        XCTAssertEqual(m.summaryText, "🎤 Audio message")
        m.text = "hello"
        XCTAssertEqual(m.summaryText, "hello")
    }
}

final class MediaFormatTests: XCTestCase {
    func testKnownTypesMatchLibgm() {
        XCTAssertEqual(GMClient.mediaFormat("image/jpeg"), 1)
        XCTAssertEqual(GMClient.mediaFormat("audio/mp4"), 19)      // voice messages
        XCTAssertEqual(GMClient.mediaFormat("audio/mpeg"), 17)
        XCTAssertEqual(GMClient.mediaFormat("audio/mp3"), 16)
        XCTAssertEqual(GMClient.mediaFormat("application/pdf"), 25)
        XCTAssertEqual(GMClient.mediaFormat("IMAGE/PNG"), 3)
    }

    func testFallbacks() {
        XCTAssertEqual(GMClient.mediaFormat("image/heic"), 7)
        XCTAssertEqual(GMClient.mediaFormat("video/quicktime"), 13)
        XCTAssertEqual(GMClient.mediaFormat("audio/flac"), 23)
        XCTAssertEqual(GMClient.mediaFormat("text/markdown"), 26)
        XCTAssertEqual(GMClient.mediaFormat("application/x-whatever"), 37)
    }

    func testMIMENormalisation() {
        XCTAssertEqual(AttachmentPrep.normalizedMIME("audio/x-m4a"), "audio/mp4")
        XCTAssertEqual(AttachmentPrep.mime(forFileName: "Voice.m4a"), "audio/mp4")
        XCTAssertEqual(AttachmentPrep.normalizedMIME("Image/PJPEG"), "image/jpeg")
    }

    func testOversizedAttachmentRejected() {
        XCTAssertNil(AttachmentPrep.prepare(data: Data(count: AttachmentPrep.maxBytes + 1), name: "big.bin", mime: "application/zip"))
        XCTAssertNil(AttachmentPrep.prepare(data: Data(), name: "empty.bin", mime: "application/zip"))
    }

    func testWaveformIsDeterministic() {
        XCTAssertEqual(Waveform.heights(for: "abc", count: 10), Waveform.heights(for: "abc", count: 10))
        XCTAssertTrue(Waveform.heights(for: "abc", count: 10).allSatisfy { $0 >= 0.25 && $0 <= 1 })
    }
}
