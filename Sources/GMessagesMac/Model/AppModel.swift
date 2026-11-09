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

/// App-wide state and actions. Views read `@Published` state and call methods here; they never talk to `GMClient`.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var phase: Phase = .launching
    @Published var errorMessage: String?
    @Published var banner: String?
    @Published private(set) var isOffline = false

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
    /// Image previews of attachments still being sent, keyed by the local message's tmpID.
    @Published private(set) var localPreviews: [String: [NSImage]] = [:]
    @Published private(set) var hiddenAlerts: Set<String> = Prefs.hiddenAlerts
    var drafts: [String: String] = [:]

    let notifications = NotificationCoordinator()
    private(set) var client: GMClient?
    private var pairing: PairingSession?
    private var eventTask: Task<Void, Never>?
    private var conversationCursor: Client_Cursor?
    private var messageCursors: [String: Client_Cursor] = [:]

    // Request hygiene (avoid duplicate RPCs that could get us rate limited)
    private var requestedAvatars = Set<String>()
    private var avatarFailures: [String: Int] = [:]
    private var pendingThumbIDs = Set<String>()
    private var thumbFlushTask: Task<Void, Never>?
    private var requestedImages = Set<String>()
    private var fetchingConversations = Set<String>()
    private var markReadTasks: [String: Task<Void, Never>] = [:]
    private var lastMarkedRead: [String: String] = [:]
    private var lastIncomingID: [String: String] = [:]
    private var lastTypingSent = Date.distantPast
    private var loadingInitial = false
    private var lastConversationRefresh = Date.distantPast
    private var mediaCache: [String: Data] = [:]
    private var mediaCacheOrder: [String] = []

    // Notification bookkeeping: each incoming message alerts at most once.
    private var notifiedIDs = Set<String>()
    private var notifiedOrder: [String] = []

    // Outgoing attachments kept until the send succeeds, so "Try Again" can resend them.
    private var outgoing: [String: [OutgoingAttachment]] = [:]

    // Connection supervision
    private var observers: [NSObjectProtocol] = []
    private let pathMonitor = NWPathMonitor()
    private var reconnectTask: Task<Void, Never>?
    private var isAsleep = false

    var selected: ConversationVM? { conversation(selectedID) }
    var unreadConversations: [ConversationVM] { conversations.filter(\.unread).sorted { $0.timestamp > $1.timestamp } }

    var filteredConversations: [ConversationVM] {
        let base = showArchived ? archived : conversations
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let list = q.isEmpty ? base : base.filter { $0.name.lowercased().contains(q) || $0.preview.lowercased().contains(q) }
        return list.sorted { ($0.pinned ? 1 : 0, $0.timestamp) > ($1.pinned ? 1 : 0, $1.timestamp) }
    }

    func conversation(_ id: String?) -> ConversationVM? {
        guard let id else { return nil }
        return conversations.first { $0.id == id } ?? archived.first { $0.id == id }
    }

    private func uniq(_ list: [ConversationVM]) -> [ConversationVM] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.id).inserted }
    }

    /// True when the user is actually looking at this conversation (window visible and app frontmost).
    private func isViewing(_ cid: String) -> Bool {
        guard selectedID == cid, NSApp.isActive, let w = MainWindow.window else { return false }
        return w.isVisible && !w.isMiniaturized
    }

    // MARK: - Launch / login

    func start() async {
        installResilience()
        purgeTempMedia()
        if AppEnv.canNotify {
            NotificationCoordinator.registerCategories()
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
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
        notifications.beginCatchUp()        // whatever was queued while the app was closed arrives as one summary
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
            notifications.beginCatchUp()
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
        reconnectTask?.cancel()
        client = nil
        conversations = []; archived = []; messages = [:]; selectedID = nil
        images = [:]; avatars = [:]; groupAvatars = [:]; mediaCache = [:]; mediaCacheOrder = []
        notifications.clearAll()
        updateDockBadge()
        phase = .needsLogin
    }

    // MARK: - Connection supervision (sleep / wake / network)

    /// Remove decrypted media left behind if the app quit while a video/audio viewer was open.
    private func purgeTempMedia() {
        let dir = FileManager.default.temporaryDirectory
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.lastPathComponent.hasPrefix("gmm-") { try? FileManager.default.removeItem(at: f) }
    }

    private func installResilience() {
        guard observers.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleSleep() }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleWake() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.appBecameActive() }
        })
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(online: online) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "goob.net.path"))
    }

    /// Going to sleep: close the stream cleanly and start holding alerts. Messages that arrive while the Mac sleeps
    /// are delivered in one burst on wake and become a summary instead of a notification each.
    private func handleSleep() {
        isAsleep = true
        reconnectTask?.cancel()
        notifications.beginCatchUp()
        if let c = client { Task { await c.disconnect() } }
    }

    private func handleWake() {
        isAsleep = false
        scheduleReconnect(after: 2)
    }

    private func networkChanged(online: Bool) {
        if !online {
            isOffline = true
            return
        }
        guard isOffline else { return }
        isOffline = false
        if !isAsleep { scheduleReconnect(after: 1) }
    }

    /// Debounced, single-flight reconnect. Wake, network and error signals often fire together; they collapse here
    /// into one reconnect instead of several back-to-back sessions (which also risks rate limiting).
    func scheduleReconnect(after seconds: Double) {
        guard client != nil, phase == .ready || phase == .connecting else { return }
        reconnectTask?.cancel()
        notifications.beginCatchUp()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.isAsleep, let c = self.client else { return }
            await c.reconnect()
        }
    }

    private func appBecameActive() {
        notifications.clearSummary()
        if let id = selectedID, isViewing(id), conversation(id)?.unread == true { markConversationRead(id) }
    }

    // MARK: - Events

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
            notifications.endCatchUp(after: 4)
            if phase == .ready {
                if conversations.isEmpty { Task { await loadInitial() } } else { Task { await refreshConversations() } }
            }
        case .listenError(let s):
            if phase == .ready && !isAsleep && !isOffline { banner = "Connection problem: \(s)" }
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
            receive(m, isOld: isOld)
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
                if isViewing(c.id) { vm.unread = false }
                conversations[i] = vm
            } else { conversations.append(vm) }
        }
        requestAvatars(for: vm)
        updateDockBadge()
    }

    private func receive(_ m: GMMessage, isOld: Bool) {
        let cid = m.conversationID
        let conv = conversation(cid)
        let vm = MessageVM(m, myParticipantID: conv?.myParticipantID ?? "")
        let tracked = messages[cid] != nil || cid == selectedID
        var list = messages[cid] ?? []
        var isUpdate = false
        if let i = list.firstIndex(where: { $0.id == vm.id }) {
            list[i] = merged(list[i], vm)
            isUpdate = true
        } else if let i = list.firstIndex(where: { vm.confirms($0) }) {
            localPreviews[list[i].tmpID] = nil
            outgoing[list[i].tmpID] = nil
            list[i] = merged(list[i], vm)
            isUpdate = true
        } else if tracked {
            list.append(vm)
        }
        if tracked {
            var seen = Set<String>()
            messages[cid] = list.filter { seen.insert($0.id).inserted }.sorted { $0.timestamp < $1.timestamp }
        }

        // An update to an older message (a reaction, a status change) must not move the conversation or alert.
        let isLatest = conv.map { vm.timestamp >= $0.timestamp.addingTimeInterval(-1) } ?? true
        if let i = conversations.firstIndex(where: { $0.id == cid }) {
            if isLatest, !vm.isTombstone, !(vm.text.isEmpty && vm.media.isEmpty) {
                conversations[i].preview = vm.summaryText
                conversations[i].timestamp = max(conversations[i].timestamp, vm.timestamp)
            }
        } else if conv == nil {
            fetchConversation(cid)
        }

        guard !vm.isFromMe, !vm.isTombstone else { return }
        if isLatest { lastIncomingID[cid] = vm.id }
        guard !isOld, !isUpdate, isLatest, rememberNotified(vm.id),
              Date().timeIntervalSince(vm.timestamp) < 24 * 3600 else { return }

        if isViewing(cid) {
            scheduleMarkRead(cid, messageID: vm.id)
            return
        }
        if let i = conversations.firstIndex(where: { $0.id == cid }) { conversations[i].unread = true }
        updateDockBadge()
        let c = conversation(cid)
        notifications.enqueue(NotificationAlert(
            conversationID: cid,
            conversationName: c?.name ?? "",
            senderName: vm.senderName,
            text: vm.summaryText,
            isGroup: c?.isGroup ?? false,
            timestamp: vm.timestamp))
    }

    /// Returns false if this message already produced (or was considered for) an alert.
    private func rememberNotified(_ id: String) -> Bool {
        guard notifiedIDs.insert(id).inserted else { return false }
        notifiedOrder.append(id)
        if notifiedOrder.count > 1000 { notifiedIDs.remove(notifiedOrder.removeFirst()) }
        return true
    }

    private func fetchConversation(_ cid: String) {
        guard let c = client, fetchingConversations.insert(cid).inserted else { return }
        Task {
            defer { fetchingConversations.remove(cid) }
            if let conv = try? await c.getConversation(cid), !conv.conversationID.isEmpty { upsert(ConversationVM(conv)) }
        }
    }

    private func merged(_ old: MessageVM, _ new: MessageVM) -> MessageVM {
        var n = new
        if new.isFromMe, new.state != .failed, old.state != .failed, old.state.rank > new.state.rank { n.state = old.state }
        return n
    }

    private func updateDockBadge() {
        let n = conversations.filter(\.unread).count
        NSApp.dockTile.badgeLabel = n > 0 ? String(n) : nil
    }

    // MARK: - Loading

    private func loadInitial() async {
        guard let c = client, !loadingInitial else { return }
        loadingInitial = true
        defer { loadingInitial = false }
        do {
            let r = try await c.listConversations(folder: .inbox, count: 60)
            conversations = uniq(r.conversations.map(ConversationVM.init))
            conversationCursor = r.hasCursor ? r.cursor : nil
            lastConversationRefresh = Date()
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

    /// Re-sync the conversation list after a reconnect: read state and previews may have changed on the phone
    /// while we were away (those updates arrive as "old" and are otherwise skipped). Throttled to once per 30 s.
    private func refreshConversations() async {
        guard let c = client, Date().timeIntervalSince(lastConversationRefresh) > 30 else { return }
        lastConversationRefresh = Date()
        guard let r = try? await c.listConversations(folder: .inbox, count: 60) else { return }
        for vm in uniq(r.conversations.map(ConversationVM.init)) { upsert(vm) }
    }

    func reload() async {
        messages = [:]; messageCursors = [:]
        lastConversationRefresh = .distantPast
        await loadInitial()
        if let id = selectedID { await openConversation(id) }
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

    func selectAdjacent(_ delta: Int) {
        let list = filteredConversations
        guard !list.isEmpty else { return }
        let idx = list.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : list.count)
        let next = min(max(idx + delta, 0), list.count - 1)
        select(list[next].id)
    }

    private func openConversation(_ id: String) async {
        guard let c = client else { return }
        if messages[id] == nil {
            loadingMessages = true
            defer { loadingMessages = false }
            if let r = try? await c.listMessages(conversationID: id, count: 40) {
                let my = conversation(id)?.myParticipantID ?? ""
                var seen = Set<String>()
                messages[id] = r.messages.map { MessageVM($0, myParticipantID: my) }
                    .filter { seen.insert($0.id).inserted }.sorted { $0.timestamp < $1.timestamp }
                messageCursors[id] = r.hasCursor ? r.cursor : nil
            }
        }
        markConversationRead(id)
    }

    func loadOlder(_ id: String) async {
        guard let c = client, let cur = messageCursors[id] else { return }
        messageCursors[id] = nil
        guard let r = try? await c.listMessages(conversationID: id, count: 40, cursor: cur) else { return }
        let my = conversation(id)?.myParticipantID ?? ""
        var list = messages[id] ?? []
        let known = Set(list.map(\.id))
        list.append(contentsOf: r.messages.map { MessageVM($0, myParticipantID: my) }.filter { !known.contains($0.id) })
        messages[id] = list.sorted { $0.timestamp < $1.timestamp }
        messageCursors[id] = r.hasCursor ? r.cursor : nil
    }

    func hasOlder(_ id: String) -> Bool { messageCursors[id] != nil }

    // MARK: - Read state

    func markConversationRead(_ id: String) {
        if let i = conversations.firstIndex(where: { $0.id == id }) { conversations[i].unread = false }
        if let i = archived.firstIndex(where: { $0.id == id }) { archived[i].unread = false }
        updateDockBadge()
        notifications.clear(conversationID: id)
        let latest = messages[id]?.last(where: { !$0.isFromMe && !$0.isLocal })?.id
            ?? lastIncomingID[id]
            ?? conversation(id).map(\.raw.latestMessageID)
        guard let mid = latest, !mid.isEmpty else { return }
        scheduleMarkRead(id, messageID: mid)
    }

    /// Debounced per conversation, and skipped if that message was already marked read.
    private func scheduleMarkRead(_ cid: String, messageID: String) {
        guard lastMarkedRead[cid] != messageID, let c = client else { return }
        markReadTasks[cid]?.cancel()
        markReadTasks[cid] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            if (try? await c.markRead(conversationID: cid, messageID: messageID)) != nil {
                self?.lastMarkedRead[cid] = messageID
            }
            self?.markReadTasks[cid] = nil
        }
    }

    func markAllRead() {
        for c in unreadConversations { markConversationRead(c.id) }
    }

    // MARK: - Alerts

    func alertsHidden(_ conv: ConversationVM) -> Bool { hiddenAlerts.contains(conv.id) }

    func setAlertsHidden(_ conv: ConversationVM, _ hidden: Bool) {
        var s = hiddenAlerts
        if hidden { s.insert(conv.id) } else { s.remove(conv.id) }
        hiddenAlerts = s
        Prefs.hiddenAlerts = s
        if hidden { notifications.clear(conversationID: conv.id) }
    }

    func showAllAlerts() {
        hiddenAlerts = []
        Prefs.hiddenAlerts = []
    }

    /// Reply typed into a notification banner.
    func replyFromNotification(conversationID cid: String, text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let c = client else { return }
        var conv = conversation(cid)
        if conv == nil, let raw = try? await c.getConversation(cid) {
            let vm = ConversationVM(raw)
            upsert(vm)
            conv = vm
        }
        guard let target = conv else { return }
        await send(text: trimmed, to: target, replyTo: nil)
        markConversationRead(cid)
    }

    // MARK: - Sending

    func send(text: String, attachments: [OutgoingAttachment] = [], to conv: ConversationVM) async {
        let reply = replyingTo?.id
        replyingTo = nil
        await send(text: text, attachments: attachments, to: conv, replyTo: reply)
    }

    private func send(text: String, attachments: [OutgoingAttachment] = [], to conv: ConversationVM, replyTo reply: String?) async {
        guard let c = client else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        let tmp = GMClient.newTmpID()
        let local = MessageVM(localText: trimmed, tmpID: tmp, conversationID: conv.id, replyToID: reply ?? "",
                              pendingMediaCount: attachments.count)
        // Only add an optimistic copy to a conversation whose history is loaded; otherwise opening it later would
        // think the history is already there.
        if messages[conv.id] != nil { messages[conv.id]?.append(local) }
        if !attachments.isEmpty {
            localPreviews[tmp] = attachments.compactMap(\.preview)
            outgoing[tmp] = attachments
        }
        if let i = conversations.firstIndex(where: { $0.id == conv.id }) {
            conversations[i].preview = local.summaryText
            conversations[i].timestamp = Date()
        }
        do {
            var uploaded: [GMMediaContent] = []
            for a in attachments { uploaded.append(try await c.uploadMedia(data: a.data, fileName: a.name, mime: a.mime)) }
            let r = try await c.sendText(trimmed, to: conv.raw, replyTo: reply, media: uploaded, tmpID: tmp)
            if r.status.rawValue != 1 { throw GMError.protocolError("Your phone couldn't send the message (status \(r.status.rawValue)).") }
            if let i = messages[conv.id]?.firstIndex(where: { $0.tmpID == tmp && $0.isLocal && $0.state == .sending }) {
                messages[conv.id]?[i].state = .sent
            }
            outgoing[tmp] = nil
        } catch {
            if let i = messages[conv.id]?.firstIndex(where: { $0.tmpID == tmp && $0.isLocal }) { messages[conv.id]?[i].state = .failed }
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
        if m.isLocal {                                   // never reached the phone: just drop it
            messages[m.conversationID]?.removeAll { $0.id == m.id }
            localPreviews[m.tmpID] = nil; outgoing[m.tmpID] = nil
            return
        }
        guard let c = client else { return }
        Task {
            do {
                try await c.deleteMessage(m.id)
                messages[m.conversationID]?.removeAll { $0.id == m.id }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func retry(_ m: MessageVM, in conv: ConversationVM) {
        let attachments = outgoing[m.tmpID] ?? []
        messages[conv.id]?.removeAll { $0.id == m.id }
        localPreviews[m.tmpID] = nil; outgoing[m.tmpID] = nil
        Task { await send(text: m.text, attachments: attachments, to: conv, replyTo: m.replyToID.isEmpty ? nil : m.replyToID) }
    }

    // MARK: - Conversation management

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
                notifications.clear(conversationID: conv.id)
                updateDockBadge()
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

    // MARK: - Avatars (batched)

    func requestAvatars(for c: ConversationVM) {
        guard let client else { return }
        if c.isGroup, !c.groupAvatarURL.isEmpty {
            let key = "g:" + c.id + c.groupAvatarURL
            guard requestedAvatars.insert(key).inserted else { return }
            let url = c.groupAvatarURL
            Task {
                if let d = try? await client.downloadAvatar(url), let img = LinkPreviewFetcher.decodeImage(d, maxPixel: 256) {
                    groupAvatars[c.id] = img
                } else {
                    avatarFailures[key, default: 0] += 1
                    if avatarFailures[key, default: 0] < 3 { requestedAvatars.remove(key) }   // retry on a later update
                }
            }
            return
        }
        // 1:1 chats use the contact's photo; groups without their own icon use a collage of up to 4 members.
        queueThumbnails(Array(c.avatarParticipantIDs.prefix(c.isGroup ? 4 : 1)))
    }

    /// Collects participant IDs for ~0.3 s and fetches them in a few RPCs instead of one RPC per conversation.
    private func queueThumbnails(_ ids: [String]) {
        for id in ids where requestedAvatars.insert(id).inserted { pendingThumbIDs.insert(id) }
        guard !pendingThumbIDs.isEmpty, thumbFlushTask == nil else { return }
        thumbFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            await self?.flushThumbnails()
        }
    }

    private func flushThumbnails() async {
        thumbFlushTask = nil
        guard let client else { return }
        let ids = Array(pendingThumbIDs)
        pendingThumbIDs = []
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(start + 25, ids.count)])
            start += 25
            if let thumbs = try? await client.participantThumbnails(chunk) {
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

    // MARK: - Media

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

    /// Full attachment bytes, decrypted. Small in-memory cache (nothing is written to disk).
    func mediaData(for item: MediaItem) async -> Data? {
        if let d = mediaCache[item.id] { return d }
        guard let client, let d = try? await client.downloadMedia(id: item.id, key: item.key) else { return nil }
        if d.count < 15 * 1024 * 1024 {
            mediaCache[item.id] = d
            mediaCacheOrder.append(item.id)
            if mediaCacheOrder.count > 12 { mediaCache[mediaCacheOrder.removeFirst()] = nil }
        }
        return d
    }

    func saveMedia(_ item: MediaItem) {
        Task {
            guard let d = await mediaData(for: item) else { errorMessage = "Couldn't download the attachment."; return }
            let panel = NSSavePanel()
            let safe = (item.name as NSString).lastPathComponent.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            panel.nameFieldStringValue = safe.isEmpty || safe.hasPrefix(".") ? "attachment" : safe
            if panel.runModal() == .OK, let url = panel.url { try? d.write(to: url) }
        }
    }

    /// Writes an attachment to a private temp file (removed on next launch) for sharing to other apps.
    func temporaryFile(for item: MediaItem) async -> URL? {
        guard let d = await mediaData(for: item) else { return nil }
        let safe = (item.name as NSString).lastPathComponent.replacingOccurrences(of: "/", with: "_")
        let name = safe.isEmpty || safe.hasPrefix(".") ? "attachment" : safe
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gmm-share-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = dir.appendingPathComponent(name)
            guard FileManager.default.createFile(atPath: url.path, contents: d, attributes: [.posixPermissions: 0o600]) else { return nil }
            return url
        } catch { return nil }
    }
}
