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
        guard let c = model.client else { failed = true; return }
        do {
            let data = try await c.downloadMedia(id: item.id, key: item.key)
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

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirm = false
    @AppStorage("linkPreviews") private var linkPreviews = true

    var body: some View {
        Form {
            Section("Account") {
                Text("Signed in via your Google account and paired with your Android phone.")
                    .foregroundStyle(.secondary)
                Button("Sign Out and Unpair…", role: .destructive) { confirm = true }
            }
            Section("Chat") {
                Toggle("Show link previews", isOn: $linkPreviews)
                Text("Previews load the linked page from your Mac, like iMessage does.").font(.caption).foregroundStyle(.secondary)
            }
            Section("About") {
                Text("Unofficial client. Uses an undocumented Google API, so it may break when Google changes it.")
                    .font(.caption).foregroundStyle(.secondary)
                if !AppEnv.canNotify {
                    Text("Notifications are available when run as GMessagesMac.app (see make_app.sh).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 380)
        .confirmationDialog("Sign out and unpair this Mac from your phone?", isPresented: $confirm) {
            Button("Sign Out", role: .destructive) { model.signOut() }
        }
    }
}
