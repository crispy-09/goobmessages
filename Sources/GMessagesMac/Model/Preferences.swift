import Foundation
import ServiceManagement

/// User preferences, stored in UserDefaults. Views bind with `@AppStorage(Prefs.Key.x)` using the same defaults
/// declared here, so there is a single source of truth and no extra observable object.
enum Prefs {
    enum Key {
        static let notificationsEnabled = "notificationsEnabled"
        static let notificationPreviews = "notificationPreviews"
        static let notificationSound = "notificationSound"
        static let linkPreviews = "linkPreviews"          // legacy Bool, read only to migrate into linkPreviewMode
        static let linkPreviewMode = "linkPreviewMode"
        static let sendOnReturn = "sendOnReturn"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let hiddenAlerts = "hiddenAlertConversationIDs"
    }

    private static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }

    static var notificationsEnabled: Bool { bool(Key.notificationsEnabled, default: true) }
    static var notificationPreviews: Bool { bool(Key.notificationPreviews, default: true) }
    static var notificationSound: Bool { bool(Key.notificationSound, default: true) }
    /// Default is `.contacts`: loading a preview contacts the linked server from this Mac, which tells whoever sent
    /// the link (e.g. spam) your IP address and that you opened it. Migrates the old on/off toggle.
    static var linkPreviewMode: LinkPreviewMode {
        if let raw = UserDefaults.standard.string(forKey: Key.linkPreviewMode), let m = LinkPreviewMode(rawValue: raw) { return m }
        return bool(Key.linkPreviews, default: true) ? .contacts : .off
    }
    static var sendOnReturn: Bool { bool(Key.sendOnReturn, default: true) }

    /// Conversations whose alerts are hidden on this Mac (like "Hide Alerts" in Apple Messages).
    /// Stored as opaque conversation IDs only, never names or numbers.
    static var hiddenAlerts: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Key.hiddenAlerts) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: Key.hiddenAlerts) }
    }
}

enum LinkPreviewMode: String, CaseIterable, Identifiable {
    case everyone, contacts, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .everyone: return "From everyone"
        case .contacts: return "From saved contacts"
        case .off: return "Off"
        }
    }

    /// Links you sent always preview (unless off): fetching them reveals nothing to anyone else.
    func allows(fromMe: Bool, senderIsContact: Bool) -> Bool {
        switch self {
        case .everyone: return true
        case .contacts: return fromMe || senderIsContact
        case .off: return false
        }
    }
}

/// "Open at Login" via ServiceManagement. Only works when running as a real .app bundle.
enum LoginItem {
    static var isAvailable: Bool { AppEnv.isBundled }

    static var isEnabled: Bool {
        guard isAvailable else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Returns an error message if the change failed.
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        guard isAvailable else { return "Open at Login needs the app built with scripts/make_app.sh." }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
