import SwiftUI
import AVKit
import UniformTypeIdentifiers

/// Full-size attachment viewer: images, video/audio playback, or a save prompt for other files.
struct MediaViewer: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let item: MediaItem
    @State private var image: NSImage?
    @State private var player: AVPlayer?
    @State private var loading = true
    @State private var tempURL: URL?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(item.name.isEmpty ? "Attachment" : item.name).font(.headline).lineLimit(1)
                Spacer()
                Button("Save…") { model.saveMedia(item) }
                Button("Done") { player?.pause(); dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(12)
            Divider()
            ZStack {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit().padding(12)
                } else if let player {
                    VideoPlayer(player: player)
                } else if failed {
                    Label("Couldn't load this attachment.", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                } else if loading {
                    ProgressView()
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.fill").font(.system(size: 48)).foregroundStyle(.secondary)
                        Text("Preview isn't available. Use Save… to download it.").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 520, idealWidth: 760, minHeight: 400, idealHeight: 560)
        .task { await load() }
        .onDisappear {
            player?.pause(); player = nil
            if let u = tempURL { try? FileManager.default.removeItem(at: u) }   // don't leave decrypted media on disk
        }
    }

    private func load() async {
        do {
            guard let data = await model.mediaData(for: item) else { throw GMError.protocolError("download failed") }
            if item.isImage, let img = NSImage(data: data) {
                image = img
            } else if item.isVideo || item.isAudio {
                let ext = UTType(mimeType: item.mime)?.preferredFilenameExtension ?? (item.isVideo ? "mp4" : "m4a")
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("gmm-" + UUID().uuidString + "." + ext)
                guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw GMError.protocolError("temp write failed") }
                tempURL = url
                let p = AVPlayer(url: url)
                player = p
                p.play()
            }
            loading = false
        } catch {
            failed = true; loading = false
        }
    }
}
