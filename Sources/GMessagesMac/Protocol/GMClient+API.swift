import Foundation
import SwiftProtobuf

extension GMClient {
    // MARK: Conversations

    enum Folder: Int { case inbox = 1, archive = 2, spam = 5 }

    func listConversations(folder: Folder = .inbox, count: Int64 = 40, cursor: Client_Cursor? = nil) async throws -> Client_ListConversationsResponse {
        var req = Client_ListConversationsRequest()
        req.count = count
        req.folder = Client_ListConversationsRequest.Folder(rawValue: folder.rawValue) ?? .inbox
        if let cursor { req.cursor = cursor }
        let first = !conversationsFetchedOnce
        markConversationsFetched()
        return try await rpc(RPCAction.listConversations, req, as: Client_ListConversationsResponse.self,
                             messageType: first ? RPCMessageType.bugleAnnotation : RPCMessageType.bugleMessage)
    }

    func getConversation(_ id: String) async throws -> GMConversation {
        var req = Client_GetConversationRequest(); req.conversationID = id
        return try await rpc(RPCAction.getConversation, req, as: Client_GetConversationResponse.self).conversation
    }

    func listMessages(conversationID: String, count: Int64 = 40, cursor: Client_Cursor? = nil) async throws -> Client_ListMessagesResponse {
        var req = Client_ListMessagesRequest()
        req.conversationID = conversationID
        req.count = count
        if let cursor { req.cursor = cursor }
        return try await rpc(RPCAction.listMessages, req, as: Client_ListMessagesResponse.self)
    }

    func getOrCreateConversation(phoneNumbers: [String], groupName: String? = nil) async throws -> Client_GetOrCreateConversationResponse {
        var req = Client_GetOrCreateConversationRequest()
        req.numbers = phoneNumbers.map { n in
            var c = Conversations_ContactNumber()
            c.mysteriousInt = 2; c.number = n; c.number2 = n
            return c
        }
        if phoneNumbers.count > 1 { req.createRcsgroup = true; if let g = groupName, !g.isEmpty { req.rcsgroupName = g } }
        return try await rpc(RPCAction.getOrCreateConversation, req, as: Client_GetOrCreateConversationResponse.self)
    }

    /// Archive / unarchive / mute / unmute. (Request shapes follow the proto; these paths are lightly tested upstream.)
    func setArchived(_ conversationID: String, archived: Bool) async throws {
        var req = Client_UpdateConversationRequest()
        req.conversationID = conversationID
        var data = Client_UpdateConversationData()
        data.conversationID = conversationID
        data.status = Conversations_ConversationStatus(rawValue: archived ? 2 : 1)!
        req.updateData = data
        _ = try await rpc(RPCAction.updateConversation, req, as: Client_UpdateConversationResponse.self, userInitiated: true)
    }

    func setMuted(_ conversationID: String, muted: Bool) async throws {
        var req = Client_UpdateConversationRequest()
        req.conversationID = conversationID
        var data = Client_UpdateConversationData()
        data.conversationID = conversationID
        data.mute = Client_ConversationMuteStatus(rawValue: muted ? 1 : 0)!
        req.updateData = data
        _ = try await rpc(RPCAction.updateConversation, req, as: Client_UpdateConversationResponse.self, userInitiated: true)
    }

    func deleteConversation(_ conversationID: String, phone: String? = nil) async throws {
        try await deleteOrBlock(conversationID, action: 1, phone: phone)
    }

    func blockConversation(_ conversationID: String, phone: String? = nil) async throws {
        try await deleteOrBlock(conversationID, action: 7, phone: phone)
    }

    private func deleteOrBlock(_ id: String, action: Int, phone: String?) async throws {
        var req = Client_UpdateConversationRequest()
        req.action = Client_ConversationActionStatus(rawValue: action)!
        req.conversationID = id
        var del = Client_DeleteConversationData()
        del.conversationID = id
        if let phone, !phone.isEmpty { del.phone = phone }
        req.deleteData = del
        let r = try await rpc(RPCAction.updateConversation, req, as: Client_UpdateConversationResponse.self, userInitiated: true)
        if !r.success { throw GMError.protocolError("Phone rejected the request") }
    }

    // MARK: Messages

    static func newTmpID() -> String { "tmp_" + String((0..<12).map { _ in "0123456789".randomElement()! }) }

    func sendText(_ text: String, to conversation: GMConversation, replyTo: String? = nil, forceRCS: Bool = false,
                  media: [GMMediaContent] = [], tmpID: String = GMClient.newTmpID()) async throws -> Client_SendMessageResponse {
        var req = Client_SendMessageRequest()
        req.conversationID = conversation.conversationID
        req.tmpID = tmpID
        req.messagePayload.tmpID = tmpID
        req.messagePayload.tmpID2 = tmpID
        req.messagePayload.conversationID = conversation.conversationID
        req.messagePayload.participantID = conversation.defaultOutgoingID
        if conversation.hasSimCard { req.simpayload = conversation.simCard.simdata.simpayload }
        req.forceRcs = forceRCS
        var infos: [GMMessageInfo] = []
        for m in media { var i = GMMessageInfo(); i.mediaContent = m; infos.append(i) }
        if !text.isEmpty { var i = GMMessageInfo(); i.messageContent.content = text; infos.append(i) }
        req.messagePayload.messageInfo = infos
        if let replyTo { req.reply.messageID = replyTo }
        return try await rpc(RPCAction.sendMessage, req, as: Client_SendMessageResponse.self, userInitiated: true)
    }

