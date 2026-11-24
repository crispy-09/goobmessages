import SwiftUI
import AppKit
import UserNotifications

enum AppEnv {
    /// True when running as a real .app (built with scripts/make_app.sh). A bare SwiftPM executable (Xcode's default
    /// run) has no bundle identity, and notifications, login items and microphone access crash or fail without one.
    static var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }
    static var canNotify: Bool { isBundled }
}

/// Closing the window hides it instead of destroying it, so a Dock click (or notification) can bring it back,
/// like Apple's Messages. Forwards everything else to SwiftUI's own window delegate.
final class WindowHider: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        AppPresence.update()
        return false
    }
    override func responds(to aSelector: Selector!) -> Bool { super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false) }
    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        (original?.responds(to: aSelector) ?? false) ? original : super.forwardingTarget(for: aSelector)
    }
}

enum MainWindow {
    static weak var window: NSWindow?
    static let hider = WindowHider()
    static func show() {
        AppPresence.update(showingWindow: true)
        NSApp.activate(ignoringOtherApps: true)
        guard let w = window else { return }
        if w.isMiniaturized { w.deminiaturize(nil) }
        w.makeKeyAndOrderFront(nil)
    }
}

struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window, MainWindow.window !== w else { return }
            let first = MainWindow.window == nil
            MainWindow.window = w
            if w.delegate !== MainWindow.hider { MainWindow.hider.original = w.delegate; w.delegate = MainWindow.hider }
            w.isReleasedWhenClosed = false
            // "Start in background": the window (and RootView's .task that connects) is created, then hidden at once.
            if first, Prefs.startInBackground { w.orderOut(nil) }
            AppPresence.update()
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Switches between a regular app (Dock icon + menu bar) and a background accessory app according to
/// `Prefs.dockIconMode` and whether any real window (main window, Settings) is open.
enum AppPresence {
    private static var observers: [NSObjectProtocol] = []

    static func install() {
        let nc = NotificationCenter.default
        let names: [Notification.Name] = [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification,
                                          NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification]
        // Async: on willClose the window is still visible.
        observers = names.map { nc.addObserver(forName: $0, object: nil, queue: .main) { _ in DispatchQueue.main.async { update() } } }
    }

    private static var hasOpenWindow: Bool {
        NSApp.windows.contains { w in
            !(w is NSPanel) && w.styleMask.contains(.titled) && (w.isVisible || w.isMiniaturized)
        }
    }

    static func update(showingWindow: Bool = false) {
        let wantDock = Prefs.dockIconMode.showsDockIcon(hasOpenWindow: showingWindow || hasOpenWindow)
        let policy: NSApplication.ActivationPolicy = wantDock ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Without this the menu bar can stay on the previous app after becoming .regular again.
        if wantDock, showingWindow || NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let background = Prefs.startInBackground
        NSApp.setActivationPolicy(Prefs.dockIconMode.showsDockIcon(hasOpenWindow: !background) ? .regular : .accessory)
        if !background { NSApp.activate(ignoringOtherApps: true) }
        AppPresence.install()
        StatusItemController.shared.install(model: AppModel.shared)
        if AppEnv.canNotify { UNUserNotificationCenter.current().delegate = self }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock click, or launching the app again from Finder/Spotlight (the way back when there is no Dock/menu bar icon).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindow.show()
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    /// Banner tapped, or one of its actions (Reply / Mark as Read) used.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let cid = response.notification.request.content.userInfo["conversationID"] as? String
        let typed = (response as? UNTextInputNotificationResponse)?.userText
        await MainActor.run {
            let model = AppModel.shared
            switch action {
            case NotificationCoordinator.replyAction:
                if let cid, let typed { Task { await model.replyFromNotification(conversationID: cid, text: typed) } }
            case NotificationCoordinator.markReadAction:
                if let cid { model.markConversationRead(cid) }
            default:
                if let cid { model.select(cid) }
                MainWindow.show()
            }
        }
    }
}

@main
struct GMessagesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup("Goob Message") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 520)
                .background(WindowAccessor())
                .task { await model.start() }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Message") { MainWindow.show(); NotificationCenter.default.post(name: .newMessage, object: nil) }
                    .keyboardShortcut("n")
            }
            CommandGroup(after: .windowArrangement) {
                Button("Show Messages") { MainWindow.show() }.keyboardShortcut("0")
            }
            CommandMenu("Conversation") {
                Button("Previous Conversation") { model.selectAdjacent(-1) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Next Conversation") { model.selectAdjacent(1) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Divider()
                Button("Find in Conversation") { NotificationCenter.default.post(name: .findInConversation, object: nil) }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                    .disabled(model.selectedID == nil)
                Button("Mark All as Read") { model.markAllRead() }
                    .disabled(model.unreadConversations.isEmpty)
                Divider()
                Button("Reload Conversations") { Task { await model.reload() } }.keyboardShortcut("r")
            }
            CommandGroup(after: .textEditing) {
                Button("Search Conversations") { NotificationCenter.default.post(name: .focusSearch, object: nil) }
                    .keyboardShortcut("f")
            }
        }

        Settings { SettingsView().environmentObject(model) }

    }
}

extension Notification.Name {
    static let newMessage = Notification.Name("newMessage")
    static let focusSearch = Notification.Name("focusSearch")
    static let findInConversation = Notification.Name("findInConversation")
}
