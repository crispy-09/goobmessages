import Foundation
import ServiceManagement

/// User preferences, stored in UserDefaults. Views bind with `@AppStorage(Prefs.Key.x)` using the same defaults
/// declared here, so there is a single source of truth and no extra observable object.
enum Prefs {
    enum Key {
        static let notificationsEnabled = "notificationsEnabled"
        static let notificationPreviews = "notificationPreviews"
        static let notificationSound = "notificationSound"
        static let linkPreviews = "linkPreviews"
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
    static var linkPreviews: Bool { bool(Key.linkPreviews, default: true) }
    static var sendOnReturn: Bool { bool(Key.sendOnReturn, default: true) }

    /// Conversations whose alerts are hidden on this Mac (like "Hide Alerts" in Apple Messages).
    /// Stored as opaque conversation IDs only, never names or numbers.
    static var hiddenAlerts: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Key.hiddenAlerts) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: Key.hiddenAlerts) }
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
