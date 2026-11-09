import SwiftUI

// MARK: - Link previews

@MainActor
final class LinkPreviewStore: ObservableObject {
    static let shared = LinkPreviewStore()

    struct Preview { var title: String; var host: String; var image: NSImage?; var icon: NSImage? }
    private enum Pending { case loading, failed(Date) }

    @Published private(set) var previews: [URL: Preview] = [:]
    private var pending: [URL: Pending] = [:]
    private var order: [URL] = []

    static let maxEntries = 200
    static let retryAfter: TimeInterval = 300

    /// Previews fetch a URL chosen by the message sender, so only public https hosts are allowed.
    static func isSafe(_ url: URL) -> Bool { URLSafety.isPublicHTTPS(url) }

    /// The URL actually fetched. Links typed without a scheme ("example.com") are detected as http, so they are
    /// upgraded to https; cleartext is never fetched.
    static func fetchURL(for url: URL) -> URL? {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if c.scheme?.lowercased() == "http" { c.scheme = "https"; if c.port == 80 { c.port = nil } }
        c.fragment = nil
        guard let u = c.url, isSafe(u) else { return nil }
        return u
    }

    func load(_ url: URL) {
        guard previews[url] == nil, let target = Self.fetchURL(for: url) else { return }
        switch pending[url] {
        case .loading?: return
        case .failed(let at)? where Date().timeIntervalSince(at) < Self.retryAfter: return
        default: break
        }
        pending[url] = .loading
        Task {
            guard let r = await LinkPreviewFetcher.shared.preview(for: target) else {
                pending[url] = .failed(Date())
                return
            }
            pending[url] = nil
            var host = r.finalURL.host ?? target.host ?? ""
            if host.hasPrefix("www.") { host.removeFirst(4) }
            insert(Preview(title: r.title, host: host, image: r.image, icon: r.icon), for: url)
        }
    }

    /// A loaded preview with something worth showing.
    func displayable(_ url: URL) -> Preview? {
        guard let p = previews[url], !(p.title.isEmpty && p.image == nil) else { return nil }
        return p
    }

    private func insert(_ p: Preview, for url: URL) {
        previews[url] = p
        order.append(url)
        while order.count > Self.maxEntries { previews[order.removeFirst()] = nil }
        if pending.count > 500 { pending = pending.filter { if case .loading = $0.value { return true } else { return false } } }
    }
}

/// The message's text bubble plus its link card. When the message is nothing but the link and the preview has loaded,
/// the card stands in for the bubble (and takes over the `.bubbleCenter` alignment the row's buttons line up with).
struct LinkPreviewSlot<Bubble: View>: View {
    @ObservedObject private var store = LinkPreviewStore.shared
    let url: URL?
    let linkOnly: Bool
    let hasText: Bool
    @ViewBuilder let bubble: () -> Bubble

    var body: some View {
        let card = url.flatMap { store.displayable($0) == nil ? nil : $0 }
        if let card, linkOnly {
            LinkCard(url: card).alignmentGuide(.bubbleCenter) { $0[VerticalAlignment.center] }
        } else {
            if hasText { bubble().alignmentGuide(.bubbleCenter) { $0[VerticalAlignment.center] } }
            if let card { LinkCard(url: card) }
        }
    }
}

/// Renders nothing until the preview has loaded; loading is triggered by the message row (`MessageRow.previewURL`).
/// Compact layout: small thumbnail beside title + site. A direct image link shows just the image.
struct LinkCard: View {
    @ObservedObject private var store = LinkPreviewStore.shared
    let url: URL

    static let width: CGFloat = 250
    static let thumb: CGFloat = 52

    var body: some View {
        if let p = store.displayable(url) {
            Button { NSWorkspace.shared.open(url) } label: {
                Group {
                    if p.title.isEmpty, let img = p.image {
                        Image(nsImage: img).resizable().scaledToFill().frame(width: Self.width, height: 130).clipped()
                    } else {
                        compact(p)
                    }
                }
                .background(Color.secondary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(url.absoluteString)
        }
    }

    private func compact(_ p: LinkPreviewStore.Preview) -> some View {
        HStack(spacing: 9) {
            if let img = p.image ?? p.icon {
                Image(nsImage: img).resizable().scaledToFill()
                    .frame(width: Self.thumb, height: Self.thumb).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(p.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                    .foregroundStyle(.primary).multilineTextAlignment(.leading)
                HStack(spacing: 4) {
                    if p.image != nil, let ic = p.icon {
                        Image(nsImage: ic).resizable().frame(width: 11, height: 11)
                            .clipShape(RoundedRectangle(cornerRadius: 2.5))
                    }
                    Text(p.host).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(7)
        .frame(width: Self.width, alignment: .leading)
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
            if !message.isLocal {
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
            }
            if !message.text.isEmpty {
                row("Copy text", "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.text, forType: .string)
                }
            }
            if let m = message.media.first {
                row("Save attachment…", "square.and.arrow.down") { model.saveMedia(m) }
                row("Share attachment…", "square.and.arrow.up") {
                    Task {
                        guard let url = await model.temporaryFile(for: m) else { model.errorMessage = "Couldn't download the attachment."; return }
                        SharePresenter.share(url)
                    }
                }
            }
            if message.state == .failed { row("Try again", "arrow.clockwise") { model.retry(message, in: conversation) } }
            Divider()
            row("Delete", "trash", destructive: true) { model.delete(message) }
        }
        .padding(.top, message.isLocal ? 6 : 0)
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
