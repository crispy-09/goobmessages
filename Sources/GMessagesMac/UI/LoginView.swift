import SwiftUI
import WebKit

/// Presents Google's sign-in page. Once the user lands on messages.google.com with a valid session,
/// the cookies are captured and the sheet closes itself.
struct GoogleLoginSheet: View {
    var onDone: ([String: String]?) -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in to Google").font(.headline)
                Spacer()
                Button("Cancel") { onDone(nil) }
            }.padding(12)
            Divider()
            GoogleWebView(onDone: onDone)
        }
        .frame(width: 520, height: 680)
    }
}

struct GoogleWebView: NSViewRepresentable {
    var onDone: ([String: String]?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onDone) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()      // nothing lingers after we copy the cookies
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
        web.navigationDelegate = context.coordinator
        context.coordinator.web = web
        let url = URL(string: "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fmessages.google.com%2Fweb%2F")!
        web.load(URLRequest(url: url))
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onDone: ([String: String]?) -> Void
        weak var web: WKWebView?
        private var finished = false
        init(_ onDone: @escaping ([String: String]?) -> Void) { self.onDone = onDone }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !finished, let host = webView.url?.host, host == "messages.google.com" else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self, !self.finished else { return }
                let google = cookies.filter {
                    let d = $0.domain.hasPrefix(".") ? String($0.domain.dropFirst()) : $0.domain
                    return d == "google.com" || d.hasSuffix(".google.com")
                }
                var dict: [String: String] = [:]
                for c in google { dict[c.name] = c.value }
                guard dict["SAPISID"] != nil else { return }
                self.finished = true
                DispatchQueue.main.async { self.onDone(dict) }
            }
        }
    }
}
