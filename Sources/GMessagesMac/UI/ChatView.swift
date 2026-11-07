import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject var model: AppModel
    let conversation: ConversationVM

    private var list: [MessageVM] { model.messages[conversation.id] ?? [] }
    private var isTyping: Bool { (model.typing[conversation.id] ?? .distantPast) > Date() }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
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
                                       replyTarget: list.first { $0.id == m.replyToID },
                                       isLastSent: m.isFromMe && list.last(where: { $0.isFromMe })?.id == m.id)
                                .id(m.id)
                                .padding(.top, firstInRun ? 6 : 1)
                        }
                        if isTyping { TypingBubble().padding(.top, 6).id("typing") }
                        Color.clear.frame(height: 6).id("bottom")
                    }
                    .padding(.horizontal, 16)
                }
                .onChange(of: list.last?.id) { _ in withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom") } }
                .onChange(of: isTyping) { _ in proxy.scrollTo("bottom") }
                .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { proxy.scrollTo("bottom") } }
                .overlay { if model.loadingMessages && list.isEmpty { ProgressView() } }
            }
            ComposerView(conversation: conversation)
        }
    }

    private var header: some View {
        VStack(spacing: 2) {
            AvatarView(image: model.avatar(for: conversation), initials: conversation.initials, colorHex: conversation.colorHex, size: 36, symbol: conversation.isGroup ? "person.2.fill" : nil, collage: model.collage(for: conversation))
            Text(conversation.name).font(.system(size: 11, weight: .medium))
            if conversation.isGroup { Text("\(conversation.raw.participants.count) people").font(.system(size: 10)).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 6)
        .background(.bar)
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

    private let tapbacks = ["❤️", "👍", "👎", "😂", "😮", "😢"]
    @State private var showActions = false
    @State private var hovering = false
    @AppStorage("linkPreviews") private var linkPreviews = true

    var body: some View {
        if message.isTombstone {
            Text(message.text.isEmpty ? "Message deleted" : message.text).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 4)
        } else {
            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 2) {
                if showSender {
                    Text(message.senderName).font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 12)
                }
                HStack(spacing: 4) {
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
                Text(r.text.isEmpty ? "Attachment" : r.text).font(.system(size: 11)).lineLimit(2)
                    .foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.4)))
            }
            ForEach(message.media) { item in MediaView(item: item) }
            if emojiOnly {
                Text(message.text.trimmingCharacters(in: .whitespacesAndNewlines)).font(.system(size: 52))
            } else if !message.text.isEmpty || !message.subject.isEmpty {
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
            if linkPreviews, !emojiOnly, let url = firstURL { LinkCard(url: url) }
        }
        .overlay(alignment: message.isFromMe ? .topLeading : .topTrailing) { reactionBadges.offset(x: message.isFromMe ? -10 : 10, y: -10) }
        .padding(.top, message.reactions.isEmpty ? 0 : 8)
        .onLongPressGesture(minimumDuration: 0.35, maximumDistance: 25) { showActions = true }
        .help(message.timestamp.formatted(date: .abbreviated, time: .standard))
        .popover(isPresented: $showActions, arrowEdge: message.isFromMe ? .leading : .trailing) {
            MessageActionsView(message: message, conversation: conversation) { showActions = false }.environmentObject(model)
        }
        .contextMenu {
            Menu("Tapback") { ForEach(tapbacks, id: \.self) { e in Button(e) { model.react(message, emoji: e, in: conversation) } } }
            Button("Reply") { model.replyingTo = message }
            if !message.text.isEmpty { Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string) } }
            if message.state == .failed { Button("Try Again") { model.retry(message, in: conversation) } }
            Divider()
            Button("Delete", role: .destructive) { model.delete(message) }
        }
    }

    private var firstURL: URL? {
        guard !message.text.isEmpty, let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let m = det.firstMatch(in: message.text, range: NSRange(message.text.startIndex..., in: message.text))
        guard let url = m?.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
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
            Label("Not Delivered", systemImage: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(.red)
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
    var body: some View {
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
                    Image(systemName: item.isAudio ? "waveform" : "doc.fill")
                    Text(item.name.isEmpty ? "Attachment" : item.name).lineLimit(1)
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.18)))
            }
        }
        .onAppear { if item.isImage || item.isVideo { model.loadImage(item) } }
        .onTapGesture { model.viewing = item }
        .contextMenu { Button("Save…") { model.saveMedia(item) } }
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
    @State private var attachments: [Attachment] = []
    @State private var textHeight: CGFloat = GrowingTextView.singleLineHeight

    struct Attachment: Identifiable {
        let id = UUID()
        let data: Data
        let name: String
        let mime: String
        let image: NSImage?
    }

    var body: some View {
        VStack(spacing: 0) {
            if let r = model.replyingTo {
                HStack {
                    Image(systemName: "arrowshape.turn.up.left").foregroundStyle(.secondary)
                    Text(r.text.isEmpty ? "Attachment" : r.text).lineLimit(1).foregroundStyle(.secondary)
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
                }.buttonStyle(.plain).padding(.bottom, 2).help("Attach files")

                HStack(alignment: .bottom, spacing: 8) {
                    ZStack(alignment: .leading) {
                        if text.isEmpty {
                            Text(conversation.raw.sendMode.rawValue == 0 ? "Text Message" : "Text Message · SMS")
                                .font(.system(size: 14)).foregroundStyle(.tertiary).padding(.vertical, 2).allowsHitTesting(false)
                        }
                        GrowingTextView(text: $text, height: $textHeight, onSubmit: sendNow,
                                        onChange: { t in if !t.isEmpty { model.typingChanged(in: conversation) } },
                                        onPaste: { d, n, m in addAttachment(d, n, m) })
                            .frame(height: textHeight)
                            .transaction { $0.animation = nil }
                    }
                    Button { NSApp.orderFrontCharacterPalette(nil) } label: {
                        Image(systemName: "face.smiling").font(.system(size: 16)).foregroundStyle(.secondary)
                    }.buttonStyle(.plain).padding(.bottom, 1).help("Emoji & Symbols")
                    if canSend {
                        Button(action: sendNow) {
                            Image(systemName: "arrow.up.circle.fill").font(.system(size: 24)).foregroundStyle(Theme.blue)
                        }.buttonStyle(.plain).padding(.bottom, -2)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.secondary.opacity(0.4)))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .background(.bar)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    if let d = item as? Data, let url = URL(dataRepresentation: d, relativeTo: nil) { load(url) }
                }
            }
            return true
        }
        .onAppear { text = model.drafts[conversation.id] ?? "" }
        .onDisappear { model.drafts[conversation.id] = text }
    }

    @ViewBuilder private func chip(_ a: Attachment) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let img = a.image {
                    Image(nsImage: img).resizable().scaledToFill()
                } else {
                    VStack(spacing: 2) {
                        Image(systemName: "doc.fill").font(.title3)
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
        let t = text, a = attachments.map { ($0.data, $0.name, $0.mime) }
        text = ""; attachments = []
        model.drafts[conversation.id] = ""
        Task { await model.send(text: t, media: a, to: conversation) }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { panel.urls.forEach(load) }
    }

    private static let maxAttachmentBytes = 100 * 1024 * 1024

    private func load(_ url: URL) {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > Self.maxAttachmentBytes { return }
        guard let data = try? Data(contentsOf: url) else { return }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        DispatchQueue.main.async { addAttachment(data, url.lastPathComponent, mime) }
    }

    private func addAttachment(_ data: Data, _ name: String, _ mime: String) {
        guard data.count <= Self.maxAttachmentBytes else { return }
        attachments.append(Attachment(data: data, name: name, mime: mime, image: mime.hasPrefix("image/") ? NSImage(data: data) : nil))
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
