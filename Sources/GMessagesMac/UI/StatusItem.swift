import AppKit
import Combine

/// Menu bar icon. A plain click opens the main window; right-click (or Control-click) shows a menu with unread
/// conversations, New Message, Settings and Quit. Uses NSStatusItem directly because SwiftUI's MenuBarExtra
/// always opens a menu on click.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    static let shared = StatusItemController()

    private var item: NSStatusItem?
    private weak var model: AppModel?
    private var cancellables: Set<AnyCancellable> = []
    private var lastUnread = -1

    func install(model: AppModel) {
        self.model = model
        // Coalesce: conversations change often during sync; the label only needs the unread count.
        model.$conversations
            .map { $0.filter(\.unread).count }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] n in self?.updateLabel(unread: n) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncVisibility() }
            .store(in: &cancellables)
        syncVisibility()
    }

    private func syncVisibility() {
        let want = Prefs.showMenuBarIcon
        if want, item == nil {
            let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            it.button?.target = self
            it.button?.action = #selector(clicked(_:))
            it.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            it.button?.toolTip = "Goob Message"
            item = it
            lastUnread = -1
            updateLabel(unread: model?.unreadConversations.count ?? 0)
        } else if !want, let it = item {
            NSStatusBar.system.removeStatusItem(it)
            item = nil
        }
    }

    private func updateLabel(unread n: Int) {
        guard let button = item?.button, n != lastUnread else { return }
        lastUnread = n
        let image = NSImage(systemSymbolName: n > 0 ? "bubble.left.fill" : "bubble.left",
                            accessibilityDescription: "Goob Message")
        image?.isTemplate = true
        button.image = image
        button.imagePosition = n > 0 ? .imageLeading : .imageOnly
        button.title = n > 0 ? "\(n)" : ""
        button.setAccessibilityLabel(n > 0 ? "Goob Message, \(n) unread" : "Goob Message")
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if wantsMenu { showMenu() } else { MainWindow.show() }
    }

    private func showMenu() {
        guard let item else { return }
        let menu = buildMenu()
        menu.delegate = self
        item.menu = menu                 // attach only for this click so a plain click keeps opening the window
        item.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) { item?.menu = nil }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let unread = model?.unreadConversations ?? []
        if unread.isEmpty {
            let none = NSMenuItem(title: "No unread messages", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for c in unread.prefix(10) {
                let id = c.id
                menu.addItem(ActionItem("\(c.name): \(String(c.preview.prefix(48)))") { [weak self] in
                    self?.model?.select(id)
                    MainWindow.show()
                })
            }
            menu.addItem(.separator())
            menu.addItem(ActionItem("Mark All as Read") { [weak self] in self?.model?.markAllRead() })
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem("Open Goob Message") { MainWindow.show() })
        menu.addItem(ActionItem("New Message") {
            MainWindow.show()
            NotificationCenter.default.post(name: .newMessage, object: nil)
        })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Settings…") {
            AppPresence.update(showingWindow: true)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        })
        menu.addItem(ActionItem("Quit Goob Message") { NSApp.terminate(nil) })
        return menu
    }
}

/// NSMenuItem that runs a closure.
private final class ActionItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func run() { handler() }
}
