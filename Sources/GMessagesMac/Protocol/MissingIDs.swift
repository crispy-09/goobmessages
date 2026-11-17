import SwiftProtobuf

/// Port of libgm `fillMissingIDs` (event_handler.go, mautrix/gmessages b580a1a1).
/// The phone can send conversations/messages with the top-level ID fields empty and the IDs only in nested
/// messages (`someKindOfGroupID`, `anotherMessageID`, `latestMessageAnotherID`). Copy them up so the rest of the
/// app can keep using `conversationID` / `messageID`.
enum MissingIDs {
    static func fill(_ conv: inout GMConversation) {
        if conv.conversationID.isEmpty { conv.conversationID = conv.someKindOfGroupID.conversationID }
        if conv.latestMessageID.isEmpty { conv.latestMessageID = conv.latestMessageAnotherID.messageID }
    }

    static func fill(_ msg: inout GMMessage) {
        if msg.messageID.isEmpty { msg.messageID = msg.anotherMessageID.messageID }
        if msg.conversationID.isEmpty { msg.conversationID = msg.someKindOfGroupID.conversationID }
    }

    /// Applies to the response/event types libgm patches; any other message is returned unchanged.
    static func fill<M: SwiftProtobuf.Message>(_ message: M) -> M {
        switch message {
        case var m as GMUpdateEvents:
            switch m.event {
            case .conversationEvent(var ce)?:
                for i in ce.data.indices { fill(&ce.data[i]) }
                m.event = .conversationEvent(ce)
            case .messageEvent(var me)?:
                for i in me.data.indices { fill(&me.data[i]) }
                m.event = .messageEvent(me)
            default: break
            }
            return (m as? M) ?? message
        case var m as Client_ListConversationsResponse:
            for i in m.conversations.indices { fill(&m.conversations[i]) }
            return (m as? M) ?? message
        case var m as Client_GetConversationResponse:
            if m.hasConversation { fill(&m.conversation) }
            return (m as? M) ?? message
        case var m as Client_GetOrCreateConversationResponse:
            if m.hasConversation { fill(&m.conversation) }
            return (m as? M) ?? message
        case var m as Client_ListMessagesResponse:
            for i in m.messages.indices { fill(&m.messages[i]) }
            return (m as? M) ?? message
        default:
            return message
        }
    }
}
