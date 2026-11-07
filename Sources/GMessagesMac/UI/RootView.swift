import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            switch model.phase {
            case .launching:
                ProgressView().controlSize(.large)
            case .needsLogin:
                WelcomeView()
            case .contactingPhone:
                StatusView(title: "Contacting your phone…", subtitle: "Open Google Messages on your phone and keep it online.", cancel: { model.cancelPairing() })
            case .confirmEmoji(let e):
                EmojiConfirmView(emoji: e)
            case .connecting:
                StatusView(title: "Connecting…", subtitle: nil, cancel: nil)
            case .ready:
                MainView()
            }
        }
        .alert("Goob Message", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.errorMessage ?? "") }
    }
}

struct StatusView: View {
    let title: String; let subtitle: String?; let cancel: (() -> Void)?
    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(title).font(.title3.weight(.semibold))
            if let s = subtitle { Text(s).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            if let c = cancel { Button("Cancel", action: c).padding(.top, 8) }
        }.padding(40)
    }
}

struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var showLogin = false
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "message.fill").font(.system(size: 64)).foregroundStyle(Theme.blueGradient)
            Text("Goob Message").font(.system(size: 30, weight: .bold))
            Text("Sign in with the Google account used on your Android phone, then confirm the emoji shown here on your phone.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 380)
            Button { showLogin = true } label: {
                Text("Sign in with Google").font(.headline).padding(.horizontal, 26).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).tint(Theme.blue)
        }
        .padding(40)
        .sheet(isPresented: $showLogin) {
            GoogleLoginSheet { cookies in
                showLogin = false
                if let cookies { Task { await model.signedIn(cookies: cookies) } }
            }
        }
    }
}

struct EmojiConfirmView: View {
    @EnvironmentObject var model: AppModel
    let emoji: String
    var body: some View {
        VStack(spacing: 18) {
            Text(emoji).font(.system(size: 96))
            Text("Tap this emoji on your phone").font(.title2.weight(.semibold))
            Text("Google Messages on your phone is asking you to confirm a pairing. Choose the emoji above to finish.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 360)
            ProgressView()
            Button("Cancel") { model.cancelPairing() }
        }.padding(40)
    }
}
