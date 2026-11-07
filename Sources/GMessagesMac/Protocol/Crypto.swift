import Foundation
import CryptoKit
import CommonCrypto

enum GMCryptoError: Error, LocalizedError {
    case tooShort, badHMAC, cipher(Int32), badKey, badChunk(Int)
    var errorDescription: String? {
        switch self {
        case .tooShort: return "Encrypted data too short"
        case .badHMAC: return "HMAC mismatch"
        case .cipher(let c): return "AES error \(c)"
        case .badKey: return "Invalid key"
        case .badChunk(let i): return "Failed to decrypt chunk \(i)"
        }
    }
}

func randomBytes(_ n: Int) -> Data {
    var d = Data(count: n)
    _ = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
    return d
}

/// AES-256-CTR (big-endian counter, same as Go's cipher.NewCTR).
private func aesCTR(key: Data, iv: Data, input: Data) throws -> Data {
    guard key.count == 32, iv.count == 16 else { throw GMCryptoError.badKey }
    var cryptor: CCCryptorRef?
    var status = key.withUnsafeBytes { k in
        iv.withUnsafeBytes { i in
            CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                                    CCPadding(ccNoPadding), i.baseAddress, k.baseAddress, key.count,
                                    nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
        }
    }
    guard status == kCCSuccess, let c = cryptor else { throw GMCryptoError.cipher(status) }
    defer { CCCryptorRelease(c) }
    var out = Data(count: input.count)
    var moved = 0
    status = out.withUnsafeMutableBytes { o in
        input.withUnsafeBytes { i in
            CCCryptorUpdate(c, i.baseAddress, input.count, o.baseAddress, input.count, &moved)
        }
    }
    guard status == kCCSuccess else { throw GMCryptoError.cipher(status) }
    return out
}

/// Encrypts requests to / decrypts responses from the phone.
/// Wire format: ciphertext || iv(16) || HMAC-SHA256(ciphertext || iv)
struct AESCTRHelper: Codable {
    var aesKey: Data
    var hmacKey: Data

    static func generate() -> AESCTRHelper { AESCTRHelper(aesKey: randomBytes(32), hmacKey: randomBytes(32)) }

    func encrypt(_ plaintext: Data) throws -> Data {
        let iv = randomBytes(16)
        var out = try aesCTR(key: aesKey, iv: iv, input: plaintext)
        out.append(iv)
        let mac = HMAC<SHA256>.authenticationCode(for: out, using: SymmetricKey(data: hmacKey))
        out.append(Data(mac))
        return out
    }

    func decrypt(_ data: Data) throws -> Data {
        guard data.count >= 48 else { throw GMCryptoError.tooShort }
        let d = Data(data) // re-base indices
        let sig = d.suffix(32)
        let body = d.prefix(d.count - 32)
        let expected = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: hmacKey))
        guard Data(expected) == Data(sig) else { throw GMCryptoError.badHMAC }
        let iv = Data(body.suffix(16))
        let ct = Data(body.prefix(body.count - 16))
        return try aesCTR(key: aesKey, iv: iv, input: ct)
    }
}

/// Chunked AES-256-GCM used for attachments: [0x00, log2(chunk)] then chunks of nonce(12)||ct||tag(16).
struct AESGCMMedia {
    let key: SymmetricKey
    init(keyData: Data) throws {
        guard keyData.count == 32 else { throw GMCryptoError.badKey }
        key = SymmetricKey(data: keyData)
    }

    private func aad(_ index: UInt32, last: Bool) -> Data {
        var d = Data([last ? 1 : 0])
        withUnsafeBytes(of: index.bigEndian) { d.append(contentsOf: $0) }
        return d
    }

    func decrypt(_ input: Data) throws -> Data {
        let data = Data(input)
        guard !data.isEmpty else { return data }
        guard data[0] == 0, data.count >= 2 else { throw GMCryptoError.badKey }
        if data.count == 2 { return Data() }          // header only: empty payload
        guard (10...24).contains(Int(data[1])) else { throw GMCryptoError.badKey }   // sane chunk sizes only
        var chunkSize = 1 << Int(data[1])
        let body = data.dropFirst(2)
        var out = Data()
        var index: UInt32 = 0
        var i = body.startIndex
        while i < body.endIndex {
            var last = false
            if i + chunkSize >= body.endIndex { chunkSize = body.endIndex - i; last = true }
            let chunk = body[i..<i + chunkSize]
            do {
                let box = try AES.GCM.SealedBox(combined: chunk)
                out.append(try AES.GCM.open(box, using: key, authenticating: aad(index, last: last)))
            } catch { throw GMCryptoError.badChunk(Int(index) + 1) }
            index += 1
            i += chunkSize
        }
        return out
    }

    func encrypt(_ data: Data) throws -> Data {
        let raw = 1 << 15
        let chunkSize = raw - 28
        var out = Data([0, 15])
        var index: UInt32 = 0
        var i = 0
        if data.isEmpty { return out }
        while i < data.count {
            let end = min(i + chunkSize, data.count)
            let last = end >= data.count
            let box = try AES.GCM.seal(data[i..<end], using: key, authenticating: aad(index, last: last))
            out.append(box.combined!)
            index += 1
            i = end
        }
        return out
    }
}

enum GMKDF {
    static func hkdf(key: Data, salt: Data, info: Data) -> Data {
        let k = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key), salt: salt, info: info, outputByteCount: 32)
        return k.withUnsafeBytes { Data($0) }
    }

    /// Java-style hash used by the key derivation v1 ordering step.
    static func byteHash(_ bytes: Data) -> Int32 {
        var out: Int32 = 1
        for b in bytes { out = out &* 31 &+ Int32(Int8(bitPattern: b)) }
        return out
    }
}

/// ECDSA P-256 key used to sign tachyon token refresh requests.
struct RefreshKey: Codable {
    var privateRaw: Data

    static func generate() -> RefreshKey { RefreshKey(privateRaw: P256.Signing.PrivateKey().rawRepresentation) }
    var privateKey: P256.Signing.PrivateKey { try! P256.Signing.PrivateKey(rawRepresentation: privateRaw) }
    /// DER SubjectPublicKeyInfo (what Go's x509.MarshalPKIXPublicKey produces).
    var publicKeyDER: Data { privateKey.publicKey.derRepresentation }

    func signASN1(_ message: Data) throws -> Data {
        // Go signs the SHA-256 digest of the message (prehashed ECDSA, ASN.1 DER output).
        let digest = SHA256.hash(data: message)
        return try privateKey.signature(for: digest).derRepresentation
    }
}

func sapisidHash(origin: String, sapisid: String) -> String {
    let ts = Int(Date().timeIntervalSince1970)
    let hash = Insecure.SHA1.hash(data: Data("\(ts) \(sapisid) \(origin)".utf8))
    return "SAPISIDHASH \(ts)_" + hash.map { String(format: "%02x", $0) }.joined()
}
