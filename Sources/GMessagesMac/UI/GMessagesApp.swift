import SwiftUI
import AppKit
import UserNotifications

/// Notifications need a real .app bundle; a bare SwiftPM executable (Xcode's default run) crashes if it touches them.
enum AppEnv {
    static var canNotify: Bool { Bundle.main.bundleURL.pathExtension == "app" }
}

/// Closing the window hides it instead of destroying it, so a Dock click (or notification) can bring it back,
/// like Apple's Messages. Forwards everything else to SwiftUI's own window delegate.
final class WindowHider: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); return false }
    override func responds(to aSelector: Selector!) -> Bool { super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false) }
    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        (original?.responds(to: aSelector) ?? false) ? original : super.forwardingTarget(for: aSelector)
    }
}

enum MainWindow {
    static weak var window: NSWindow?
    static let hider = WindowHider()
    static func show() {
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
            MainWindow.window = w
            if w.delegate !== MainWindow.hider { MainWindow.hider.original = w.delegate; w.delegate = MainWindow.hider }
            w.isReleasedWhenClosed = false
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if AppEnv.canNotify { UNUserNotificationCenter.current().delegate = self }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindow.show()
        return true
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive r: UNNotificationResponse) async {
        if let id = r.notification.request.content.userInfo["conversationID"] as? String {
            await MainActor.run { NotificationCenter.default.post(name: .openConversation, object: id); MainWindow.show() }
        }
    }
}

extension Notification.Name { static let openConversation = Notification.Name("openConversation") }

@main
struct GMessagesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Goob Message") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 520)
                .background(WindowAccessor())
                .task { await model.start() }
                .onReceive(NotificationCenter.default.publisher(for: .openConversation)) { n in
                    if let id = n.object as? String { model.select(id) }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Message") { NotificationCenter.default.post(name: .newMessage, object: nil) }
                    .keyboardShortcut("n")
            }
            CommandGroup(after: .windowArrangement) {
                Button("Show Messages") { MainWindow.show() }.keyboardShortcut("0")
            }
            CommandMenu("Conversation") {
                Button("Previous Conversation") { model.selectAdjacent(-1) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Next Conversation") { model.selectAdjacent(1) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
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
}
