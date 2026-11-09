import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject var model: AppModel
    let conversation: ConversationVM

    @State private var findVisible = false
    @State private var findText = ""
    @State private var findIndex = 0
    @FocusState private var findFocused: Bool

    private var list: [MessageVM] { model.messages[conversation.id] ?? [] }
    private var isTyping: Bool { (model.typing[conversation.id] ?? .distantPast) > Date() }

    /// IDs of messages matching the find query, oldest first.
    private var matches: [String] {
        let q = findText.trimmingCharacters(in: .whitespaces)
        guard findVisible, !q.isEmpty else { return [] }
        return list.filter { $0.text.localizedCaseInsensitiveContains(q) || $0.subject.localizedCaseInsensitiveContains(q) }.map(\.id)
    }

    private var currentMatch: String? {
        let m = matches
        guard !m.isEmpty else { return nil }
        return m[min(max(findIndex, 0), m.count - 1)]
    }

    @State private var atBottom = true

    /// Changes whenever the last row's height can change without its id changing.
    private var lastRowKey: String {
        guard let m = list.last else { return "" }
        return "\(m.id)|\(m.state)|\(m.reactions.count)|\(m.media.count)"
    }

    /// Deferred one runloop so the row's new height is laid out before scrolling.
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) } }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if findVisible { findBar; Divider() }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if model.hasOlder(conversation.id) {
                            Button("Load earlier messages") { Task { await model.loadOlder(conversation.id) } }
                                .buttonStyle(.link).padding(8)
                        }
                        ForEach(Array(list.enumerated()), id: \.element.id) { idx, m in
                            let prev = idx > 0 ? list[idx - 1] : nil
                            let next = idx + 1 < list.count ? list[idx + 1] : nil
                            if prev == nil || m.timestamp.timeIntervalSince(prev!.timestamp) > 3600 {
                                Text(m.timestamp.chatHeaderString).font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary).padding(.vertical, 10)
                            }
                            let lastInRun = next == nil || next!.isFromMe != m.isFromMe || next!.participantID != m.participantID
                                || next!.timestamp.timeIntervalSince(m.timestamp) > 120
                            let firstInRun = prev == nil || prev!.isFromMe != m.isFromMe || prev!.participantID != m.participantID
                                || m.timestamp.timeIntervalSince(prev!.timestamp) > 120
                            MessageRow(message: m, conversation: conversation, showTail: lastInRun,
                                       showSender: conversation.isGroup && !m.isFromMe && firstInRun,
                                       replyTarget: m.replyToID.isEmpty ? nil : list.first(where: { $0.id == m.replyToID }),
                                       isLastSent: m.isFromMe && list.last(where: { $0.isFromMe })?.id == m.id,
                                       highlighted: currentMatch == m.id)
                                .id(m.id)
                                .padding(.top, firstInRun ? 6 : 1)
                        }
                        if isTyping { TypingBubble().padding(.top, 6).id("typing") }
                        Color.clear.frame(height: 6).id("bottom")
                            .onAppear { atBottom = true }
                            .onDisappear { atBottom = false }
                    }
                    .padding(.horizontal, 16)
                }
                .onChange(of: list.last?.id) { _ in
                    guard !findVisible else { return }
                    scrollToBottom(proxy)
                }
                // Rows grow after they're added ("Delivered"/"Read" line, link cards loading): keep following if pinned.
                .onChange(of: lastRowKey) { _ in if atBottom && !findVisible { scrollToBottom(proxy) } }
                .onReceive(LinkPreviewStore.shared.$previews) { _ in if atBottom && !findVisible { scrollToBottom(proxy) } }
                .onChange(of: isTyping) { typing in if typing && !findVisible { proxy.scrollTo("bottom") } }
                .onChange(of: currentMatch) { id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                }
                .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { proxy.scrollTo("bottom") } }
                .overlay { if model.loadingMessages && list.isEmpty { ProgressView() } }
            }
            ComposerView(conversation: conversation)
        }
        .onReceive(NotificationCenter.default.publisher(for: .findInConversation)) { _ in openFind() }
    }

    private var header: some View {
        VStack(spacing: 2) {
            AvatarView(image: model.avatar(for: conversation), initials: conversation.initials, colorHex: conversation.colorHex,
                       size: 36, symbol: conversation.isGroup ? "person.2.fill" : nil, collage: model.collage(for: conversation))
            HStack(spacing: 4) {
                Text(conversation.name).font(.system(size: 11, weight: .medium))
                if model.alertsHidden(conversation) {
                    Image(systemName: "bell.slash.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            if conversation.isGroup {
                Text("\(conversation.raw.participants.count) people").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 6)
        .overlay(alignment: .trailing) {
            HStack(spacing: 12) {
                Button { openFind() } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.plain).help("Find in Conversation (⌥⌘F)")
                Button { model.setAlertsHidden(conversation, !model.alertsHidden(conversation)) } label: {
                    Image(systemName: model.alertsHidden(conversation) ? "bell.slash" : "bell")
                }
                .buttonStyle(.plain)
                .help(model.alertsHidden(conversation) ? "Show Alerts" : "Hide Alerts")
            }
            .font(.system(size: 14)).foregroundStyle(.secondary).padding(.trailing, 14)
        }
        .background(.bar)
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in conversation", text: $findText)
                .textFieldStyle(.plain)
                .focused($findFocused)
                .onSubmit { step(-1) }
                .onChange(of: findText) { _ in findIndex = max(matches.count - 1, 0) }
            if !findText.isEmpty {
                Text(matches.isEmpty ? "No matches" : "\(min(findIndex, matches.count - 1) + 1) of \(matches.count)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            Button { step(-1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain).disabled(matches.count < 2).help("Older match")
            Button { step(1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain).disabled(matches.count < 2).help("Newer match")
            if model.hasOlder(conversation.id) {
                Button("Search Earlier") { Task { await model.loadOlder(conversation.id) } }
                    .buttonStyle(.link).font(.system(size: 11))
                    .help("Load older messages so they can be searched")
            }
            Button("Done") { closeFind() }.buttonStyle(.plain).foregroundStyle(Theme.blue)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(.bar)
        .onExitCommand { closeFind() }
    }

    private func openFind() {
        findVisible = true
        DispatchQueue.main.async { findFocused = true }
    }

    private func closeFind() {
        findVisible = false
        findText = ""
        findIndex = 0
    }

    /// -1 = older, +1 = newer, wrapping around.
    private func step(_ delta: Int) {
        let n = matches.count
        guard n > 0 else { return }
        findIndex = ((min(findIndex, n - 1) + delta) % n + n) % n
    }
}

struct MessageRow: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) var scheme
    let message: MessageVM
    let conversation: ConversationVM
    let showTail: Bool
    let showSender: Bool
    let replyTarget: MessageVM?
    let isLastSent: Bool
    var highlighted = false

    private let tapbacks = ["❤️", "👍", "👎", "😂", "😮", "😢"]
    @State private var showActions = false
    @State private var hovering = false
    @AppStorage(Prefs.Key.linkPreviewMode) private var previewMode: LinkPreviewMode = Prefs.linkPreviewMode

    var body: some View {
        if message.isTombstone {
            Text(message.text.isEmpty ? "Message deleted" : message.text).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 4)
        } else {
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 2) {
                if showSender {
                    Text(message.senderName).font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 12)
                }
                HStack(alignment: .bubbleCenter, spacing: 4) {
                    if message.isFromMe { Spacer(minLength: 60); hoverButton }
                    bubbleStack
                    if !message.isFromMe { hoverButton; Spacer(minLength: 60) }
                }
                .onHover { hovering = $0 }
                statusLine
            }
        }
    }

    private var hoverButton: some View {
        Button { showActions = true } label: {
            Image(systemName: "face.smiling")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.secondary.opacity(0.18)))
        }
        .buttonStyle(.plain)
        .opacity(hovering || showActions ? 1 : 0)
        .help("React, reply, copy…")
    }

    private var bubbleStack: some View {
        VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 3) {
            if let r = replyTarget {
                Text(r.summaryText).font(.system(size: 11)).lineLimit(2)
                    .foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.4)))
            }
            if message.isLocal && message.pendingMediaCount > 0 { pendingAttachments }
            ForEach(message.media) { item in MediaView(item: item, fromMe: message.isFromMe) }
            if emojiOnly {
                Text(message.text.trimmingCharacters(in: .whitespacesAndNewlines)).font(.system(size: 52))
                    .alignmentGuide(.bubbleCenter) { $0[VerticalAlignment.center] }
            } else {
                let link = firstLink
                LinkPreviewSlot(url: previewURL, linkOnly: link?.isWholeText ?? false,
                                hasText: !message.text.isEmpty || !message.subject.isEmpty) { textBubble }
            }
        }
        // Load from here, not from LinkCard: LinkCard renders nothing until loaded, so its own onAppear never fires.
        .task(id: previewURL) { if let url = previewURL { LinkPreviewStore.shared.load(url) } }
        .background {
            if highlighted {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.yellow.opacity(0.35)).padding(-5)
            }
        }
        .overlay(alignment: message.isFromMe ? .topLeading : .topTrailing) { reactionBadges.offset(x: message.isFromMe ? -10 : 10, y: -10) }
        .padding(.top, message.reactions.isEmpty ? 0 : 8)
        .onLongPressGesture(minimumDuration: 0.35, maximumDistance: 25) { showActions = true }
        .help(message.timestamp.formatted(date: .abbreviated, time: .standard))
        .popover(isPresented: $showActions, arrowEdge: message.isFromMe ? .leading : .trailing) {
            MessageActionsView(message: message, conversation: conversation) { showActions = false }.environmentObject(model)
        }
        .contextMenu {
            if !message.isLocal {
                Menu("Tapback") { ForEach(tapbacks, id: \.self) { e in Button(e) { model.react(message, emoji: e, in: conversation) } } }
                Button("Reply") { model.replyingTo = message }
            }
            if !message.text.isEmpty { Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string) } }
            if message.state == .failed { Button("Try Again") { model.retry(message, in: conversation) } }
            Divider()
            Button("Delete", role: .destructive) { model.delete(message) }
        }
    }

    /// Attachments of a message that is still uploading: show the local previews dimmed with a spinner.
    @ViewBuilder private var pendingAttachments: some View {
        let previews = model.localPreviews[message.tmpID] ?? []
        if previews.isEmpty {
            Label(message.pendingMediaCount == 1 ? "Sending attachment…" : "Sending \(message.pendingMediaCount) attachments…",
                  systemImage: "paperclip")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(10).background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.18)))
        } else {
            ForEach(Array(previews.enumerated()), id: \.offset) { _, img in
                Image(nsImage: img).resizable().scaledToFit()
                    .frame(maxWidth: 260, maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .opacity(message.state == .failed ? 1 : 0.6)
                    .overlay { if message.state == .sending { ProgressView() } }
            }
        }
    }

    private var textBubble: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !message.subject.isEmpty { Text(message.subject).fontWeight(.semibold) }
            if !message.text.isEmpty { Text(linkified(message.text)) }
        }
        .font(.system(size: 14))
        .foregroundStyle(message.isFromMe ? Color.white : Color.primary)
        .tint(message.isFromMe ? Color.white : Theme.blue)
        .padding(.leading, message.isFromMe ? 12 : 17).padding(.trailing, message.isFromMe ? 17 : 12)
        .padding(.vertical, 7)
        .background(bubbleFill.clipShape(BubbleShape(fromMe: message.isFromMe, tail: showTail)))
    }

    private var senderIsContact: Bool {
        if !message.senderContactID.isEmpty { return true }
        return conversation.raw.participants.contains { $0.id.participantID == message.participantID && !$0.contactID.isEmpty }
    }

    private var previewURL: URL? {
        guard !emojiOnly, previewMode.allows(fromMe: message.isFromMe, senderIsContact: senderIsContact) else { return nil }
        return firstLink?.url
    }

    /// First http(s) link, and whether it is the entire message (then the card replaces the text, like iMessage).
    private var firstLink: (url: URL, isWholeText: Bool)? {
        let t = message.text
        guard !t.isEmpty, let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
              let m = det.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), let url = m.url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let r = Range(m.range, in: t) else { return nil }
        let whole = message.subject.isEmpty
            && t[r].trimmingCharacters(in: .whitespacesAndNewlines) == t.trimmingCharacters(in: .whitespacesAndNewlines)
        return (url, whole)
    }

    private var emojiOnly: Bool {
        let t = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 3, message.media.isEmpty, message.subject.isEmpty else { return false }
        return t.allSatisfy { ch in
            ch.unicodeScalars.allSatisfy { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x238C) || $0.value == 0x200D || $0.value == 0xFE0F }
        }
    }

    @ViewBuilder private var bubbleFill: some View {
        if message.isFromMe { Theme.blueGradient } else { scheme == .dark ? Theme.receivedDark : Theme.receivedLight }
    }

    @ViewBuilder private var reactionBadges: some View {
        if !message.reactions.isEmpty {
            HStack(spacing: 2) {
                ForEach(message.reactions) { r in
                    Text(r.count > 1 ? "\(r.emoji)\(r.count)" : r.emoji).font(.system(size: 12))
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(scheme == .dark ? Color(white: 0.2) : .white).shadow(radius: 1))
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch message.state {
        case .failed:
            Button { model.retry(message, in: conversation) } label: {
                Label("Not Delivered · Try Again", systemImage: "exclamationmark.circle.fill").font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundStyle(.red)
        case .sending where isLastSent:
            Text("Sending…").font(.system(size: 11)).foregroundStyle(.secondary)
        case .read where isLastSent:
            Text("Read").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        case .delivered where isLastSent:
            Text("Delivered").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        default: EmptyView()
        }
    }

    private func linkified(_ s: String) -> AttributedString {
        var a = AttributedString(s)
        if let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for m in det.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                if let r = Range(m.range, in: s), let ar = Range(r, in: a), let url = m.url,
                   ["http", "https", "mailto", "tel"].contains(url.scheme?.lowercased() ?? "") {
                    a[ar].link = url
                    a[ar].underlineStyle = .single
                    a[ar].foregroundColor = message.isFromMe ? Color.white : Theme.blue
                }
            }
        }
        return a
    }
}

