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
    static let blockedSuffixes = [".localhost", ".local", ".internal", ".lan", ".home.arpa", ".intranet", ".corp"]

    /// https only, public host: refuses localhost/.local/.internal/…, single-label hosts, non-ASCII or odd characters,
    /// IPv6 literals, and IPv4 literals unless canonical dotted-quad in a public range. Resolvers also accept forms
    /// like `0x7f.0.0.1`, `127.1` or `017.0.0.1`, so any host whose last label is numeric/hex is treated as an IP.
    /// This checks the name only; `LinkPreviewFetcher.resolvesToPublicAddresses` checks what it resolves to.
    static func isPublicHTTPS(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", var host = url.host?.lowercased() else { return false }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty,
              host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") })
        else { return false }   // also rejects IPv6 literals (':') and percent-encoding
        if host == "localhost" || blockedSuffixes.contains(where: { host.hasSuffix($0) }) { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, !labels.contains(where: \.isEmpty) else { return false }
        let last = labels[labels.count - 1]
        if last.allSatisfy(\.isNumber) || last.hasPrefix("0x") {
            guard labels.count == 4 else { return false }
            var bytes: [UInt8] = []
            for l in labels {
                guard l.allSatisfy(\.isNumber), l == "0" || !l.hasPrefix("0"), let v = UInt8(l) else { return false }
                bytes.append(v)
            }
            return isPublicIPv4(bytes)
        }
        return true
    }

    /// `bytes` in network order. Rejects this-network, private, CGNAT, loopback, link-local, IETF, benchmarking,
    /// multicast and reserved ranges.
    static func isPublicIPv4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        let (a, c) = (b[0], b[1])
        switch a {
        case 0, 10, 127: return false
        case 100 where (64...127).contains(c): return false
        case 169 where c == 254: return false
        case 172 where (16...31).contains(c): return false
        case 192 where c == 168: return false
        case 192 where c == 0 && b[2] == 0: return false
        case 198 where c == 18 || c == 19: return false
        case 224...: return false
        default: return true
        }
    }

    /// `bytes` in network order. Embedded IPv4 (mapped, NAT64, 6to4) is checked as IPv4.
    static func isPublicIPv6(_ b: [UInt8]) -> Bool {
        guard b.count == 16 else { return false }
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff { return isPublicIPv4(Array(b[12...])) }
        if b[0..<12].allSatisfy({ $0 == 0 }) { return false }                     // ::, ::1, IPv4-compatible
        if b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xff && b[3] == 0x9b { return isPublicIPv4(Array(b[12...])) }
        if b[0] == 0x20 && b[1] == 0x02 { return isPublicIPv4(Array(b[2..<6])) } // 6to4
        if b[0] == 0xff { return false }                                          // multicast
        if b[0] & 0xfe == 0xfc { return false }                                   // unique local
        if b[0] == 0xfe && b[1] & 0x80 == 0x80 { return false }                   // link-local / site-local
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
