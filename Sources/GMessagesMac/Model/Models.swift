import Foundation
import SwiftUI

struct MediaItem: Identifiable, Hashable {
    var id: String            // mediaID
    var key: Data
    var mime: String
    var name: String
    var thumbID: String
    var thumbKey: Data
    var isImage: Bool { mime.hasPrefix("image/") }
    var isVideo: Bool { mime.hasPrefix("video/") }
    var isAudio: Bool { mime.hasPrefix("audio/") }
}

struct ReactionSummary: Identifiable, Hashable {
    var emoji: String
    var count: Int
    var byMe: Bool
    var id: String { emoji }
}

enum DeliveryState {
    case none, sending, sent, delivered, read, failed
    /// Status only moves forward; used so a late echo can't regress "Delivered" back to "Sending".
    var rank: Int {
        switch self { case .none: return 0; case .sending: return 1; case .sent: return 2; case .delivered: return 3; case .read: return 4; case .failed: return 0 }
    }
}

struct MessageVM: Identifiable, Hashable {
    var id: String            // messageID (or tmpID until confirmed)
    var tmpID: String
    var conversationID: String
    var text: String
    var subject: String
    var isFromMe: Bool
    var senderName: String
    var participantID: String
    var timestamp: Date
    var state: DeliveryState
    var media: [MediaItem]
    var reactions: [ReactionSummary]
    var replyToID: String
    var isTombstone: Bool
    var isLocal = false      // optimistic copy not yet confirmed by the phone

    init(_ m: GMMessage, myParticipantID: String) {
        id = m.messageID.isEmpty ? m.tmpID : m.messageID
        tmpID = m.tmpID
        conversationID = m.conversationID
        participantID = m.participantID
        let status = m.messageStatus.status.rawValue
        isFromMe = (status >= 1 && status < 100) || m.senderParticipant.isMe || (!myParticipantID.isEmpty && m.participantID == myParticipantID)
        isTombstone = StatusCode.isTombstone(status)
        senderName = m.senderParticipant.fullName.isEmpty ? m.senderParticipant.firstName : m.senderParticipant.fullName
        timestamp = Date(timeIntervalSince1970: Double(m.timestamp) / 1_000_000)
        subject = m.hasSubject ? m.subject : ""
        var texts: [String] = []
        var items: [MediaItem] = []
        for info in m.messageInfo {
            switch info.data {
            case .messageContent(let c)?: if !c.content.isEmpty { texts.append(c.content) }
            case .mediaContent(let mc)?:
                items.append(MediaItem(id: mc.mediaID, key: mc.decryptionKey, mime: mc.mimeType, name: mc.mediaName,
                                       thumbID: mc.thumbnailMediaID, thumbKey: mc.thumbnailDecryptionKey))
            case .locationContent(let l)?: texts.append("📍 " + (l.messageContent.content.isEmpty ? "Location" : l.messageContent.content))
            default: break
            }
        }
        text = texts.joined(separator: "\n")
        media = items
        if isFromMe {
            if StatusCode.isFailed(status) { state = .failed }
            else if StatusCode.isRead(status) { state = .read }
            else if StatusCode.isDelivered(status) { state = .delivered }
            else if StatusCode.isSending(status) { state = .sending }
            else { state = .sent }
        } else { state = .none }
        reactions = m.reactions.compactMap { r in
            let e = r.data.unicode
            guard !e.isEmpty, !r.participantIds.isEmpty else { return nil }
            return ReactionSummary(emoji: e, count: r.participantIds.count, byMe: !myParticipantID.isEmpty && r.participantIds.contains(myParticipantID))
        }
        replyToID = m.hasReplyMessage ? m.replyMessage.messageID : ""
    }

    init(localText: String, tmpID: String, conversationID: String, media: [MediaItem] = [], replyToID: String = "") {
        id = tmpID; self.tmpID = tmpID; self.conversationID = conversationID
        text = localText; subject = ""; isFromMe = true; senderName = ""; participantID = ""
        timestamp = Date(); state = .sending; self.media = media; reactions = []
        self.replyToID = replyToID; isTombstone = false; isLocal = true
    }
}

struct ConversationVM: Identifiable, Hashable {
    var id: String
    var name: String
    var preview: String
    var timestamp: Date
    var unread: Bool
    var isGroup: Bool
    var pinned: Bool
    var colorHex: String
    var avatarParticipantIDs: [String]
    var myParticipantID: String
    var archived: Bool
    var groupAvatarURL: String
    var raw: GMConversation

    init(_ c: GMConversation) {
        raw = c
        groupAvatarURL = c.groupAvatarURL
        id = c.conversationID
        name = c.name
        preview = c.latestMessage.displayContent
        timestamp = Date(timeIntervalSince1970: Double(c.lastMessageTimestamp) / 1_000_000)
        unread = c.unread
        isGroup = c.isGroupChat
        pinned = c.pinned
        colorHex = c.avatarHexColor
        myParticipantID = c.defaultOutgoingID
        archived = c.status.rawValue == 2 || c.status.rawValue == 4
        let others = Set(c.otherParticipants)
        avatarParticipantIDs = c.participants.filter { !$0.isMe && (others.isEmpty || others.contains($0.id.participantID)) }.map { $0.id.participantID }
    }

    var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let s = parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
        return s.isEmpty ? "#" : s
    }
}

struct ContactVM: Identifiable, Hashable {
    var id: String
    var name: String
    var number: String
    var colorHex: String
    init(_ c: GMContact) {
        id = c.contactID.isEmpty ? c.participantID : c.contactID
        name = c.name.isEmpty ? c.nameAgain : c.name
        number = c.number.formattedNumber.isEmpty ? c.number.number : c.number.formattedNumber
        colorHex = c.avatarHexColor
    }
}

extension Color {
    init(hex: String, fallback: Color = .gray) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { self = fallback; return }
        if s.count == 8 { s = String(s.suffix(6)) }
        let n = UInt64(s, radix: 16) ?? v
        self = Color(red: Double((n >> 16) & 0xff) / 255, green: Double((n >> 8) & 0xff) / 255, blue: Double(n & 0xff) / 255)
    }
}