struct MediaView: View {
    @EnvironmentObject var model: AppModel
    let item: MediaItem
    var fromMe = false

    var body: some View {
        if item.isAudio {
            AudioBubble(item: item, fromMe: fromMe)
                .contextMenu {
                    Button("Save…") { model.saveMedia(item) }
                    Button("Share…") { share() }
                }
        } else {
            Group {
                if item.isImage || item.isVideo, let img = model.image(for: item) {
                    ZStack {
                        Image(nsImage: img).resizable().scaledToFit()
                        if item.isVideo { Image(systemName: "play.circle.fill").font(.system(size: 40)).foregroundStyle(.white.opacity(0.9)) }
                    }
                    .frame(maxWidth: 260, maxHeight: 320).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else if item.isImage || item.isVideo {
                    RoundedRectangle(cornerRadius: 18).fill(Color.secondary.opacity(0.2)).frame(width: 200, height: 140)
                        .overlay(ProgressView())
                } else {
                    HStack {
                        Image(systemName: "doc.fill")
                        Text(item.name.isEmpty ? "Attachment" : item.name).lineLimit(1)
                    }
                    .padding(10).background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.18)))
                }
            }
            .onAppear { if item.isImage || item.isVideo { model.loadImage(item) } }
            .onTapGesture { model.viewing = item }
            .contextMenu {
                Button("Open") { model.viewing = item }
                Button("Save…") { model.saveMedia(item) }
                Button("Share…") { share() }
            }
        }
    }

    private func share() {
        Task {
            guard let url = await model.temporaryFile(for: item) else { model.errorMessage = "Couldn't download the attachment."; return }
            SharePresenter.share(url)
        }
    }
}

