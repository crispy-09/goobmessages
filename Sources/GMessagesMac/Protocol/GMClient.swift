import Foundation
import CryptoKit
import SwiftProtobuf

enum GMError: Error, LocalizedError {
    case notLoggedIn
    case http(Int, String)
    case noDevices
    case phoneNotFound
    case pairingInitTimeout
    case wrongEmoji
    case pairingCancelled
    case pairingFailed(String)
    case phoneNotResponding
    case connectionClosed
    case protocolError(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "Not signed in"
        case .http(let c, let b): return "HTTP \(c)\(b.isEmpty ? "" : ": " + b.prefix(200))"
        case .noDevices: return "No phone with Google Messages was found on this Google account."
        case .phoneNotFound: return "The previously paired phone wasn't found."
        case .pairingInitTimeout: return "Your phone didn't respond. Make sure Google Messages is open and online."
        case .wrongEmoji: return "The wrong emoji was selected on the phone."
        case .pairingCancelled: return "Pairing was cancelled on the phone."
        case .pairingFailed(let s): return "Pairing failed: \(s)"
        case .phoneNotResponding: return "Your phone isn't responding."
        case .connectionClosed: return "Connection closed."
        case .protocolError(let s): return s
        }
    }
}

enum GMEvent {
    case conversation(GMConversation)
    case message(GMMessage, isOld: Bool)
    case typing(GMTypingData)
    case settings(Settings_Settings)
    case userAlert(Int)
    case connected
    case listenError(String)
    case fatalAuthError(String)
    case phoneNotResponding
    case phoneResponding
    case loggedOut
    case authChanged
}

struct IncomingRPC {
    var raw: Rpc_IncomingRPCMessage
    var route: Int
    var data: Rpc_RPCMessageData?
    var gaia: Authentication_RPCGaiaData?
    var pair: Events_RPCPairData?
    var decrypted: Data?
}

struct SendParams {
    var action: Rpc_ActionType
    var data: (any SwiftProtobuf.Message)?
    var requestID: String?
    var omitTTL = false
    var customTTL: Int64 = 0
    var dontEncrypt = false
    var messageType: Rpc_MessageType = RPCMessageType.bugleMessage
    var userInitiated = false
}

private final class Waiter {
    var cont: CheckedContinuation<IncomingRPC, Error>?
    var result: Result<IncomingRPC, Error>?
    func deliver(_ r: Result<IncomingRPC, Error>) {
        guard result == nil else { return }
        result = r
        if let c = cont { cont = nil; c.resume(with: r) }
    }
}

