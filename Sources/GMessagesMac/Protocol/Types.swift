import Foundation
import SwiftProtobuf

// Short aliases for the generated protobuf types (names are prefixed with their proto package).
typealias GMConversation = Conversations_Conversation
typealias GMMessage = Conversations_Message
typealias GMParticipant = Conversations_Participant
typealias GMContact = Conversations_Contact
typealias GMMessageInfo = Conversations_MessageInfo
typealias GMMediaContent = Conversations_MediaContent
typealias GMReactionData = Conversations_ReactionData
typealias GMDevice = Authentication_Device
typealias GMAuthMessage = Authentication_AuthMessage
typealias GMConfigVersion = Authentication_ConfigVersion
typealias GMUpdateEvents = Events_UpdateEvents
typealias GMTypingData = Events_TypingData

/// Raw-value based enum helpers so a naming difference in generated code only needs fixing here.
enum RPCAction {
    static let listConversations = Rpc_ActionType(rawValue: 1)!
    static let listMessages = Rpc_ActionType(rawValue: 2)!
    static let sendMessage = Rpc_ActionType(rawValue: 3)!
    static let listContacts = Rpc_ActionType(rawValue: 6)!
    static let getOrCreateConversation = Rpc_ActionType(rawValue: 9)!
    static let messageRead = Rpc_ActionType(rawValue: 10)!
    static let typingUpdates = Rpc_ActionType(rawValue: 12)!
    static let settingsUpdate = Rpc_ActionType(rawValue: 13)!
    static let updateConversation = Rpc_ActionType(rawValue: 15)!
    static let getUpdates = Rpc_ActionType(rawValue: 16)!
    static let notifyDittoActivity = Rpc_ActionType(rawValue: 22)!
    static let deleteMessage = Rpc_ActionType(rawValue: 23)!
    static let listTopContacts = Rpc_ActionType(rawValue: 28)!
    static let getContactsThumbnail = Rpc_ActionType(rawValue: 29)!
    static let isBugleDefault = Rpc_ActionType(rawValue: 31)!
    static let getParticipantsThumbnail = Rpc_ActionType(rawValue: 37)!
    static let sendReaction = Rpc_ActionType(rawValue: 38)!
    static let getConversation = Rpc_ActionType(rawValue: 43)!
    static let createGaiaPairingClientInit = Rpc_ActionType(rawValue: 44)!
    static let createGaiaPairingClientFinished = Rpc_ActionType(rawValue: 45)!
    static let unpairGaiaPairing = Rpc_ActionType(rawValue: 46)!
    static let cancelGaiaPairing = Rpc_ActionType(rawValue: 47)!
}

enum RPCMessageType {
    static let bugleMessage = Rpc_MessageType(rawValue: 2)!
    static let bugleAnnotation = Rpc_MessageType(rawValue: 16)!
    static let gaia2 = Rpc_MessageType(rawValue: 20)!
}

enum BugleRouteValue {
    static let dataEvent = 19, pairEvent = 14, gaiaEvent = 7
}

/// Message status codes (conversations.MessageStatusType) the UI cares about.
enum StatusCode {
    static func isOutgoing(_ s: Int) -> Bool { s < 100 }
    static func isTombstone(_ s: Int) -> Bool { s >= 200 && s < 300 }
    static func isFailed(_ s: Int) -> Bool { [8, 9, 13, 17, 18, 19, 21, 22, 24, 27].contains(s) }
    static func isSending(_ s: Int) -> Bool { [3, 4, 5, 6, 7, 10, 20].contains(s) }
    static func isDelivered(_ s: Int) -> Bool { s == 2 }
    static func isRead(_ s: Int) -> Bool { s == 11 }
}

/// Guards fetches of URLs that originate from message/conversation data (i.e. untrusted).
enum URLSafety {
    /// https only, public host: refuses localhost, .local/.internal/.lan, single-label hosts, IP literals in private,
    /// loopback, link-local or multicast ranges, and IPv6 literals.
    static func isPublicHTTPS(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".internal") || host.hasSuffix(".lan") { return false }
        if host.contains(":") { return false }
        if !host.contains(".") { return false }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            let (a, b) = (parts[0], parts[1])
            if a == 10 || a == 127 || a == 0 || (a == 169 && b == 254) || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || a >= 224 { return false }
        }
        return true
    }

    static let googleOwned = ["google.com", "googleusercontent.com", "ggpht.com", "gstatic.com", "googleapis.com"]
    static func isGoogleOwned(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return googleOwned.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

enum GMConstants {
    static let apiKey = "AIzaSyCA4RsOZUFrm9whhtGosPlJLmVPnfSHKz8"
    static let userAgent = "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36"
    static let secUA = "\"Google Chrome\";v=\"152\", \"Chromium\";v=\"152\", \"Not-A.Brand\";v=\"24\""
    static let xUserAgent = "grpc-web-javascript/0.1"
    static let googleNetwork = "GDitto"
    static let messagesBase = "https://messages.google.com"

    static var configVersion: GMConfigVersion {
        var c = GMConfigVersion()
        c.year = 2026; c.month = 9; c.day = 2; c.v1 = 4; c.v2 = 6
        return c
    }

    static var browserDetails: Authentication_BrowserDetails {
        var b = Authentication_BrowserDetails()
        b.userAgent = userAgent
        b.browserType = Authentication_BrowserType(rawValue: 1)! // OTHER
        b.os = "libgm"
        b.deviceType = Authentication_DeviceType(rawValue: 2)!   // TABLET
        return b
    }

    private static let im = "https://instantmessaging-pa.googleapis.com"
    private static let imG = "https://instantmessaging-pa.clients6.google.com"
    private static let msgG = imG + "/$rpc/google.internal.communications.instantmessaging.v1.Messaging"
    private static let regG = imG + "/$rpc/google.internal.communications.instantmessaging.v1.Registration"
    static let receiveMessagesURL = msgG + "/ReceiveMessages"
    static let sendMessageURL = msgG + "/SendMessage"
    static let ackMessagesURL = msgG + "/AckMessages"
    static let signInGaiaURL = regG + "/SignInGaia"
    static let registerRefreshURL = regG + "/RegisterRefresh"
    static let uploadURL = im + "/upload"
    static let configURL = messagesBase + "/web/config"
}