    func react(messageID: String, emoji: String, action: ReactionAction, conversation: GMConversation?) async throws {
        var req = Client_SendReactionRequest()
        req.messageID = messageID
        req.reactionData.unicode = emoji
        req.reactionData.type = Conversations_EmojiType(rawValue: Self.emojiType(emoji)) ?? .custom
        req.action = Client_SendReactionRequest.Action(rawValue: action.rawValue) ?? .add
        if let c = conversation, c.hasSimCard { req.simpayload = c.simCard.simdata.simpayload }
        let r = try await rpc(RPCAction.sendReaction, req, as: Client_SendReactionResponse.self, userInitiated: true)
        if !r.success { throw GMError.protocolError("Reaction was rejected") }
    }

    enum ReactionAction: Int { case add = 1, remove = 2, `switch` = 3 }

    static func emojiType(_ e: String) -> Int {
        switch e {
        case "👍": return 1
        case "😍": return 2
        case "😂": return 3
        case "😮": return 4
        case "😥": return 5
        case "😠": return 6
        case "👎": return 7
        case "🤔": return 9
        case "😢": return 10
        case "😡": return 11
        case "❤", "❤️": return 12
        default: return 8
        }
    }

    func deleteMessage(_ id: String) async throws {
        var req = Client_DeleteMessageRequest(); req.messageID = id
        _ = try await rpc(RPCAction.deleteMessage, req, as: Client_DeleteMessageResponse.self, userInitiated: true)
    }

    func markRead(conversationID: String, messageID: String) async throws {
        var req = Client_MessageReadRequest()
        req.conversationID = conversationID; req.messageID = messageID
        _ = try await send(SendParams(action: RPCAction.messageRead, data: req))
    }

    func setTyping(conversationID: String, simPayload: Settings_SIMPayload?) async throws {
        var req = Client_TypingUpdateRequest()
        req.data.conversationID = conversationID
        req.data.typing = true
        if let s = simPayload { req.simpayload = s }
        try await sendNoResponse(SendParams(action: RPCAction.typingUpdates, data: req))
    }

    // MARK: Contacts + thumbnails

    func listContacts() async throws -> [GMContact] {
        var req = Client_ListContactsRequest()
        req.i1 = 1; req.i2 = 350; req.i3 = 50
        return try await rpc(RPCAction.listContacts, req, as: Client_ListContactsResponse.self).contacts
    }

    func listTopContacts() async throws -> [GMContact] {
        var req = Client_ListTopContactsRequest(); req.count = 8
        return try await rpc(RPCAction.listTopContacts, req, as: Client_ListTopContactsResponse.self).contacts
    }

    /// Returns image bytes keyed by the requested identifier.
    func participantThumbnails(_ ids: [String]) async throws -> [String: Data] {
        var req = Client_GetThumbnailRequest(); req.identifiers = ids
        let r = try await rpc(RPCAction.getParticipantsThumbnail, req, as: Client_GetThumbnailResponse.self)
        return Dictionary(r.thumbnail.compactMap { t in t.data.imageBuffer.isEmpty ? nil : (t.identifier, t.data.imageBuffer) },
                          uniquingKeysWith: { a, _ in a })
    }

    func contactThumbnails(_ ids: [String]) async throws -> [String: Data] {
        var req = Client_GetThumbnailRequest(); req.identifiers = ids
        let r = try await rpc(RPCAction.getContactsThumbnail, req, as: Client_GetThumbnailResponse.self)
        return Dictionary(r.thumbnail.compactMap { t in t.data.imageBuffer.isEmpty ? nil : (t.identifier, t.data.imageBuffer) },
                          uniquingKeysWith: { a, _ in a })
    }

    // MARK: Media

