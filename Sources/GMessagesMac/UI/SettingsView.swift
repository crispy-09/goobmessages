import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            NotificationSettings().tabItem { Label("Notifications", systemImage: "bell.badge") }
            AccountSettings().tabItem { Label("Account", systemImage: "person.crop.circle") }
        }
        .frame(width: 480, height: 460)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Prefs.Key.sendOnReturn) private var sendOnReturn = true
    @AppStorage(Prefs.Key.linkPreviewMode) private var previewMode: LinkPreviewMode = Prefs.linkPreviewMode
    @AppStorage(Prefs.Key.showMenuBarIcon) private var showMenuBarIcon = false
    @AppStorage(Prefs.Key.dockIconMode) private var dockMode: DockIconMode = .always
    @AppStorage(Prefs.Key.startInBackground) private var startInBackground = false
    @State private var openAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $openAtLogin)
                    .disabled(!LoginItem.isAvailable)
                    .onChange(of: openAtLogin) { value in
                        guard value != LoginItem.isEnabled else { return }
                        loginError = LoginItem.set(value)
                        if loginError != nil { openAtLogin = LoginItem.isEnabled }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Toggle("Start in background", isOn: $startInBackground)
                Text("Connects and shows notifications at launch without opening the window.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Show in Dock", selection: $dockMode) {
                    ForEach(DockIconMode.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: dockMode) { _ in DispatchQueue.main.async { AppPresence.update() } }
                Toggle("Show in menu bar", isOn: $showMenuBarIcon)
                Text(presenceHint).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Send with Return", isOn: $sendOnReturn)
                Text(sendOnReturn ? "Shift-Return or Option-Return starts a new line." : "Return starts a new line. ⌘-Return sends.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Link previews", selection: $previewMode) {
                    ForEach(LinkPreviewMode.allCases) { Text($0.label).tag($0) }
                }
                Text("Previews load the linked page from your Mac, which lets the site (and whoever sent the link) see your IP address and that you opened the chat. Links you send always preview. Only public https links are fetched.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var presenceHint: String {
        var s = "Goob Message keeps running and notifying after you close its window; ⌘Q quits it."
        if dockMode != .always && !showMenuBarIcon {
            s += " With no Dock or menu bar icon, open it again from a notification, Spotlight or Finder."
        } else if showMenuBarIcon {
            s += " Click the menu bar icon to open the app; right-click it for unread conversations."
        }
        return s
    }
}

private struct NotificationSettings: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Prefs.Key.notificationsEnabled) private var enabled = true
    @AppStorage(Prefs.Key.notificationPreviews) private var previews = true
    @AppStorage(Prefs.Key.notificationSound) private var sound = true

    var body: some View {
        Form {
            Section {
                Toggle("Show notifications", isOn: $enabled)
                Toggle("Show message previews", isOn: $previews).disabled(!enabled)
                Toggle("Play sound", isOn: $sound).disabled(!enabled)
                Text("Messages that arrive in a burst, for example while your Mac was asleep, are combined into one notification per conversation, or a single summary.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Conversations with hidden alerts", value: "\(model.hiddenAlerts.count)")
                Button("Show Alerts for All Conversations") { model.showAllAlerts() }
                    .disabled(model.hiddenAlerts.isEmpty)
                Text("Hide alerts for a conversation from its right-click menu or the bell in its header. This only affects this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Open System Notification Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") { NSWorkspace.shared.open(url) }
                }
                if !AppEnv.canNotify {
                    Text("Notifications only work in the app built with scripts/make_app.sh, not when run from Xcode.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AccountSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var confirm = false

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return "Goob Message \(v)"
    }

    var body: some View {
        Form {
            Section {
                Text("Signed in with your Google account and paired with your Android phone. Your session is stored in the macOS Keychain on this Mac only.")
                    .foregroundStyle(.secondary)
                Button("Sign Out and Unpair…", role: .destructive) { confirm = true }
                    .disabled(model.phase != .ready)
            }
            Section {
                Text(version)
                Text("Unofficial client. It uses an undocumented Google API, so it may break when Google changes it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Sign out and unpair this Mac from your phone?", isPresented: $confirm) {
            Button("Sign Out", role: .destructive) { model.signOut() }
        }
    }
}
