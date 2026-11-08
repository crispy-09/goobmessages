import Foundation
import UserNotifications

/// One incoming message that may deserve an alert.
struct NotificationAlert: Equatable {
    var conversationID: String
    var conversationName: String
    var senderName: String
    var text: String
    var isGroup: Bool
    var timestamp: Date
}

/// A notification ready to post. `identifier` is per conversation, so a newer alert *replaces* the older one
/// instead of stacking a new banner for every message.
struct PlannedNotification: Equatable {
    var identifier: String
    var title: String
    var subtitle: String
    var body: String
    var conversationID: String?     // nil for the summary notification
    var category: String
}

/// Pure decision logic (unit-tested): turns a batch of alerts into the fewest useful notifications.
///
/// * Alerts are grouped per conversation; each conversation gets at most one notification.
/// * During catch-up (after launch, sleep or a reconnect) or when any alert is older than `staleAfter`,
///   messages are summarised: per conversation if there are few, otherwise one summary for everything.
enum NotificationPlanner {
    static let staleAfter: TimeInterval = 120
    static let maxConversationsBeforeSummary = 3
    static let summaryIdentifier = "goob.summary"
    static let messageCategory = "GOOB_MESSAGE"
    static let summaryCategory = "GOOB_SUMMARY"

    static func identifier(for conversationID: String) -> String { "conv." + conversationID }

    static func plan(_ alerts: [NotificationAlert], catchUp: Bool, now: Date, previews: Bool) -> [PlannedNotification] {
        guard !alerts.isEmpty else { return [] }
        var order: [String] = []                       // conversations, oldest activity first
        var groups: [String: [NotificationAlert]] = [:]
        for a in alerts.sorted(by: { $0.timestamp < $1.timestamp }) {
            if groups[a.conversationID] == nil { order.append(a.conversationID) }
            else { order.removeAll { $0 == a.conversationID }; order.append(a.conversationID) }
            groups[a.conversationID, default: []].append(a)
        }
        let summarize = catchUp || alerts.contains { now.timeIntervalSince($0.timestamp) > staleAfter }

        if summarize && order.count > maxConversationsBeforeSummary {
            let names = order.reversed().compactMap { cid -> String? in
                guard let last = groups[cid]?.last else { return nil }
                return displayName(last)
            }
            let body: String
            if previews {
                let shown = names.prefix(3).joined(separator: ", ")
                body = names.count > 3 ? "From \(shown) and \(names.count - 3) more" : "From \(shown)"
            } else {
                body = "From \(names.count) conversations"
            }
            return [PlannedNotification(identifier: summaryIdentifier, title: "\(alerts.count) new messages",
                                        subtitle: "", body: body, conversationID: nil, category: summaryCategory)]
        }

        return order.compactMap { cid -> PlannedNotification? in
            guard let items = groups[cid], let last = items.last else { return nil }
            let count = items.count
            var subtitle = last.isGroup ? last.senderName : ""
            let body: String
            if !previews {
                body = count > 1 ? "\(count) new messages" : "New message"
            } else {
                body = last.text
                if count > 1 {
                    let tag = "\(count) new messages"
                    subtitle = subtitle.isEmpty ? tag : "\(tag) · \(subtitle)"
                }
            }
            return PlannedNotification(identifier: identifier(for: cid), title: displayName(last), subtitle: subtitle,
                                       body: body, conversationID: cid, category: messageCategory)
        }
    }

    private static func displayName(_ a: NotificationAlert) -> String {
        a.conversationName.isEmpty ? (a.senderName.isEmpty ? "Someone" : a.senderName) : a.conversationName
    }
}

/// Buffers alerts, applies `NotificationPlanner`, and posts/clears system notifications.
/// Messages that arrive in a burst (e.g. everything delivered at once after the Mac wakes) become one or a few
/// notifications with a single sound, instead of one banner and sound per message.
@MainActor
final class NotificationCoordinator {
    nonisolated static let replyAction = "GOOB_REPLY"
    nonisolated static let markReadAction = "GOOB_MARK_READ"

