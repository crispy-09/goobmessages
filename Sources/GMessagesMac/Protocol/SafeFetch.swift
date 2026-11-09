import Foundation

/// GET for URLs that come from message/conversation data (untrusted): link previews, group avatars.
/// Every hop (initial request + each redirect) must be https to a public host name that resolves only to public
/// addresses; bodies are streamed with a hard size cap. Callers should use a session without cookies.
enum SafeFetch {
    struct Response {
        var data: Data
        var http: HTTPURLResponse
        /// false when the body hit the cap and `allowTruncation` was set.
        var complete: Bool
    }

    static func get(_ request: URLRequest, session: URLSession, limit: Int, allowTruncation: Bool = false) async -> Response? {
        guard let url = request.url, URLSafety.isPublicHTTPS(url), let host = url.host,
              await resolvesToPublicAddresses(host) else { return nil }
        var req = request
        req.httpMethod = "GET"
        req.httpShouldHandleCookies = false

        guard let (bytes, resp) = try? await session.bytes(for: req, delegate: RedirectGuard.shared),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let final = http.url, URLSafety.isPublicHTTPS(final) else { return nil }
        if !allowTruncation, http.expectedContentLength > Int64(limit) { bytes.task.cancel(); return nil }

        var data = Data()
        data.reserveCapacity(min(limit, max(Int(clamping: http.expectedContentLength), 64 * 1024)))
        do {
            for try await b in bytes {
                data.append(b)
                if data.count >= limit {
                    bytes.task.cancel()
                    return allowTruncation ? Response(data: data, http: http, complete: false) : nil
                }
            }
        } catch { return nil }
        return Response(data: data, http: http, complete: true)
    }

    /// Headers that may follow a redirect to a different host. Everything else (API keys, client headers,
    /// origin/referer) is dropped so e.g. a Google URL redirecting elsewhere can't leak the web-client headers.
    static let crossHostHeaders: Set<String> = ["user-agent", "accept", "accept-language"]

    /// Applies the same checks as the original URL to each redirect hop.
    final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        static let shared = RedirectGuard()

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            guard let url = request.url, URLSafety.isPublicHTTPS(url), let host = url.host else {
                completionHandler(nil)
                return
            }
            let previousHost = task.currentRequest?.url?.host ?? task.originalRequest?.url?.host
            var next = request
            if previousHost?.lowercased() != host.lowercased() {
                next = URLRequest(url: url, cachePolicy: request.cachePolicy, timeoutInterval: request.timeoutInterval)
                for (k, v) in request.allHTTPHeaderFields ?? [:] where SafeFetch.crossHostHeaders.contains(k.lowercased()) {
                    next.setValue(v, forHTTPHeaderField: k)
                }
            }
            next.httpShouldHandleCookies = false
            Task { completionHandler(await SafeFetch.resolvesToPublicAddresses(host) ? next : nil) }
        }
    }

    /// Best-effort DNS check so public names pointing at private addresses (e.g. `127.0.0.1.nip.io`) are refused.
    /// (URLSession resolves again itself, so this does not fully defeat DNS rebinding, but it stops the simple cases.)
    static func resolvesToPublicAddresses(_ host: String) async -> Bool {
        await Task.detached(priority: .utility) { () -> Bool in
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var res: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, "443", &hints, &res) == 0, let first = res else { return false }
            defer { freeaddrinfo(first) }
            var sawAny = false
            var p: UnsafeMutablePointer<addrinfo>? = first
            while let ai = p {
                defer { p = ai.pointee.ai_next }
                guard let sa = ai.pointee.ai_addr else { continue }
                switch Int32(sa.pointee.sa_family) {
                case AF_INET:
                    let bytes = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                        withUnsafeBytes(of: sin.pointee.sin_addr) { Array($0) }
                    }
                    guard URLSafety.isPublicIPv4(bytes) else { return false }
                case AF_INET6:
                    let bytes = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                        withUnsafeBytes(of: sin6.pointee.sin6_addr) { Array($0) }
                    }
                    guard URLSafety.isPublicIPv6(bytes) else { return false }
                default:
                    return false
                }
                sawAny = true
            }
            return sawAny
        }.value
    }
}