/// Inline player for voice messages and other audio, like the Messages app.
struct AudioBubble: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var playback = AudioPlayback.shared
    @Environment(\.colorScheme) var scheme
    let item: MediaItem
    let fromMe: Bool

    private var isCurrent: Bool { playback.currentID == item.id }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                Task { if let err = await playback.toggle(item, model: model) { model.errorMessage = err } }
            } label: {
                ZStack {
                    if playback.loadingID == item.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: isCurrent && playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .bold))
                    }
                }
                .frame(width: 30, height: 30)
                .background(Circle().fill(fromMe ? Color.white.opacity(0.25) : Theme.blue.opacity(0.15)))
            }
            .buttonStyle(.plain)
            WaveformView(seed: item.id, progress: isCurrent ? playback.progress : 0,
                         played: fromMe ? .white : Theme.blue, unplayed: fromMe ? Color.white.opacity(0.45) : Color.secondary.opacity(0.5))
                .frame(width: 130, height: 22)
            Text(isCurrent && playback.duration > 0 ? playback.duration.clockString : "Audio")
                .font(.system(size: 11)).monospacedDigit()
                .opacity(0.85)
        }
        .foregroundStyle(fromMe ? Color.white : Color.primary)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(fromMe ? AnyShapeStyle(Theme.blueGradient) : AnyShapeStyle(scheme == .dark ? Theme.receivedDark : Theme.receivedLight))
        )
        .help(item.name.isEmpty ? "Audio message" : item.name)
    }
}