    private var pending: [NotificationAlert] = []
    private var firstPendingAt: Date?
    private var flushTask: Task<Void, Never>?
    private var catchUpTask: Task<Void, Never>?
    private(set) var inCatchUp = false
    private var lastSoundAt = Date.distantPast

    /// Registers the reply / mark-as-read actions. Call once at launch.
    nonisolated static func registerCategories() {
        guard AppEnv.canNotify else { return }
        let reply = UNTextInputNotificationAction(identifier: replyAction, title: "Reply", options: [],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        let markRead = UNNotificationAction(identifier: markReadAction, title: "Mark as Read", options: [])
        let message = UNNotificationCategory(identifier: NotificationPlanner.messageCategory, actions: [reply, markRead],
                                             intentIdentifiers: [], options: [])
        let summary = UNNotificationCategory(identifier: NotificationPlanner.summaryCategory, actions: [],
                                             intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([message, summary])
    }

    func enqueue(_ alert: NotificationAlert) {
        guard AppEnv.canNotify, Prefs.notificationsEnabled, !Prefs.hiddenAlerts.contains(alert.conversationID) else { return }
        pending.append(alert)
        if firstPendingAt == nil { firstPendingAt = Date() }
        scheduleFlush()
    }

    /// Start holding alerts (launch, sleep, reconnect). They are summarised when catch-up ends.
    func beginCatchUp() {
        inCatchUp = true
        flushTask?.cancel()
        catchUpTask?.cancel()
        catchUpTask = Task { [weak self] in          // safety net: never hold alerts forever
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard !Task.isCancelled else { return }
            self?.finishCatchUp()
        }
    }

    /// Called once the connection is back; waits briefly for the backlog to finish arriving.
    func endCatchUp(after seconds: Double) {
        guard inCatchUp else { return }
        catchUpTask?.cancel()
        catchUpTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finishCatchUp()
        }
    }

    /// Removes pending and delivered alerts for a conversation (it was opened or read).
    func clear(conversationID: String) {
        pending.removeAll { $0.conversationID == conversationID }
        guard AppEnv.canNotify else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: [NotificationPlanner.identifier(for: conversationID)])
    }

    func clearSummary() {
        guard AppEnv.canNotify else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [NotificationPlanner.summaryIdentifier])
    }

    func clearAll() {
        pending = []
        firstPendingAt = nil
        flushTask?.cancel()
        guard AppEnv.canNotify else { return }
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    // MARK: private

    private func scheduleFlush() {
        guard !inCatchUp else { return }                // flushed as a summary when catch-up ends
        flushTask?.cancel()
        let waited = Date().timeIntervalSince(firstPendingAt ?? Date())
        let delay: Double = waited >= 3 ? 0 : 1         // 1 s debounce, but never delay an alert more than ~3 s
        flushTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            self?.flush(catchUp: false)
        }
    }

    private func finishCatchUp() {
        guard inCatchUp else { return }
        inCatchUp = false
        catchUpTask = nil
        flush(catchUp: true)
    }

    private func flush(catchUp: Bool) {
        let alerts = pending
        pending = []
        firstPendingAt = nil
        let plan = NotificationPlanner.plan(alerts, catchUp: catchUp, now: Date(), previews: Prefs.notificationPreviews)
        guard !plan.isEmpty else { return }
        // At most one sound per flush, and not more often than every few seconds.
        var playSound = Prefs.notificationSound && Date().timeIntervalSince(lastSoundAt) > 4
        if playSound { lastSoundAt = Date() }
        for item in plan {
            post(item, sound: playSound)
            playSound = false
        }
    }

    private func post(_ n: PlannedNotification, sound: Bool) {
        let content = UNMutableNotificationContent()
        content.title = n.title
        content.subtitle = n.subtitle
        content.body = n.body
        content.categoryIdentifier = n.category
        if let cid = n.conversationID {
            content.threadIdentifier = cid
            content.userInfo = ["conversationID": cid]
        }
        content.sound = sound ? .default : nil
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: n.identifier, content: content, trigger: nil))
    }
}