    private func uploadHeaders(_ r: inout URLRequest, size: Int, command: String, offset: String?, mime: String?, proto: String?) {
        r.setValue(GMConstants.secUA, forHTTPHeaderField: "sec-ch-ua")
        if let proto { r.setValue(proto, forHTTPHeaderField: "x-goog-upload-protocol") }
        r.setValue(String(size), forHTTPHeaderField: "x-goog-upload-header-content-length")
        r.setValue("?1", forHTTPHeaderField: "sec-ch-ua-mobile")
        r.setValue(GMConstants.userAgent, forHTTPHeaderField: "user-agent")
        if let mime, !mime.isEmpty { r.setValue(mime, forHTTPHeaderField: "x-goog-upload-header-content-type") }
        r.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "content-type")
        r.setValue(command, forHTTPHeaderField: "x-goog-upload-command")
        if let offset { r.setValue(offset, forHTTPHeaderField: "x-goog-upload-offset") }
        r.setValue("\"Android\"", forHTTPHeaderField: "sec-ch-ua-platform")
        r.setValue("*/*", forHTTPHeaderField: "accept")
        r.setValue(GMConstants.messagesBase, forHTTPHeaderField: "origin")
        r.setValue("cross-site", forHTTPHeaderField: "sec-fetch-site")
        r.setValue("cors", forHTTPHeaderField: "sec-fetch-mode")
        r.setValue("empty", forHTTPHeaderField: "sec-fetch-dest")
        r.setValue(GMConstants.messagesBase + "/", forHTTPHeaderField: "referer")
        r.setValue("en-US,en;q=0.9", forHTTPHeaderField: "accept-language")
    }

    func downloadMedia(id: String, key: Data) async throws -> Data {
        var info = Client_AttachmentInfo(); info.attachmentID = id; info.encrypted = true
        var dl = Client_DownloadAttachmentRequest()
        dl.info = info
        dl.authData = makeAuth()
        let meta = try dl.serializedData().base64EncodedString()
        var req = URLRequest(url: URL(string: GMConstants.uploadURL)!)
        req.setValue(meta, forHTTPHeaderField: "x-goog-download-metadata")
        req.setValue(GMConstants.secUA, forHTTPHeaderField: "sec-ch-ua")
        req.setValue("?1", forHTTPHeaderField: "sec-ch-ua-mobile")
        req.setValue(GMConstants.userAgent, forHTTPHeaderField: "user-agent")
        req.setValue("\"Android\"", forHTTPHeaderField: "sec-ch-ua-platform")
        req.setValue("*/*", forHTTPHeaderField: "accept")
        req.setValue(GMConstants.messagesBase, forHTTPHeaderField: "origin")
        req.setValue(GMConstants.messagesBase + "/", forHTTPHeaderField: "referer")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GMError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, "media download")
        }
        guard key.count == 32 else { return data }
        return try AESGCMMedia(keyData: key).decrypt(data)
    }

    func uploadMedia(data: Data, fileName: String, mime: String) async throws -> GMMediaContent {
        let key = randomBytes(32)
        let encrypted = try AESGCMMedia(keyData: key).encrypt(data)

        var start = Client_StartMediaUploadRequest()
        start.attachmentType = 1
        start.authData = makeAuth()
        if let m = auth.mobile { start.mobile = m }
        let payload = try start.serializedData().base64EncodedString()

        var r1 = URLRequest(url: URL(string: GMConstants.uploadURL)!)
        r1.httpMethod = "POST"
        r1.httpBody = Data(payload.utf8)
        uploadHeaders(&r1, size: encrypted.count, command: "start", offset: nil, mime: mime, proto: "resumable")
        let (_, resp1) = try await URLSession.shared.data(for: r1)
        guard let h1 = resp1 as? HTTPURLResponse, h1.statusCode == 200,
              let uploadURL = h1.value(forHTTPHeaderField: "x-goog-upload-url"), let u = URL(string: uploadURL) else {
            throw GMError.http((resp1 as? HTTPURLResponse)?.statusCode ?? 0, "starting media upload")
        }

        var r2 = URLRequest(url: u)
        r2.httpMethod = "POST"
        r2.httpBody = encrypted
        uploadHeaders(&r2, size: encrypted.count, command: "upload, finalize", offset: "0", mime: mime, proto: nil)
        let (body, resp2) = try await URLSession.shared.data(for: r2)
        guard let h2 = resp2 as? HTTPURLResponse, h2.statusCode == 200 else {
            throw GMError.http((resp2 as? HTTPURLResponse)?.statusCode ?? 0, "finalizing media upload")
        }
        var bytes = body
        if let s = String(data: body, encoding: .utf8), let d = Data(base64Encoded: s.trimmingCharacters(in: .whitespacesAndNewlines)) { bytes = d }
        let parsed = try Client_UploadMediaResponse(serializedData: bytes)

        var m = GMMediaContent()
        m.format = Conversations_MediaFormats(rawValue: Self.mediaFormat(mime)) ?? .unspecifiedType
        m.mediaID = parsed.media.mediaID
        m.mediaName = fileName
        m.size = Int64(data.count)
        m.decryptionKey = key
        m.mimeType = mime
        return m
    }

    static func mediaFormat(_ mime: String) -> Int {
        switch mime {
        case "image/jpeg": return 1
        case "image/jpg": return 2
        case "image/png": return 3
        case "image/gif": return 4
        case "video/mp4": return 8
        case "audio/mpeg", "audio/mp3": return 16
        case "audio/aac": return 14
        case "application/pdf": return 25
        case "text/vcard": return 24
        default:
            if mime.hasPrefix("image/") { return 7 }
            if mime.hasPrefix("video/") { return 13 }
            if mime.hasPrefix("audio/") { return 23 }
            return 37
        }
    }
}