actor GMClient {
    private(set) var auth: AuthData
    nonisolated let events: AsyncStream<GMEvent>
    private let eventCont: AsyncStream<GMEvent>.Continuation

    private let api: URLSession
    private let lpSession: URLSession

    private var rpcSessionID = UUID().uuidString
    private var waiters: [String: Waiter] = [:]
    private var ackQueue: [String] = []
    private var ackTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var longPollTask: Task<Void, Never>?
    private var listenID = 0
    private var skipCount = 0
    private var recentHashes: [String: String] = [:]
    private var recentOrder: [String] = []
    private var pingTimeouts = 0
    private var notRespondingSent = false
    private(set) var conversationsFetchedOnce = false
    var onFirstConnectDone = false
    private(set) var isConnected = false

    init(auth: AuthData) {
        self.auth = auth
        var cont: AsyncStream<GMEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        self.eventCont = cont
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 60
        api = URLSession(configuration: cfg)
        let lp = URLSessionConfiguration.ephemeral
        lp.httpCookieStorage = nil
        lp.httpShouldSetCookies = false
        lp.urlCache = nil
        lp.timeoutIntervalForRequest = 120      // idle timeout between stream chunks
        lp.timeoutIntervalForResource = 30 * 60
        lpSession = URLSession(configuration: lp)
    }

    func emit(_ e: GMEvent) { eventCont.yield(e) }
    func markConversationsFetched() { conversationsFetchedOnce = true }
    func setAuth(_ block: (inout AuthData) -> Void) { block(&auth); emit(.authChanged) }

    // MARK: - HTTP

    private func relayHeaders(_ req: inout URLRequest, contentType: String?, accept: String = "*/*") {
        req.setValue(GMConstants.secUA, forHTTPHeaderField: "sec-ch-ua")
        req.setValue(GMConstants.xUserAgent, forHTTPHeaderField: "x-user-agent")
        req.setValue(GMConstants.apiKey, forHTTPHeaderField: "x-goog-api-key")
        if let ct = contentType { req.setValue(ct, forHTTPHeaderField: "content-type") }
        req.setValue("?1", forHTTPHeaderField: "sec-ch-ua-mobile")
        req.setValue(GMConstants.userAgent, forHTTPHeaderField: "user-agent")
        req.setValue("\"Android\"", forHTTPHeaderField: "sec-ch-ua-platform")
        req.setValue(accept, forHTTPHeaderField: "accept")
        req.setValue(GMConstants.messagesBase, forHTTPHeaderField: "origin")
        req.setValue("cross-site", forHTTPHeaderField: "sec-fetch-site")
        req.setValue("cors", forHTTPHeaderField: "sec-fetch-mode")
        req.setValue("empty", forHTTPHeaderField: "sec-fetch-dest")
        req.setValue(GMConstants.messagesBase + "/", forHTTPHeaderField: "referer")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "accept-language")
    }

    private func addCookies(_ req: inout URLRequest) {
        guard !auth.cookies.isEmpty else { return }
        req.setValue(auth.cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        if let sapisid = auth.cookies["SAPISID"] {
            req.setValue(sapisidHash(origin: GMConstants.messagesBase, sapisid: sapisid), forHTTPHeaderField: "Authorization")
        }
    }

    private func absorbCookies(_ http: HTTPURLResponse) {
        guard let url = http.url else { return }
        var h: [String: String] = [:]
        for (k, v) in http.allHeaderFields { if let k = k as? String, let v = v as? String { h[k] = v } }
        var changed = false
        for c in HTTPCookie.cookies(withResponseHeaderFields: h, for: url) where auth.cookies[c.name] != c.value {
            auth.cookies[c.name] = c.value; changed = true
        }
        if changed { emit(.authChanged) }
    }

    private func post(_ url: String, body: Data, contentType: String) async throws -> (Data, HTTPURLResponse) {
        guard let u = URL(string: url) else { throw GMError.protocolError("bad url") }
        for attempt in 1... {
            var req = URLRequest(url: u)
            req.httpMethod = "POST"
            req.httpBody = body
            relayHeaders(&req, contentType: contentType)
            addCookies(&req)
            let (data, resp) = try await api.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw GMError.protocolError("no http response") }
            absorbCookies(http)
            if http.statusCode < 500 || attempt >= 3 { return (data, http) }
            try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
        }
        fatalError("unreachable")
    }

    /// Group icons are plain image URLs taken from conversation metadata (untrusted): public https only, no cookies,
    /// and the web-client headers are only sent to Google-owned hosts.
    func downloadAvatar(_ url: String) async throws -> Data {
        guard let u = URL(string: url), URLSafety.isPublicHTTPS(u) else { throw GMError.protocolError("avatar url rejected") }
        var req = URLRequest(url: u)
        if URLSafety.isGoogleOwned(u) {
            relayHeaders(&req, contentType: nil)
            req.setValue(nil, forHTTPHeaderField: "x-user-agent")
            req.setValue(nil, forHTTPHeaderField: "x-goog-api-key")
        } else {
            req.setValue(GMConstants.userAgent, forHTTPHeaderField: "user-agent")
        }
        let (data, resp) = try await api.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count < 20_000_000 else {
            throw GMError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, "downloading avatar")
        }
        return data
    }

    private func decodeResponse<M: SwiftProtobuf.Message>(_ data: Data, _ http: HTTPURLResponse) throws -> M {
        let ct = (http.value(forHTTPHeaderField: "Content-Type") ?? "").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        if ct == "application/x-protobuf" { return try M(serializedData: data) }
        return try PBLite.unmarshal(data)
    }

    /// POST a pblite-encoded message and decode the typed response.
    func call<Req: SwiftProtobuf.Message, Resp: SwiftProtobuf.Message>(_ url: String, _ req: Req, as type: Resp.Type) async throws -> Resp {
        let body = try PBLite.marshal(req)
        let (data, http) = try await post(url, body: body, contentType: "application/json+protobuf")
        guard (200..<300).contains(http.statusCode) else {
            throw GMError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try decodeResponse(data, http)
    }

    // MARK: - Config + token refresh

    /// Fetches /web/config, which tells us the session (device) UUID to use.
    func fetchConfig() async throws {
        guard let u = URL(string: GMConstants.configURL) else { return }
        var req = URLRequest(url: u)
        relayHeaders(&req, contentType: nil)
        req.setValue("same-origin", forHTTPHeaderField: "sec-fetch-site")
        req.setValue(nil, forHTTPHeaderField: "x-user-agent")
        req.setValue(nil, forHTTPHeaderField: "origin")
        addCookies(&req)
        let (data, resp) = try await api.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw GMError.protocolError("no response") }
        absorbCookies(http)
        guard (200..<300).contains(http.statusCode) else { throw GMError.http(http.statusCode, "") }
        let config: Config_Config = try decodeResponse(data, http)
        let id = config.deviceInfo.deviceID
        if !id.isEmpty, UUID(uuidString: id) != nil { auth.sessionID = id; emit(.authChanged) }
    }

    private func updateTachyonToken(_ t: Authentication_TokenData) {
        auth.tachyonToken = t.tachyonAuthToken
        let micros = t.ttl == 0 ? Int64(24 * 3600 * 1_000_000) : t.ttl
        auth.tachyonTTLMicros = micros
        auth.tachyonExpiry = Date().addingTimeInterval(Double(micros) / 1_000_000)
        emit(.authChanged)
    }

    func refreshAuthToken(force: Bool = false) async throws {
        guard auth.browser != nil else { return }
        if !force && auth.tachyonExpiry.timeIntervalSinceNow > 3600 { return }
        let requestID = UUID().uuidString
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000) * 1000
        let sig = try auth.refreshKey.signASN1(Data("\(requestID):\(timestamp)".utf8))

        var payload = Authentication_RegisterRefreshRequest()
        payload.messageAuth = makeAuth(requestID: requestID)
        payload.currBrowserDevice = auth.browser!
        payload.unixTimestamp = timestamp
        payload.signature = sig
        payload.parameters.emptyArr = Util_EmptyArr()
        payload.messageType = 2
        let resp: Authentication_RegisterRefreshResponse = try await call(GMConstants.registerRefreshURL, payload, as: Authentication_RegisterRefreshResponse.self)
        guard !resp.tokenData.tachyonAuthToken.isEmpty else { throw GMError.protocolError("no tachyon token in refresh response") }
        updateTachyonToken(resp.tokenData)
    }

    func makeAuth(requestID: String = UUID().uuidString) -> GMAuthMessage {
        var a = GMAuthMessage()
        a.requestID = requestID
        a.tachyonAuthToken = auth.tachyonToken
        a.network = auth.authNetwork
        a.configVersion = GMConstants.configVersion
        return a
    }

    // MARK: - Connection lifecycle

    func connect() async throws {
        guard auth.hasCookies, auth.isPaired else { throw GMError.notLoggedIn }
        do { try await refreshAuthToken() } catch let e as GMError {
            if case .http(let c, _) = e, [401, 403, 404].contains(c) { throw e }
        }
        startLongPolling(loggedIn: true) { [weak self] in
            Task { await self?.postConnect() }
        }
        startAckLoop()
    }

    func disconnect() {
        listenID += 1
        longPollTask?.cancel(); longPollTask = nil
        ackTask?.cancel(); ackTask = nil
        pingTask?.cancel(); pingTask = nil
        isConnected = false
        for (_, w) in waiters { w.deliver(.failure(GMError.connectionClosed)) }
        waiters.removeAll()
    }

    func reconnect() async {
        disconnect()
        try? await Task.sleep(nanoseconds: 500_000_000)
        try? await connect()
    }

    private func postConnect() async {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        for _ in 0..<3 where skipCount > 0 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        await sendAcks()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        do { try await setActiveSession() } catch { emit(.listenError("Failed to set active session: \(error.localizedDescription)")) }
        isConnected = true
        emit(.connected)
        startPinger()
    }

    func setActiveSession() async throws {
        rpcSessionID = UUID().uuidString
        try await sendNoResponse(SendParams(action: RPCAction.getUpdates, data: nil, requestID: rpcSessionID, omitTTL: true))
    }

    // MARK: - RPC send

    private func buildMessage(_ p: SendParams) throws -> (String, Rpc_OutgoingRPCMessage) {
        let requestID = p.requestID ?? UUID().uuidString
        var m = Rpc_OutgoingRPCMessage()
        if let mobile = auth.mobile { m.mobile = mobile }
        m.data.requestID = requestID
        m.data.bugleRoute = Rpc_BugleRoute(rawValue: BugleRouteValue.dataEvent)!
        m.data.messageTypeData.emptyArr = Util_EmptyArr()
        m.data.messageTypeData.messageType = p.messageType
        m.auth.requestID = requestID
        m.auth.tachyonAuthToken = auth.tachyonToken
        m.auth.configVersion = GMConstants.configVersion
        if !auth.destRegID.isEmpty { m.destRegistrationIds = [auth.destRegID] }
        if p.customTTL != 0 { m.ttl = p.customTTL } else if !p.omitTTL { m.ttl = auth.tachyonTTLMicros }

        var inner = Rpc_OutgoingRPCData()
        inner.requestID = requestID
        inner.action = p.action
        inner.sessionID = rpcSessionID
        if let d = p.data {
            let ser = try d.serializedData()
            if p.dontEncrypt { inner.unencryptedProtoData = ser }
            else { inner.encryptedProtoData = try auth.requestCrypto.encrypt(ser) }
        }
        m.data.messageData = try inner.serializedData()
        return (requestID, m)
    }

    func sendNoResponse(_ p: SendParams) async throws {
        let (_, msg) = try buildMessage(p)
        let _: Rpc_OutgoingRPCResponse = try await call(GMConstants.sendMessageURL, msg, as: Rpc_OutgoingRPCResponse.self)
    }

    func send(_ p: SendParams, timeout: TimeInterval = 60) async throws -> IncomingRPC {
        let (requestID, msg) = try buildMessage(p)
        let waiter = Waiter()
        waiters[requestID] = waiter
        do {
            let _: Rpc_OutgoingRPCResponse = try await call(GMConstants.sendMessageURL, msg, as: Rpc_OutgoingRPCResponse.self)
        } catch {
            waiters[requestID] = nil
            throw error
        }
        return try await wait(waiter, id: requestID, timeout: timeout)
    }

    /// Typed RPC: send `request`, decode the decrypted response as `Resp`.
    func rpc<Resp: SwiftProtobuf.Message>(_ action: Rpc_ActionType, _ request: (any SwiftProtobuf.Message)?, as type: Resp.Type,
                                          messageType: Rpc_MessageType = RPCMessageType.bugleMessage, userInitiated: Bool = false) async throws -> Resp {
        var p = SendParams(action: action, data: request)
        p.messageType = messageType
        p.userInitiated = userInitiated
        let resp = try await send(p)
        guard let d = resp.decrypted else { return Resp() }
        return try Resp(serializedData: d)
    }

    private func wait(_ w: Waiter, id: String, timeout: TimeInterval) async throws -> IncomingRPC {
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if !Task.isCancelled { await self?.failWaiter(id, GMError.phoneNotResponding) }
        }
        defer { timer.cancel(); waiters[id] = nil }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<IncomingRPC, Error>) in
            if let r = w.result { c.resume(with: r) } else { w.cont = c }
        }
    }

    private func failWaiter(_ id: String, _ error: Error) {
        waiters.removeValue(forKey: id)?.deliver(.failure(error))
    }

    // MARK: - Acks

    private func queueAck(_ id: String) { if !ackQueue.contains(id) { ackQueue.append(id) } }

    private func startAckLoop() {
        ackTask?.cancel()
        ackTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await self?.sendAcks()
            }
        }
    }

    func sendAcks() async {
        guard !ackQueue.isEmpty else { return }
        let ids = ackQueue; ackQueue = []
        var req = Client_AckMessageRequest()
        req.authData = makeAuth()
        req.emptyArr = Util_EmptyArr()
        req.acks = ids.map { id in
            var a = Client_AckMessageRequest.Message()
            a.requestID = id
            if let b = auth.browser { a.device = b }
            return a
        }
        do { let _: Rpc_OutgoingRPCResponse = try await call(GMConstants.ackMessagesURL, req, as: Rpc_OutgoingRPCResponse.self) }
        catch { if ackQueue.count + ids.count <= 1024 { ackQueue = ids + ackQueue } }
    }

    // MARK: - Long polling

    func startLongPolling(loggedIn: Bool, onFirstConnect: (@Sendable () -> Void)? = nil) {
        listenID += 1
        let id = listenID
        longPollTask?.cancel()
        longPollTask = Task { [weak self] in
            await self?.longPollLoop(listenID: id, loggedIn: loggedIn, onFirstConnect: onFirstConnect)
        }
    }

    private func longPollLoop(listenID id: Int, loggedIn: Bool, onFirstConnect: (@Sendable () -> Void)?) async {
        var firstConnect = onFirstConnect
        var errorCount = 1
        let listenReqID = UUID().uuidString
        while id == listenID && !Task.isCancelled {
            do { try await refreshAuthToken() } catch {
                if case GMError.http(let c, _) = error, [401, 403, 404].contains(c) {
                    if loggedIn { emit(.fatalAuthError("Token refresh failed: \(error.localizedDescription)")) }
                    return
                }
                if loggedIn { emit(.listenError(error.localizedDescription)) }
                errorCount += 1
                try? await Task.sleep(nanoseconds: UInt64((errorCount + 1) * 5) * 1_000_000_000)
                continue
            }
            var payload = Client_ReceiveMessagesRequest()
            payload.auth = makeAuth(requestID: listenReqID)
            payload.unknown.unknown = Client_ReceiveMessagesRequest.UnknownEmptyObject1()
            do {
                let body = try PBLite.marshal(payload)
                var req = URLRequest(url: URL(string: GMConstants.receiveMessagesURL)!)
                req.httpMethod = "POST"
                req.httpBody = body
                req.timeoutInterval = 120
                relayHeaders(&req, contentType: "application/json+protobuf")
                addCookies(&req)
                let (bytes, resp) = try await lpSession.bytes(for: req)
                guard let http = resp as? HTTPURLResponse else { throw GMError.protocolError("no response") }
                absorbCookies(http)
                if http.statusCode == 401 || http.statusCode == 403 {
                    if loggedIn { emit(.fatalAuthError("Google rejected the session (HTTP \(http.statusCode)). Please sign in again.")) }
                    return
                } else if http.statusCode >= 400 {
                    throw GMError.http(http.statusCode, "")
                }
                guard id == listenID else { return }
                errorCount = 0
                if let f = firstConnect { firstConnect = nil; f() }
                try await readStream(bytes, listenID: id)
            } catch is CancellationError {
                return
            } catch {
                if id != listenID { return }
                if loggedIn { emit(.listenError(error.localizedDescription)) }
                errorCount += 1
                try? await Task.sleep(nanoseconds: UInt64(min((errorCount + 1) * 5, 60)) * 1_000_000_000)
            }
        }
    }

    /// Body is `[[` element (`,` element)* `]]`; each element is a complete pblite LongPollingPayload.
    private func readStream(_ bytes: URLSession.AsyncBytes, listenID id: Int) async throws {
        var opened = 0, depth = 0
        var inString = false, escape = false
        var buf: [UInt8] = []
        for try await b in bytes {
            if id != listenID { return }
            if opened < 2 {
                if b == UInt8(ascii: "[") { opened += 1 }
                continue
            }
            if depth == 0 {
                if b == UInt8(ascii: "[") { depth = 1; buf = [b] }
                continue // commas, whitespace, closing brackets between elements
            }
            buf.append(b)
            if buf.count > 64 * 1024 * 1024 { throw GMError.protocolError("stream element too large") }
            if inString {
                if escape { escape = false }
                else if b == UInt8(ascii: "\\") { escape = true }
                else if b == UInt8(ascii: "\"") { inString = false }
            } else if b == UInt8(ascii: "\"") { inString = true }
            else if b == UInt8(ascii: "[") { depth += 1 }
            else if b == UInt8(ascii: "]") {
                depth -= 1
                if depth == 0 {
                    let element = Data(buf); buf = []
                    handlePayload(element)
                }
            }
        }
    }

    private func handlePayload(_ element: Data) {
        guard let payload = try? PBLite.unmarshal(element, as: Rpc_LongPollingPayload.self) else { return }
        if payload.hasData {
            handleRPC(payload.data)
        } else if payload.hasAck {
            skipCount = Int(payload.ack.count)
        }
    }

    // MARK: - Incoming RPC

    private func decryptInternal(_ raw: Rpc_IncomingRPCMessage) throws -> IncomingRPC {
        var msg = IncomingRPC(raw: raw, route: raw.bugleRoute.rawValue)
        switch raw.bugleRoute.rawValue {
        case BugleRouteValue.pairEvent:
            msg.pair = try Events_RPCPairData(serializedData: raw.messageData)
        case BugleRouteValue.gaiaEvent:
            msg.gaia = try Authentication_RPCGaiaData(serializedData: raw.messageData)
        case BugleRouteValue.dataEvent:
            let md = try Rpc_RPCMessageData(serializedData: raw.messageData)
            msg.data = md
            if !md.encryptedData.isEmpty {
                msg.decrypted = try auth.requestCrypto.decrypt(md.encryptedData)
            } else if !md.encryptedData2.isEmpty {
                _ = try auth.requestCrypto.decrypt(md.encryptedData2) // account-change container; unused
            }
        default:
            throw GMError.protocolError("unknown bugle route \(raw.bugleRoute.rawValue)")
        }
        return msg
    }

    private func handleRPC(_ raw: Rpc_IncomingRPCMessage) {
        let msg: IncomingRPC
        do { msg = try decryptInternal(raw) } catch { queueAck(raw.responseID); return }
        queueAck(raw.responseID)
        if deliverResponse(msg) { return }
        switch msg.route {
        case BugleRouteValue.pairEvent:
            if case .revoked? = msg.pair?.event { emit(.loggedOut) }
        case BugleRouteValue.dataEvent:
            var old = false
            if skipCount > 0 { skipCount -= 1; old = true }
            if !old { phoneIsAlive() }
            handleUpdates(msg, isOld: old)
        default: break
        }
    }

    private func deliverResponse(_ msg: IncomingRPC) -> Bool {
        guard let d = msg.data else {
            // Gaia/pair events can also carry request responses during pairing; fall through below.
            return deliverGaia(msg)
        }
        let action = d.action.rawValue
        let isGaiaPairing = action == RPCAction.createGaiaPairingClientInit.rawValue || action == RPCAction.createGaiaPairingClientFinished.rawValue
        if auth.hasCookies, !isGaiaPairing, !d.unencryptedData.isEmpty, d.encryptedData.isEmpty { return false }
        guard let w = waiters.removeValue(forKey: d.sessionID) else { return false }
        if action != RPCAction.notifyDittoActivity.rawValue { phoneIsAlive() }
        w.deliver(.success(msg))
        return true
    }

    private func deliverGaia(_ msg: IncomingRPC) -> Bool { false }

    private func dedupe(id: String, data: Data?) -> Bool {
        guard let data else { return false }
        let h = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if recentHashes[id] == h { return true }
        recentHashes[id] = h
        recentOrder.append(id)
        if recentOrder.count > 128 { recentHashes[recentOrder.removeFirst()] = nil }
        return false
    }

    private func handleUpdates(_ msg: IncomingRPC, isOld: Bool) {
        guard let d = msg.data else { return }
        guard d.action.rawValue == RPCAction.getUpdates.rawValue else { return }
        if msg.decrypted == nil, Array(d.unencryptedData) == [0x72, 0x00] {
            Task { await self.sendAcks() }
            emit(.loggedOut)
            return
        }
        guard let bytes = msg.decrypted, let ev = try? GMUpdateEvents(serializedData: bytes) else { return }
        switch ev.event {
        case .conversationEvent(let ce)?:
            for c in ce.data {
                if dedupe(id: c.conversationID, data: msg.decrypted) { return }
                if !isOld { emit(.conversation(c)) }
            }
        case .messageEvent(let me)?:
            for m in me.data {
                if dedupe(id: m.messageID, data: msg.decrypted) { return }
                emit(.message(m, isOld: isOld))
            }
        case .typingEvent(let te)?:
            if !isOld { emit(.typing(te.data)) }
        case .settingsEvent(let s)?:
            emit(.settings(s))
        case .userAlertEvent(let a)?:
            if !isOld { emit(.userAlert(a.alertType.rawValue)) }
        case .browserPresenceCheckEvent?:
            Task { try? await self.sendNoResponse(SendParams(action: Rpc_ActionType(rawValue: 17)!, data: nil)) }
        default: break
        }
    }

    // MARK: - Liveness

    private func phoneIsAlive() {
        pingTimeouts = 0
        if notRespondingSent { notRespondingSent = false; emit(.phoneResponding) }
    }

    private func startPinger() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await self?.pingOnce()
            }
        }
    }

    private func pingOnce() async {
        var p = SendParams(action: RPCAction.notifyDittoActivity, data: nil)
        var req = Client_NotifyDittoActivityRequest(); req.success = true
        p.data = req
        do {
            _ = try await send(p, timeout: 60)
            if pingTimeouts >= 2 { try? await setActiveSession() }
            phoneIsAlive()
        } catch {
            pingTimeouts += 1
            if pingTimeouts >= 4, !notRespondingSent { notRespondingSent = true; emit(.phoneNotResponding) }
            if pingTimeouts >= 3 { startLongPolling(loggedIn: true) }
        }
    }
}
