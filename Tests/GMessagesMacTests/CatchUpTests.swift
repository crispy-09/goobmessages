import XCTest
@testable import GMessagesMac

/// Regression tests for notification spam after launch/reconnect.
final class CatchUpTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func alert(_ cid: String) -> NotificationAlert {
        NotificationAlert(conversationID: cid, conversationName: cid, senderName: "", text: "x", isGroup: false,
                          timestamp: now.addingTimeInterval(-600))
    }

    // Backlog after launch/reconnect often contains messages already read on the phone: no alert for those.
    func testDropReadRemovesConversationsReadOnPhone() {
        let alerts = [alert("read"), alert("unread"), alert("unknown")]
        let state: [String: Bool] = ["read": false, "unread": true]
        let kept = NotificationPlanner.dropRead(alerts, isUnread: { state[$0] })
        XCTAssertEqual(kept.map(\.conversationID), ["unread", "unknown"])
    }

    // The catch-up window slides with each new alert but never passes its hard deadline.
    func testCatchUpEndSlidesButIsCapped() {
        let deadline = now.addingTimeInterval(45)
        XCTAssertEqual(NotificationPlanner.catchUpEnd(lastActivity: now, quiet: 4, deadline: deadline), now.addingTimeInterval(4))
        let late = now.addingTimeInterval(43)
        XCTAssertEqual(NotificationPlanner.catchUpEnd(lastActivity: late, quiet: 4, deadline: deadline), deadline)
    }
}
