import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Multi-line, auto-growing text input backed by NSTextView.
/// Return sends; Shift+Return inserts a newline.
struct GrowingTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var maxHeight: CGFloat = 120
    var onSubmit: () -> Void
    var onChange: (String) -> Void
    var onPaste: (Data, String, String) -> Void = { _, _, _ in }

    static let font = NSFont.systemFont(ofSize: 14)
    static let verticalInset: CGFloat = 2
    /// Measured from the font, never hardcoded, so the empty and typed states are identical in height.
    static var singleLineHeight: CGFloat {
        ceil(NSLayoutManager().defaultLineHeight(for: font)) + verticalInset * 2
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero

        let tv = SubmitTextView()
        tv.delegate = context.coordinator
        tv.onSubmit = { context.coordinator.parent.onSubmit() }
        tv.onPaste = { d, n, m in context.coordinator.parent.onPaste(d, n, m) }
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = Self.font
        tv.textColor = .labelColor
        tv.insertionPointColor = .labelColor
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 0, height: Self.verticalInset)
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        scroll.documentView = tv
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text { tv.string = text }
        context.coordinator.recalc(tv)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingTextView
        init(_ p: GrowingTextView) { parent = p }

        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            parent.text = tv.string
            recalc(tv, immediate: true)
            parent.onChange(tv.string)
        }

        func recalc(_ tv: NSTextView, immediate: Bool = false) {
            guard let lm = tv.layoutManager, let tc = tv.textContainer, let font = tv.font else { return }
            lm.ensureLayout(for: tc)
            let line = ceil(lm.defaultLineHeight(for: font))
            let content = max(ceil(lm.usedRect(for: tc).height), line)
            let total = content + tv.textContainerInset.height * 2
            let h = min(total, parent.maxHeight)
            let overflowing = total > parent.maxHeight
            tv.enclosingScrollView?.hasVerticalScroller = overflowing
            // While everything fits, the text view grows a line before SwiftUI grows the frame, and NSTextView scrolls
            // the clip view to keep the caret visible: the text jumps up then back. Keep it pinned to the top instead.
            if !overflowing, let clip = tv.enclosingScrollView?.contentView, clip.bounds.origin != .zero {
                clip.scroll(to: .zero)
                tv.enclosingScrollView?.reflectScrolledClipView(clip)
            }
            guard abs(parent.height - h) > 0.5 else { return }
            if immediate { parent.height = h } else { DispatchQueue.main.async { self.parent.height = h } }
        }
    }
}

final class SubmitTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onPaste: ((Data, String, String) -> Void)?

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            for u in urls {
                guard let d = try? Data(contentsOf: u) else { continue }
                let mime = UTType(filenameExtension: u.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                onPaste?(d, u.lastPathComponent, mime)
            }
            return
        }
        if pb.string(forType: .string) == nil, let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            onPaste?(png, "Pasted Image.png", "image/png")
            return
        }
        super.paste(sender)
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // "Send with Return" on: Return sends, Shift/Option-Return adds a line. Off: Return adds a line, ⌘Return sends.
        let sends = Prefs.sendOnReturn ? mods.isDisjoint(with: [.shift, .option]) : mods.contains(.command)
        if isReturn, sends, !hasMarkedText() {
            onSubmit?()
        } else if isReturn, mods.contains(.option) || mods.contains(.shift) {
            insertNewlineIgnoringFieldEditor(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}
