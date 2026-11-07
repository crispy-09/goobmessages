import SwiftUI
import LinkPresentation

// MARK: - Link previews

@MainActor
final class LinkPreviewStore: ObservableObject {
    static let shared = LinkPreviewStore()

    struct Preview { var title: String; var host: String; var image: NSImage?; var icon: NSImage? }

    @Published private(set) var previews: [URL: Preview] = [:]
    private var attempted = Set<URL>()

    /// Previews fetch a URL chosen by the message sender, so only public https hosts are allowed.
    static func isSafe(_ url: URL) -> Bool { URLSafety.isPublicHTTPS(url) }

    func load(_ url: URL) {
        guard Self.isSafe(url), !attempted.contains(url) else { return }
        attempted.insert(url)
        Task {
            let provider = LPMetadataProvider()
            provider.timeout = 8
            guard let md = try? await provider.startFetchingMetadata(for: url) else { return }
            let image = await Self.image(from: md.imageProvider)
            let icon = await Self.image(from: md.iconProvider)
            previews[url] = Preview(title: md.title ?? "", host: url.host ?? url.absoluteString, image: image, icon: icon)
        }
    }

    private static func image(from provider: NSItemProvider?) async -> NSImage? {
        guard let provider, provider.canLoadObject(ofClass: NSImage.self) else { return nil }
        return await withCheckedContinuation { cont in
            provider.loadObject(ofClass: NSImage.self) { obj, _ in cont.resume(returning: obj as? NSImage) }
        }
    }
}

struct LinkCard: View {
    @ObservedObject private var store = LinkPreviewStore.shared
    let url: URL

    var body: some View {
        Group {
            if let p = store.previews[url], !(p.title.isEmpty && p.image == nil) {
                Button { NSWorkspace.shared.open(url) } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        if let img = p.image {
                            Image(nsImage: img).resizable().scaledToFill().frame(width: 260, height: 140).clipped()
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            if !p.title.isEmpty {
                                Text(p.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                                    .foregroundStyle(.primary).multilineTextAlignment(.leading)
                            }
                            HStack(spacing: 4) {
                                if let ic = p.icon {
                                    Image(nsImage: ic).resizable().frame(width: 12, height: 12)
                                        .clipShape(RoundedRectangle(cornerRadius: 3))
                                }
                                Text(p.host).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .padding(10).frame(width: 260, alignment: .leading)
                    }
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear { store.load(url) }
    }
}

// MARK: - Long-press / action popover

struct MessageActionsView: View {
    @EnvironmentObject var model: AppModel
    let message: MessageVM
    let conversation: ConversationVM
    let dismiss: () -> Void

    private let emojis = ["❤️", "👍", "😂", "😮", "😢", "😡", "👎"]
    private var mine: String? { message.reactions.first(where: { $0.byMe })?.emoji }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                ForEach(emojis, id: \.self) { e in
                    Button {
                        model.react(message, emoji: e, in: conversation)
                        dismiss()
                    } label: {
                        Text(e).font(.system(size: 24)).padding(5)
                            .background(Circle().fill(mine == e ? Theme.blue.opacity(0.3) : Color.clear))
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 8)
            Divider()
            row("Reply", "arrowshape.turn.up.left") { model.replyingTo = message }
            if !message.text.isEmpty {
                row("Copy text", "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.text, forType: .string)
                }
            }
            if let m = message.media.first { row("Save attachment…", "square.and.arrow.down") { model.saveMedia(m) } }
            if message.state == .failed { row("Try again", "arrow.clockwise") { model.retry(message, in: conversation) } }
            Divider()
            row("Delete", "trash", destructive: true) { model.delete(message) }
        }
        .padding(.bottom, 6)
        .frame(width: 290)
    }

    private func row(_ title: String, _ icon: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(destructive ? Color.red : Color.primary)
    }
}
