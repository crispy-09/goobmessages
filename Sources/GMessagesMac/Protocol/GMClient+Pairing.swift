import Foundation
import CryptoKit
import SwiftProtobuf

/// State of an in-flight Google-account pairing handshake.
struct PairingSession {
    let uuid = UUID()
    let start = Date()
    let key = P256.KeyAgreement.PrivateKey()
    var destRegID: String
    var destPhoneID: UInt64
    var destUnknownInt: UInt64
    var lastSeen: Date
    var serverInit: Authentication_GaiaPairingResponseContainer?
    var initPayload = Data()
    var finishPayload = Data()
    var nextKey = Data()
}

private let encryptionKeyInfo = Data([130, 170, 85, 160, 211, 151, 248, 131, 70, 202, 28, 238, 141, 57, 9, 185,
                                      95, 19, 250, 125, 235, 29, 74, 179, 131, 118, 184, 37, 109, 168, 85, 16])

private final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func run(_ f: () -> Void) { lock.lock(); defer { lock.unlock() }; if !done { done = true; f() } }
}

extension GMClient {
    // MARK: Sign in with Google cookies

    private func baseSignInPayload() -> Authentication_SignInGaiaRequest {
        var p = Authentication_SignInGaiaRequest()
        p.authMessage.requestID = UUID().uuidString
        p.authMessage.network = GMConstants.googleNetwork
        p.authMessage.configVersion = GMConstants.configVersion
        p.inner.deviceID.unknownInt1 = 3
        p.inner.deviceID.deviceID = "messages-web-\(auth.sessionIDHex)"
        p.network = GMConstants.googleNetwork
        return p
    }

    private struct PrimaryDevice {
        var regID: String
        var unknownInt: UInt64
        var unknownTS: UInt64 = 0
        var lastSeen: Date = Date(timeIntervalSince1970: 0)
    }

    /// Exchanges the Google cookies for a tachyon token and the list of phones on the account.
    private func signInGaiaGetToken() async throws -> Authentication_SignInGaiaResponse {
        var p = baseSignInPayload()
        p.inner.someData.someData = auth.refreshKey.publicKeyDER
        let resp: Authentication_SignInGaiaResponse = try await call(GMConstants.signInGaiaURL, p, as: Authentication_SignInGaiaResponse.self)
        let device = resp.deviceData.deviceWrapper.device
        var lower = device
        lower.sourceID = device.sourceID.lowercased()
        setAuth { a in
            a.tachyonToken = resp.tokenData.tachyonAuthToken
            let micros = resp.tokenData.ttl == 0 ? Int64(24 * 3600 * 1_000_000) : resp.tokenData.ttl
            a.tachyonTTLMicros = micros
            a.tachyonExpiry = Date().addingTimeInterval(Double(micros) / 1_000_000)
            a.mobile = lower
            a.browser = device
        }
        return resp
    }

    private func gaiaPrimaryDevices() async throws -> [PrimaryDevice] {
        let resp = try await signInGaiaGetToken()
        var devices: [String: PrimaryDevice] = [:]
        var order: [String] = []
        for d in resp.deviceData.unknownItems2 where d.unknownInt4 == 1 {
            devices[d.destOrSourceUuid] = PrimaryDevice(regID: d.destOrSourceUuid, unknownInt: d.unknownBigInt7)
            order.append(d.destOrSourceUuid)
        }
        for d in resp.deviceData.unknownItems3 {
            if var pd = devices[d.destOrSourceUuid] {
                pd.lastSeen = Date(timeIntervalSince1970: Double(d.unknownTimestampMicroseconds) / 1_000_000)
                pd.unknownTS = d.item8.unknownTimestamp
                devices[d.destOrSourceUuid] = pd
            }
        }
        return order.compactMap { devices[$0] }.sorted { $0.lastSeen > $1.lastSeen }
    }

    // MARK: Pairing handshake

    /// Phase 1: contacts the phone and returns the emoji the user must pick on the phone.
    func startGaiaPairing() async throws -> (emoji: String, session: PairingSession) {
        guard auth.hasCookies else { throw GMError.notLoggedIn }
        var devices = try await gaiaPrimaryDevices()
        guard !devices.isEmpty else { throw GMError.noDevices }
        if auth.destPhoneID != 0 {
            devices.removeAll { $0.unknownTS != auth.destPhoneID }
            guard !devices.isEmpty else { throw GMError.phoneNotFound }
        }
        let dest = devices[0]
        setAuth { $0.destRegID = dest.regID }

        // Open the long-poll stream first so the phone's replies can reach us.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let once = Once()
            startLongPolling(loggedIn: false) { once.run { c.resume() } }
            Task { try? await Task.sleep(nanoseconds: 20_000_000_000); once.run { c.resume() } }
        }

