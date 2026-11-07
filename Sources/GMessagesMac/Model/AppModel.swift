import Foundation
import SwiftUI
import AppKit
import UserNotifications
import Network

enum Phase: Equatable {
    case launching
    case needsLogin
    case contactingPhone
    case confirmEmoji(String)
    case connecting
    case ready
}

@MainActor
final class AppModel: ObservableObject {
    @Published var phase: Phase = .launching
    @Published var errorMessage: String?
    @Published var banner: String?

    @Published var conversations: [ConversationVM] = []
    @Published var archived: [ConversationVM] = []
    @Published var showArchived = false
    @Published var selectedID: String?
    @Published var messages: [String: [MessageVM]] = [:]
    @Published var typing: [String: Date] = [:]
    @Published var search = ""
    @Published var contacts: [ContactVM] = []
    @Published var images: [String: NSImage] = [:]
    @Published var avatars: [String: NSImage] = [:]
    @Published var groupAvatars: [String: NSImage] = [:]
    @Published var loadingMessages = false
    @Published var replyingTo: MessageVM?
    @Published var viewing: MediaItem?
    var drafts: [String: String] = [:]

    private(set) var client: GMClient?
    private var pairing: PairingSession?
    private var eventTask: Task<Void, Never>?
    private var conversationCursor: Client_Cursor?
    private var messageCursors: [String: Client_Cursor] = [:]
    private var requestedAvatars = Set<String>()
    private var avatarFailures: [String: Int] = [:]
    private var requestedImages = Set<String>()
    private var lastTypingSent = Date.distantPast
    private var observers: [NSObjectProtocol] = []
    private let pathMonitor = NWPathMonitor()
    private var wasOffline = false

    var selected: ConversationVM? { (conversations + archived).first { $0.id == selectedID } }

    var filteredConversations: [ConversationVM] {
        let base = showArchived ? archived : conversations
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let list = q.isEmpty ? base : base.filter { $0.name.lowercased().contains(q) || $0.preview.lowercased().contains(q) }
        return list.sorted { ($0.pinned ? 1 : 0, $0.timestamp) > ($1.pinned ? 1 : 0, $1.timestamp) }
    }

