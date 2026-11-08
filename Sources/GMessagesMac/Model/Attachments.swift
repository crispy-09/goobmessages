import Foundation
import AppKit
import UniformTypeIdentifiers

/// A file waiting to be sent, already normalised for the phone.
struct OutgoingAttachment: Identifiable {
    let id = UUID()
    var data: Data
    var name: String
    var mime: String
    var preview: NSImage?
}

enum AttachmentPrep {
    static let maxBytes = 100 * 1024 * 1024
    /// Image types every Android phone renders; anything else (HEIC, TIFF, WebP, PSD…) is converted to JPEG.
    static let phoneFriendlyImages: Set<String> = ["image/jpeg", "image/jpg", "image/png", "image/gif"]

    static func mime(forFileName name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "m4a" { return "audio/mp4" }
        return normalizedMIME(UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream")
    }

    /// macOS reports some types under names the Messages protocol doesn't know.
    static func normalizedMIME(_ mime: String) -> String {
        switch mime.lowercased() {
        case "audio/x-m4a", "audio/m4a", "audio/aac-adts": return "audio/mp4"
        case "image/pjpeg": return "image/jpeg"
        case "audio/x-mpeg", "audio/mpeg3", "audio/x-mp3": return "audio/mpeg"
        case "text/x-vcard", "text/directory": return "text/vcard"
        default: return mime.lowercased()
        }
    }

    /// Returns nil when the file is too large.
    static func prepare(data: Data, name: String, mime: String) -> OutgoingAttachment? {
        guard !data.isEmpty, data.count <= maxBytes else { return nil }
        var outData = data
        var outMime = normalizedMIME(mime)
        var outName = name.isEmpty ? "Attachment" : name
        if outMime.hasPrefix("image/"), !phoneFriendlyImages.contains(outMime),
           let rep = NSBitmapImageRep(data: data),
           let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
            outData = jpeg
            outMime = "image/jpeg"
            let base = (outName as NSString).deletingPathExtension
            outName = (base.isEmpty ? "Image" : base) + ".jpg"
        }
        let preview = outMime.hasPrefix("image/") ? NSImage(data: outData) : nil
        return OutgoingAttachment(data: outData, name: outName, mime: outMime, preview: preview)
    }

    static func prepare(fileURL url: URL) -> OutgoingAttachment? {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxBytes { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return prepare(data: data, name: url.lastPathComponent, mime: mime(forFileName: url.lastPathComponent))
    }
}