        var ps = PairingSession(destRegID: dest.regID, destPhoneID: dest.unknownTS, destUnknownInt: dest.unknownInt, lastSeen: dest.lastSeen)
        let (initMsg, _) = try preparePayloads(&ps)

        let serverInit: Authentication_GaiaPairingResponseContainer
        do {
            serverInit = try await sendGaiaMessage(&ps, action: RPCAction.createGaiaPairingClientInit, payload: initMsg, timeout: 20)
        } catch GMError.phoneNotResponding {
            try? await cancelGaiaPairing(ps)
            throw GMError.pairingInitTimeout
        }
        do {
            let emoji = try processServerInit(&ps, serverInit)
            return (emoji, ps)
        } catch {
            try? await cancelGaiaPairing(ps)
            throw error
        }
    }

    /// Phase 2: waits for the user to confirm the emoji on the phone, then derives the session keys.
    func finishGaiaPairing(_ session: PairingSession) async throws {
        var ps = session
        let finishResp: Authentication_GaiaPairingResponseContainer
        do {
            finishResp = try await sendGaiaMessage(&ps, action: RPCAction.createGaiaPairingClientFinished,
                                                   payload: ps.finishPayload, timeout: 300)
        } catch {
            try? await cancelGaiaPairing(ps)
            throw error
        }
        if finishResp.finishErrorType != 0 {
            switch finishResp.finishErrorCode.rawValue {
            case 5: throw GMError.wrongEmoji
            case 7, 27: throw GMError.pairingCancelled
            case 2, 3, 6: throw GMError.pairingFailed("timed out (code \(finishResp.finishErrorType)/\(finishResp.finishErrorCode.rawValue))")
            default: throw GMError.pairingFailed("error \(finishResp.finishErrorType)/\(finishResp.finishErrorCode.rawValue)")
            }
        }
        let clientKey = GMKDF.hkdf(key: ps.nextKey, salt: encryptionKeyInfo, info: Data("client".utf8))
        let serverKey = GMKDF.hkdf(key: ps.nextKey, salt: encryptionKeyInfo, info: Data("server".utf8))
        var crypto = AESCTRHelper(aesKey: Data(), hmacKey: Data())
        switch ps.serverInit?.confirmedKeyDerivationVersion ?? 0 {
        case 0:
            crypto.aesKey = clientKey; crypto.hmacKey = serverKey
        case 1:
            var concat = encryptionKeyInfo
            if GMKDF.byteHash(clientKey) < GMKDF.byteHash(serverKey) { concat += clientKey + serverKey }
            else { concat += serverKey + clientKey }
            let h = Data(SHA256.hash(data: concat))
            crypto.aesKey = GMKDF.hkdf(key: h, salt: Data("Ditto salt 1".utf8), info: Data("Ditto info 1".utf8))
            crypto.hmacKey = GMKDF.hkdf(key: h, salt: Data("Ditto salt 2".utf8), info: Data("Ditto info 2".utf8))
        default:
            throw GMError.pairingFailed("unsupported key derivation version")
        }
        setAuth { a in
            a.requestCrypto = crypto
            a.pairingID = ps.uuid.uuidString
            a.destPhoneID = ps.destPhoneID
        }
    }

    func cancelGaiaPairing(_ ps: PairingSession) async throws {
        var p = SendParams(action: RPCAction.cancelGaiaPairing, data: nil)
        p.requestID = ps.uuid.uuidString
        p.dontEncrypt = true
        p.customTTL = 300 * 1_000_000
        p.messageType = RPCMessageType.gaia2
        try await sendNoResponse(p)
    }

    func unpairGaia() async throws {
        var req = Authentication_RevokeGaiaPairingRequest()
        req.pairingAttemptID = auth.pairingID
        try await sendNoResponse(SendParams(action: RPCAction.unpairGaiaPairing, data: req))
    }

    // MARK: helpers

    private func sendGaiaMessage(_ ps: inout PairingSession, action: Rpc_ActionType, payload: Data, timeout: TimeInterval) async throws -> Authentication_GaiaPairingResponseContainer {
        var c = Authentication_GaiaPairingRequestContainer()
        c.pairingAttemptID = ps.uuid.uuidString
        c.browserDetails = GMConstants.browserDetails
        c.startTimestamp = Int64(ps.start.timeIntervalSince1970 * 1000)
        c.data = payload
        var msgType = RPCMessageType.gaia2
        if action.rawValue == RPCAction.createGaiaPairingClientFinished.rawValue {
            msgType = RPCMessageType.bugleMessage
            c.privateApiconfirmation = "This is an undocumented API. Use or access of undocumented Google APIs without express authorization is prohibited per the Google API Terms of Service (https://developers.google.com/terms)."
        } else {
            c.proposedVerificationCodeVersion = 1
            c.proposedKeyDerivationVersion = 1
        }
        var p = SendParams(action: action, data: c)
        p.dontEncrypt = true
        p.customTTL = 300 * 1_000_000
        p.messageType = msgType
        let resp = try await send(p, timeout: timeout)
        guard let d = resp.data else { throw GMError.protocolError("gaia response had no data") }
        return try Authentication_GaiaPairingResponseContainer(serializedData: d.unencryptedData)
    }

    private func preparePayloads(_ ps: inout PairingSession) throws -> (Data, Data) {
        let pub = ps.key.publicKey.x963Representation   // 04 || X(32) || Y(32)
        var ec = Ukey_EcP256PublicKey()
        ec.x = Data([0]) + pub[1..<33]
        ec.y = Data([0]) + pub[33..<65]
        var pk = Ukey_GenericPublicKey()
        pk.type = Ukey_PublicKeyType(rawValue: 1)!   // EC_P256
        pk.ecP256PublicKey = ec

        var fin = Ukey_Ukey2ClientFinished()
        fin.publicKey = pk
        var finMsg = Ukey_Ukey2Message()
        finMsg.messageType = Ukey_Ukey2Message.TypeEnum(rawValue: 4)!   // CLIENT_FINISH
        finMsg.messageData = try fin.serializedData()
        let finish = try finMsg.serializedData()
        ps.finishPayload = finish

        var ci = Ukey_Ukey2ClientInit()
        ci.version = 1
        ci.random = randomBytes(32)
        var cc = Ukey_Ukey2ClientInit.CipherCommitment()
        cc.handshakeCipher = Ukey_Ukey2HandshakeCipher(rawValue: 100)!   // P256_SHA512
        cc.commitment = Data(SHA512.hash(data: finish))
        ci.cipherCommitments = [cc]
        ci.nextProtocol = "AES_256_CBC-HMAC_SHA256"
        var initMsg = Ukey_Ukey2Message()
        initMsg.messageType = Ukey_Ukey2Message.TypeEnum(rawValue: 2)!   // CLIENT_INIT
        initMsg.messageData = try ci.serializedData()
        let initBytes = try initMsg.serializedData()
        ps.initPayload = initBytes
        return (initBytes, finish)
    }

    private func processServerInit(_ ps: inout PairingSession, _ msg: Authentication_GaiaPairingResponseContainer) throws -> String {
        ps.serverInit = msg
        let um = try Ukey_Ukey2Message(serializedData: msg.data)
        guard um.messageType.rawValue == 3 else { throw GMError.pairingFailed("unexpected UKEY2 message type \(um.messageType.rawValue)") }
        let si = try Ukey_Ukey2ServerInit(serializedData: um.messageData)
        guard si.version == 1 else { throw GMError.pairingFailed("unexpected server init version \(si.version)") }
        guard si.handshakeCipher.rawValue == 100 else { throw GMError.pairingFailed("unexpected handshake cipher") }
        guard si.random.count == 32 else { throw GMError.pairingFailed("bad server random") }
        var x = si.publicKey.ecP256PublicKey.x, y = si.publicKey.ecP256PublicKey.y
        if x.count == 33 { guard x[x.startIndex] == 0 else { throw GMError.pairingFailed("bad key x") }; x = x.dropFirst() }
        if y.count == 33 { guard y[y.startIndex] == 0 else { throw GMError.pairingFailed("bad key y") }; y = y.dropFirst() }
        guard x.count == 32, y.count == 32 else { throw GMError.pairingFailed("bad key length") }
        let serverPub = try P256.KeyAgreement.PublicKey(x963Representation: Data([4]) + x + y)
        let dh = try ps.key.sharedSecretFromKeyAgreement(with: serverPub)
        let dhBytes = dh.withUnsafeBytes { Data($0) }
        let sharedSecret = Data(SHA256.hash(data: dhBytes))
        let authInfo = ps.initPayload + msg.data
        let v1Auth = GMKDF.hkdf(key: sharedSecret, salt: Data("UKEY2 v1 auth".utf8), info: authInfo)
        ps.nextKey = GMKDF.hkdf(key: sharedSecret, salt: Data("UKEY2 v1 next".utf8), info: authInfo)
        let authNumber = v1Auth.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        switch msg.confirmedVerificationCodeVersion {
        case 0: return PairingEmojis.v0[Int(authNumber) % PairingEmojis.v0.count]
        case 1: return PairingEmojis.v1[Int(authNumber) % PairingEmojis.v1.count]
        default: throw GMError.pairingFailed("unsupported verification code version")
        }
    }
}