/// Decorative waveform: bar heights derived from the attachment id, so each message keeps the same shape.
struct WaveformView: View {
    let seed: String
    let progress: Double
    let played: Color
    let unplayed: Color
    private let bars = 26

    var body: some View {
        let heights = Waveform.heights(for: seed, count: bars)
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<bars, id: \.self) { i in
                    Capsule()
                        .fill(Double(i) / Double(bars) < progress ? played : unplayed)
                        .frame(height: max(3, geo.size.height * heights[i]))
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}


/// Bar heights (0.25…1) derived from the attachment id, so each audio message keeps the same shape.
enum Waveform {
    static func heights(for seed: String, count: Int) -> [CGFloat] {
        var h: UInt64 = 14_695_981_039_346_656_037            // FNV-1a
        for b in seed.utf8 { h = (h ^ UInt64(b)) &* 1_099_511_628_211 }
        var out: [CGFloat] = []
        for _ in 0..<count {
            h ^= h << 13; h ^= h >> 7; h ^= h << 17           // xorshift
            out.append(0.25 + CGFloat(h % 1000) / 1000 * 0.75)
        }
        return out
    }
}

enum SharePresenter {
    /// Shows the macOS share menu for a file, at the mouse position in the key window.
    @MainActor static func share(_ url: URL) {
        guard let window = NSApp.keyWindow, let view = window.contentView else { return }
        let p = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: NSRect(x: p.x, y: p.y, width: 1, height: 1), of: view, preferredEdge: .minY)
    }
}