    private func uniq(_ list: [ConversationVM]) -> [ConversationVM] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.id).inserted }
    }

    // MARK: Navigation / resilience

    /// Remove decrypted media left behind if the app quit while a video/audio viewer was open.
    private func purgeTempMedia() {
        let dir = FileManager.default.temporaryDirectory
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.lastPathComponent.hasPrefix("gmm-") { try? FileManager.default.removeItem(at: f) }
    }

    func selectAdjacent(_ delta: Int) {
        let list = filteredConversations
        guard !list.isEmpty else { return }
        let idx = list.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : list.count)
        let next = min(max(idx + delta, 0), list.count - 1)
        select(list[next].id)
    }

    func reload() async {
        messages = [:]; messageCursors = [:]
        await loadInitial()
        if let id = selectedID { await openConversation(id) }
    }

    /// Reconnect after the Mac wakes from sleep or the network comes back; long-poll streams die silently otherwise.
    private func installResilience() {
        guard observers.isEmpty else { return }
        let wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.client?.reconnect() }
        }
        observers.append(wake)
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                if path.status != .satisfied { self.wasOffline = true }
                else if self.wasOffline { self.wasOffline = false; await self.client?.reconnect() }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "net.path"))
    }

    // MARK: Launch / login

    func start() async {
        installResilience()
        purgeTempMedia()
        if AppEnv.canNotify { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in } }
        if let saved = Keychain.load(), saved.isPaired, saved.hasCookies {
            phase = .connecting
            await boot(saved)
        } else {
            phase = .needsLogin
        }
    }

    private func boot(_ auth: AuthData) async {
        let c = GMClient(auth: auth)
        client = c
        listen(to: c)
        do {
            try await c.connect()
            await loadInitial()
        } catch {
            errorMessage = error.localizedDescription
            if case GMError.http(let code, _)? = error as? GMError, [401, 403].contains(code) { signOutLocally() }
            else { phase = .needsLogin }
        }
    }

    /// Called with the Google cookies captured by the sign-in window.
    func signedIn(cookies: [String: String]) async {
        errorMessage = nil
        phase = .contactingPhone
        var a = Keychain.load() ?? AuthData()
        a.cookies = cookies
        let c = GMClient(auth: a)
        client = c
        listen(to: c)
        do {
            try await c.fetchConfig()
            let (emoji, session) = try await c.startGaiaPairing()
            pairing = session
            phase = .confirmEmoji(emoji)
            try await c.finishGaiaPairing(session)
            pairing = nil
            Keychain.save(await c.auth)
            phase = .connecting
            try await c.connect()
            await loadInitial()
        } catch {
            errorMessage = error.localizedDescription
            await c.disconnect()
            phase = .needsLogin
        }
    }

    func cancelPairing() {
        if let c = client, let p = pairing { Task { try? await c.cancelGaiaPairing(p); await c.disconnect() } }
        pairing = nil
        phase = .needsLogin
    }

    func signOut() {
        let c = client
        Task { try? await c?.unpairGaia(); await c?.disconnect() }
        signOutLocally()
    }

    private func signOutLocally() {
        Keychain.clear()
        eventTask?.cancel()
        client = nil
        conversations = []; archived = []; messages = [:]; selectedID = nil
        phase = .needsLogin
    }

    // MARK: Events

    private func listen(to c: GMClient) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await e in c.events {
                await self?.handle(e)
            }
        }
    }

    private func handle(_ e: GMEvent) async {
        switch e {
        case .authChanged:
            if let c = client { Keychain.save(await c.auth) }
        case .connected:
            banner = nil
        case .listenError(let s):
            if phase == .ready { banner = "Connection problem: \(s)" }
        case .fatalAuthError(let s):
            errorMessage = s
            signOutLocally()
        case .loggedOut:
            errorMessage = "You were signed out from the phone."
            signOutLocally()
        case .phoneNotResponding:
            banner = "Your phone isn't responding. Make sure it's online."
        case .phoneResponding:
            banner = nil
        case .conversation(let c):
            upsert(ConversationVM(c))
        case .message(let m, let isOld):
            await receive(m, isOld: isOld)
        case .typing(let t):
            let id = t.conversationID
            if t.type.rawValue == 1 { typing[id] = Date().addingTimeInterval(8) } else { typing[id] = nil }
        case .userAlert, .settings:
            break
        }
    }

    private func upsert(_ c: ConversationVM) {
        var vm = c
        if c.archived {
            conversations.removeAll { $0.id == c.id }
            if let i = archived.firstIndex(where: { $0.id == c.id }) { archived[i] = vm } else { archived.append(vm) }
        } else {
            archived.removeAll { $0.id == c.id }
            if let i = conversations.firstIndex(where: { $0.id == c.id }) {
                if selectedID == c.id && NSApp.isActive { vm.unread = false }
                conversations[i] = vm
            } else { conversations.append(vm) }
        }
        requestAvatars(for: vm)
    }

    private func receive(_ m: GMMessage, isOld: Bool) async {
        let cid = m.conversationID
        let my = (conversations + archived).first { $0.id == cid }?.myParticipantID ?? ""
        let vm = MessageVM(m, myParticipantID: my)
        var list = messages[cid] ?? []
        if let i = list.firstIndex(where: { $0.id == vm.id || (!vm.tmpID.isEmpty && $0.tmpID == vm.tmpID) }) { list[i] = merged(list[i], vm) }
        else if vm.isFromMe, let i = list.firstIndex(where: { $0.isLocal && $0.text == vm.text && $0.media.count == vm.media.count }) { list[i] = merged(list[i], vm) }
        else if messages[cid] != nil || cid == selectedID { list.append(vm) }
        var seenIDs = Set<String>()
        list = list.filter { seenIDs.insert($0.id).inserted }
        list.sort { $0.timestamp < $1.timestamp }
        if messages[cid] != nil || cid == selectedID { messages[cid] = list }

        if let i = conversations.firstIndex(where: { $0.id == cid }) {
            if !vm.text.isEmpty || !vm.media.isEmpty {
                conversations[i].preview = vm.text.isEmpty ? "Attachment" : vm.text
                conversations[i].timestamp = vm.timestamp
            }
        } else if let c = try? await client?.getConversation(cid) { upsert(ConversationVM(c)) }

        guard !isOld, !vm.isFromMe, !vm.isTombstone else { return }
        if cid == selectedID && NSApp.isActive {
            Task { try? await client?.markRead(conversationID: cid, messageID: vm.id) }
        } else {
            if let i = conversations.firstIndex(where: { $0.id == cid }) { conversations[i].unread = true }
            notify(vm, conversation: conversations.first { $0.id == cid })
        }
        updateDockBadge()
    }

    private func merged(_ old: MessageVM, _ new: MessageVM) -> MessageVM {
        var n = new
        if new.isFromMe, new.state != .failed, old.state != .failed, old.state.rank > new.state.rank { n.state = old.state }
        return n
    }

    private func notify(_ m: MessageVM, conversation: ConversationVM?) {
        guard AppEnv.canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = conversation?.name ?? m.senderName
        content.subtitle = conversation?.isGroup == true ? m.senderName : ""
        content.body = m.text.isEmpty ? "Attachment" : m.text
        content.sound = .default
        content.userInfo = ["conversationID": m.conversationID]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: m.id, content: content, trigger: nil))
    }

    private func updateDockBadge() {
        let n = conversations.filter(\.unread).count
        NSApp.dockTile.badgeLabel = n > 0 ? String(n) : nil
    }

    // MARK: Loading

    private func loadInitial() async {
        guard let c = client else { return }
        do {
            let r = try await c.listConversations(folder: .inbox, count: 60)
            conversations = uniq(r.conversations.map(ConversationVM.init))
            conversationCursor = r.hasCursor ? r.cursor : nil
            conversations.forEach(requestAvatars)
            phase = .ready
            updateDockBadge()
            Task {
                if let ar = try? await c.listConversations(folder: .archive, count: 40) {
                    archived = uniq(ar.conversations.map(ConversationVM.init))
                }
                contacts = ((try? await c.listContacts()) ?? []).map(ContactVM.init).sorted { $0.name < $1.name }
            }
        } catch {
            errorMessage = error.localizedDescription
            phase = .ready
        }
    }

    func loadMoreConversations() async {
        guard let c = client, let cur = conversationCursor else { return }
        conversationCursor = nil
        if let r = try? await c.listConversations(folder: .inbox, count: 60, cursor: cur) {
            r.conversations.map(ConversationVM.init).forEach(upsert)
            conversationCursor = r.hasCursor ? r.cursor : nil
        }
    }

    func select(_ id: String?) {
        selectedID = id
        replyingTo = nil
        guard let id else { return }
        Task { await openConversation(id) }
    }

    private func openConversation(_ id: String) async {
        guard let c = client else { return }
        if messages[id] == nil {
            loadingMessages = true
            defer { loadingMessages = false }
            if let r = try? await c.listMessages(conversationID: id, count: 40) {
                let my = selected?.myParticipantID ?? ""
                var seen = Set<String>()
                messages[id] = r.messages.map { MessageVM($0, myParticipantID: my) }.filter { seen.insert($0.id).inserted }.sorted { $0.timestamp < $1.timestamp }
                messageCursors[id] = r.hasCursor ? r.cursor : nil
            }
        }
        markConversationRead(id)
    }

    func loadOlder(_ id: String) async {
        guard let c = client, let cur = messageCursors[id] else { return }
        messageCursors[id] = nil
        guard let r = try? await c.listMessages(conversationID: id, count: 40, cursor: cur) else { return }
        let my = selected?.myParticipantID ?? ""
        var list = messages[id] ?? []
        let known = Set(list.map(\.id))
        list.append(contentsOf: r.messages.map { MessageVM($0, myParticipantID: my) }.filter { !known.contains($0.id) })
        messages[id] = list.sorted { $0.timestamp < $1.timestamp }
        messageCursors[id] = r.hasCursor ? r.cursor : nil
    }

    func hasOlder(_ id: String) -> Bool { messageCursors[id] != nil }

    func markConversationRead(_ id: String) {
        if let i = conversations.firstIndex(where: { $0.id == id }) { conversations[i].unread = false }
        updateDockBadge()
        guard let last = messages[id]?.last(where: { !$0.isFromMe }), let c = client else { return }
        Task { try? await c.markRead(conversationID: id, messageID: last.id) }
    }

    // MARK: Sending

    func send(text: String, media: [(Data, String, String)] = [], to conv: ConversationVM) async {
        guard let c = client else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !media.isEmpty else { return }
        let tmp = GMClient.newTmpID()
        let reply = replyingTo?.id
        replyingTo = nil
        var local = MessageVM(localText: trimmed, tmpID: tmp, conversationID: conv.id, replyToID: reply ?? "")
        messages[conv.id, default: []].append(local)
        if let i = conversations.firstIndex(where: { $0.id == conv.id }) {
            conversations[i].preview = trimmed.isEmpty ? "Attachment" : trimmed
            conversations[i].timestamp = Date()
        }
        do {
            var uploaded: [GMMediaContent] = []
            for (data, name, mime) in media { uploaded.append(try await c.uploadMedia(data: data, fileName: name, mime: mime)) }
            let r = try await c.sendText(trimmed, to: conv.raw, replyTo: reply, media: uploaded, tmpID: tmp)
            if r.status.rawValue != 1 { throw GMError.protocolError("Phone could not send the message (status \(r.status.rawValue)).") }
            if let i = messages[conv.id]?.firstIndex(where: { $0.tmpID == tmp && $0.isLocal }) { messages[conv.id]?[i].state = .sent }
        } catch {
            local.state = .failed
            if let i = messages[conv.id]?.firstIndex(where: { $0.tmpID == tmp }) { messages[conv.id]?[i].state = .failed }
            errorMessage = error.localizedDescription
        }
    }

    func typingChanged(in conv: ConversationVM) {
        guard Date().timeIntervalSince(lastTypingSent) > 5, let c = client else { return }
        lastTypingSent = Date()
        let sim = conv.raw.hasSimCard ? conv.raw.simCard.simdata.simpayload : nil
        Task { try? await c.setTyping(conversationID: conv.id, simPayload: sim) }
    }

    func react(_ m: MessageVM, emoji: String, in conv: ConversationVM) {
        guard let c = client else { return }
        let existing = m.reactions.first { $0.byMe }
        let action: GMClient.ReactionAction
        if let e = existing { action = e.emoji == emoji ? .remove : .switch } else { action = .add }
        Task {
            do { try await c.react(messageID: m.id, emoji: emoji, action: action, conversation: conv.raw) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func delete(_ m: MessageVM) {
        guard let c = client else { return }
        Task {
            do {
                try await c.deleteMessage(m.id)
                messages[m.conversationID]?.removeAll { $0.id == m.id }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func retry(_ m: MessageVM, in conv: ConversationVM) {
        messages[conv.id]?.removeAll { $0.id == m.id }
        Task { await send(text: m.text, to: conv) }
    }

    // MARK: Conversation management

    func setArchived(_ conv: ConversationVM, _ value: Bool) {
        guard let c = client else { return }
        Task {
            do {
                try await c.setArchived(conv.id, archived: value)
                var v = conv; v.archived = value
                upsert(v)
                if selectedID == conv.id { selectedID = nil }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func setMuted(_ conv: ConversationVM, _ value: Bool) {
        guard let c = client else { return }
        Task { do { try await c.setMuted(conv.id, muted: value) } catch { errorMessage = error.localizedDescription } }
    }

    func deleteConversation(_ conv: ConversationVM) {
        guard let c = client else { return }
        Task {
            do {
                try await c.deleteConversation(conv.id)
                conversations.removeAll { $0.id == conv.id }; archived.removeAll { $0.id == conv.id }
                if selectedID == conv.id { selectedID = nil }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func startConversation(numbers: [String], groupName: String? = nil) async {
        guard let c = client else { return }
        do {
            let r = try await c.getOrCreateConversation(phoneNumbers: numbers, groupName: groupName)
            guard r.hasConversation else { throw GMError.protocolError("Couldn't create the conversation.") }
            let vm = ConversationVM(r.conversation)
            upsert(vm)
            select(vm.id)
        } catch { errorMessage = error.localizedDescription }
    }

    // MARK: Images

    func requestAvatars(for c: ConversationVM) {
        guard let client else { return }
        if c.isGroup, !c.groupAvatarURL.isEmpty {
            let key = "g:" + c.id + c.groupAvatarURL
            if !requestedAvatars.contains(key) {
                requestedAvatars.insert(key)
                let url = c.groupAvatarURL
                Task {
                    if let d = try? await client.downloadAvatar(url), let img = NSImage(data: d) {
                        groupAvatars[c.id] = img
                    } else {
                        avatarFailures[key, default: 0] += 1
                        if avatarFailures[key, default: 0] < 3 { requestedAvatars.remove(key) }   // retry on a later update
                    }
                }
            }
            return
        }
        // 1:1 chats use the contact's photo; groups without their own icon use a collage of up to 4 members.
        let ids = c.avatarParticipantIDs.prefix(c.isGroup ? 4 : 1).filter { !requestedAvatars.contains($0) }
        guard !ids.isEmpty else { return }
        ids.forEach { requestedAvatars.insert($0) }
        Task {
            if let thumbs = try? await client.participantThumbnails(Array(ids)) {
                for (id, data) in thumbs { if let img = NSImage(data: data) { avatars[id] = img } }
            }
        }
    }

    /// Member photos for groups that have no icon of their own.
    func collage(for c: ConversationVM) -> [NSImage] {
        guard c.isGroup, groupAvatars[c.id] == nil else { return [] }
        return c.avatarParticipantIDs.prefix(4).compactMap { avatars[$0] }
    }

    func avatar(for c: ConversationVM) -> NSImage? {
        if c.isGroup { return groupAvatars[c.id] }
        return c.avatarParticipantIDs.first.flatMap { avatars[$0] }
    }

    func loadImage(_ item: MediaItem, thumbnail: Bool = true) {
        let id = thumbnail && !item.thumbID.isEmpty ? item.thumbID : item.id
        let key = thumbnail && !item.thumbID.isEmpty ? item.thumbKey : item.key
        guard images[id] == nil, !requestedImages.contains(id), let client else { return }
        requestedImages.insert(id)
        Task {
            if let d = try? await client.downloadMedia(id: id, key: key), let img = NSImage(data: d) { images[id] = img }
            else { requestedImages.remove(id) }
        }
    }

    func image(for item: MediaItem) -> NSImage? { images[!item.thumbID.isEmpty ? item.thumbID : item.id] }

    func saveMedia(_ item: MediaItem) {
        guard let client else { return }
        Task {
            guard let d = try? await client.downloadMedia(id: item.id, key: item.key) else { return }
            let panel = NSSavePanel()
            let safe = (item.name as NSString).lastPathComponent.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            panel.nameFieldStringValue = safe.isEmpty || safe.hasPrefix(".") ? "attachment" : safe
            if panel.runModal() == .OK, let url = panel.url { try? d.write(to: url) }
        }
    }
}
