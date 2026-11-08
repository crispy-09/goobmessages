import SwiftUI

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var showNew = false

    var body: some View {
        NavigationSplitView {
            SidebarView(showNew: $showNew)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        } detail: {
            if let c = model.selected { ChatView(conversation: c).id(c.id) }
            else { Text("No Conversation Selected").font(.title3).foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.isOffline {
                Label("You're offline. Messages will sync when you reconnect.", systemImage: "wifi.slash")
                    .font(.callout).frame(maxWidth: .infinity).padding(6).background(Color.secondary.opacity(0.18))
            } else if let b = model.banner {
                Text(b).font(.callout).frame(maxWidth: .infinity).padding(6).background(.yellow.opacity(0.3))
            }
        }
        .sheet(isPresented: $showNew) { NewChatView() }
        .sheet(item: $model.viewing) { MediaViewer(item: $0) }
        .onReceive(NotificationCenter.default.publisher(for: .newMessage)) { _ in showNew = true }
    }
}

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @Binding var showNew: Bool
    @FocusState private var searchFocused: Bool
    @State private var pendingDelete: ConversationVM?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.showArchived ? "Archived" : "Messages").font(.title2.weight(.bold))
                Spacer()
                Button { model.showArchived.toggle() } label: { Image(systemName: model.showArchived ? "tray.full" : "archivebox") }
                    .buttonStyle(.plain).help("Toggle archived")
                Button { showNew = true } label: { Image(systemName: "square.and.pencil").font(.title3) }
                    .buttonStyle(.plain).foregroundStyle(Theme.blue).help("New message")
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $model.search).textFieldStyle(.plain).focused($searchFocused)
            }
            .padding(7).background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.07)))
            .padding(.horizontal, 12).padding(.bottom, 8)

            List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
                ForEach(model.filteredConversations) { c in
                    ConversationRow(conversation: c, selected: model.selectedID == c.id)
                        .tag(c.id)
                        .listRowSeparator(.hidden)
                        .contextMenu {
                            if c.unread { Button("Mark as Read") { model.markConversationRead(c.id) } }
                            Button(model.alertsHidden(c) ? "Show Alerts" : "Hide Alerts") { model.setAlertsHidden(c, !model.alertsHidden(c)) }
                            Divider()
                            Menu("On Your Phone") {
                                Button("Mute Notifications") { model.setMuted(c, true) }
                                Button("Unmute Notifications") { model.setMuted(c, false) }
                            }
                            Button(c.archived ? "Unarchive" : "Archive") { model.setArchived(c, !c.archived) }
                            Divider()
                            Button("Delete…", role: .destructive) { pendingDelete = c }
                        }
                        .onAppear { if c.id == model.filteredConversations.last?.id { Task { await model.loadMoreConversations() } } }
                }
            }
            .listStyle(.sidebar)
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in searchFocused = true }
        .confirmationDialog("Delete this conversation from your phone?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { c in
            Button("Delete", role: .destructive) { model.deleteConversation(c) }
        } message: { _ in
            Text("This deletes it in Google Messages on your phone too. It can't be undone.")
        }
    }
}

struct ConversationRow: View {
    @EnvironmentObject var model: AppModel
    let conversation: ConversationVM
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.blue).frame(width: 9, height: 9).opacity(conversation.unread ? 1 : 0)
            AvatarView(image: model.avatar(for: conversation), initials: conversation.initials, colorHex: conversation.colorHex, size: 42, symbol: conversation.isGroup ? "person.2.fill" : nil, collage: model.collage(for: conversation))
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(conversation.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if conversation.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary) }
                    if model.alertsHidden(conversation) { Image(systemName: "bell.slash.fill").font(.system(size: 9)).foregroundStyle(.secondary) }
                    Spacer()
                    Text(conversation.timestamp.sidebarString).font(.system(size: 11)).foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
                }
                Text(conversation.preview).font(.system(size: 12)).lineLimit(2)
                    .foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