struct TypingBubble: View {
    @State private var phase = 0.0
    var body: some View {
        HStack {
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle().fill(Color.secondary).frame(width: 7, height: 7)
                        .opacity(0.4 + 0.6 * abs(sin(phase + Double(i) * 0.6)))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Color.secondary.opacity(0.2).clipShape(BubbleShape(fromMe: false, tail: true)))
            Spacer()
        }
        .onAppear { withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { phase = .pi * 2 } }
    }
}

struct ComposerView: View {
    @EnvironmentObject var model: AppModel
    let conversation: ConversationVM
    @State private var text = ""
    @State private var attachments: [OutgoingAttachment] = []
    @State private var textHeight: CGFloat = GrowingTextView.singleLineHeight
    @StateObject private var recorder = VoiceRecorder()

    var body: some View {
        VStack(spacing: 0) {
            if let r = model.replyingTo {
                HStack {
                    Image(systemName: "arrowshape.turn.up.left").foregroundStyle(.secondary)
                    Text(r.summaryText).lineLimit(1).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.replyingTo = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                }.font(.caption).padding(.horizontal, 16).padding(.top, 6)
            }
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) { ForEach(attachments) { chip($0) } }.padding(.horizontal, 16).padding(.top, 10)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button { pickFile() } label: {
                    Image(systemName: "plus.circle.fill").font(.system(size: 24)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).padding(.bottom, 2).help("Attach files")
                .disabled(recorder.isRecording)

                if recorder.isRecording { recordingField } else { textField }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .background(.bar)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let d = item as? Data, let url = URL(dataRepresentation: d, relativeTo: nil) else { return }
                    let prepared = AttachmentPrep.prepare(fileURL: url)
                    DispatchQueue.main.async { add(prepared, name: url.lastPathComponent) }
                }
            }
            return true
        }
        .onAppear { text = model.drafts[conversation.id] ?? "" }
        .onDisappear {
            model.drafts[conversation.id] = text
            if recorder.isRecording { recorder.cancel() }
        }
    }

    private var textField: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(conversation.raw.sendMode.rawValue == 0 ? "Text Message" : "Text Message · SMS")
                        .font(.system(size: 14)).foregroundStyle(.tertiary).lineLimit(1)
                        .padding(.top, GrowingTextView.verticalInset).allowsHitTesting(false)
                }
                GrowingTextView(text: $text, height: $textHeight, onSubmit: sendNow,
                                onChange: { t in if !t.isEmpty { model.typingChanged(in: conversation) } },
                                onPaste: { d, n, m in add(AttachmentPrep.prepare(data: d, name: n, mime: m), name: n) })
            }
            // The field's height is driven only by the text view, never by the placeholder.
            .frame(height: textHeight, alignment: .topLeading)
            .transaction { $0.animation = nil }
            Button { NSApp.orderFrontCharacterPalette(nil) } label: {
                Image(systemName: "face.smiling").font(.system(size: 16)).foregroundStyle(.secondary)
                    .frame(width: 22, height: GrowingTextView.singleLineHeight)
            }.buttonStyle(.plain).help("Emoji & Symbols")
            // Send and mic share one fixed-size slot so swapping them (first keystroke) can't resize the bar.
            ZStack {
                if canSend {
                    Button(action: sendNow) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.blue)
                    }.buttonStyle(.plain).help("Send")
                } else if VoiceRecorder.isAvailable {
                    Button { startRecording() } label: {
                        Image(systemName: "mic.fill").font(.system(size: 15)).foregroundStyle(.secondary)
                    }.buttonStyle(.plain).help("Record a voice message")
                }
            }
            .frame(width: 24, height: GrowingTextView.singleLineHeight)
            .transaction { $0.animation = nil }
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.secondary.opacity(0.4)))
    }

    private var recordingField: some View {
        HStack(spacing: 10) {
            Button { recorder.cancel() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(.secondary)
            }.buttonStyle(.plain).help("Discard recording")
            Circle().fill(Color.red).frame(width: 8, height: 8)
            Text(recorder.elapsed.clockString).font(.system(size: 13)).monospacedDigit()
            GeometryReader { geo in
                Capsule().fill(Color.secondary.opacity(0.2))
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.red.opacity(0.7)).frame(width: max(4, geo.size.width * recorder.level))
                    }
            }
            .frame(height: 6)
            Button { finishRecording() } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 24)).foregroundStyle(Theme.blue)
            }.buttonStyle(.plain).help("Send voice message")
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.red.opacity(0.5)))
        .onExitCommand { recorder.cancel() }
    }

    @ViewBuilder private func chip(_ a: OutgoingAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let img = a.preview {
                    Image(nsImage: img).resizable().scaledToFill()
                } else {
                    VStack(spacing: 2) {
                        Image(systemName: a.mime.hasPrefix("audio/") ? "waveform" : "doc.fill").font(.title3)
                        Text(a.name).font(.system(size: 9)).lineLimit(1).padding(.horizontal, 3)
                    }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.secondary.opacity(0.18))
                }
            }
            .frame(width: 58, height: 58).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Button { attachments.removeAll { $0.id == a.id } } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 16)).symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.black.opacity(0.65))
            }.buttonStyle(.plain).offset(x: 5, y: -5)
        }
        .padding(.top, 5).padding(.trailing, 5)
    }

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }

    private func sendNow() {
        guard canSend else { return }
        let t = text, a = attachments
        text = ""; attachments = []
        model.drafts[conversation.id] = ""
        Task { await model.send(text: t, attachments: a, to: conversation) }
    }

    private func startRecording() {
        Task { if let err = await recorder.start() { model.errorMessage = err } }
    }

    private func finishRecording() {
        guard let a = recorder.finish() else { return }
        Task { await model.send(text: "", attachments: [a], to: conversation) }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { add(AttachmentPrep.prepare(fileURL: url), name: url.lastPathComponent) }
    }

    private func add(_ a: OutgoingAttachment?, name: String) {
        guard let a else {
            model.errorMessage = "\(name) couldn't be attached. Files must be under 100 MB."
            return
        }
        attachments.append(a)
    }
}

struct NewChatView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var query = ""
    @State private var recipients: [String] = []

    private var matches: [ContactVM] {
        let q = query.lowercased()
        return q.isEmpty ? Array(model.contacts.prefix(60)) : model.contacts.filter { $0.name.lowercased().contains(q) || $0.number.contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New Message").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
            }.padding(12)
            Divider()
            HStack {
                Text("To:").foregroundStyle(.secondary)
                ForEach(recipients, id: \.self) { r in
                    Text(r).padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(Theme.blue.opacity(0.2)))
                        .onTapGesture { recipients.removeAll { $0 == r } }
                }
                TextField("Name or phone number", text: $query).textFieldStyle(.plain).onSubmit(addTyped)
            }.padding(10)
            Divider()
            List(matches) { c in
                Button { add(c.number) } label: {
                    HStack {
                        AvatarView(image: nil, initials: String(c.name.prefix(1)).uppercased(), colorHex: c.colorHex, size: 30)
                        VStack(alignment: .leading) { Text(c.name); Text(c.number).font(.caption).foregroundStyle(.secondary) }
                    }
                }.buttonStyle(.plain)
            }
            Divider()
            HStack {
                Spacer()
                Button("Start Chat") {
                    addTyped()
                    let nums = recipients
                    dismiss()
                    Task { await model.startConversation(numbers: nums) }
                }
                .buttonStyle(.borderedProminent).tint(Theme.blue)
                .disabled(recipients.isEmpty && query.trimmingCharacters(in: .whitespaces).isEmpty)
            }.padding(12)
        }
        .frame(width: 440, height: 520)
    }

    private func add(_ n: String) { if !recipients.contains(n) { recipients.append(n) }; query = "" }
    private func addTyped() {
        let t = query.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { add(t) }
    }
}

extension VerticalAlignment {
    /// Centre of a message's main text bubble, so row accessories (react/reply button) line up with it rather than
    /// with the whole stack (reply quote + bubble + link card). Falls back to the stack's centre when there's no text.
    private enum BubbleCenter: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] }
    }
    static let bubbleCenter = VerticalAlignment(BubbleCenter.self)
}
