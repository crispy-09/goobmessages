import Foundation
import Security
import SwiftProtobuf

/// Everything needed to resume a session: Google cookies, the paired phone's identity,
/// the symmetric keys negotiated during pairing, and the current tachyon token.
struct AuthData: Codable {
    var requestCrypto: AESCTRHelper = .generate()
    var refreshKey: RefreshKey = .generate()
    var browserData: Data?          // serialized Authentication_Device
    var mobileData: Data?
    var tachyonToken: Data = Data()
    var tachyonExpiry: Date = .distantPast
    var tachyonTTLMicros: Int64 = 0
    var sessionID: String = UUID().uuidString   // replaced by deviceInfo.deviceID from /web/config
    var destRegID: String = ""
    var destPhoneID: UInt64 = 0
    var pairingID: String = ""
    var cookies: [String: String] = [:]

    var browser: GMDevice? {
        get { browserData.flatMap { try? GMDevice(serializedData: $0) } }
        set { browserData = try? newValue?.serializedData() }
    }
    var mobile: GMDevice? {
        get { mobileData.flatMap { try? GMDevice(serializedData: $0) } }
        set { mobileData = try? newValue?.serializedData() }
    }

    var hasCookies: Bool { !cookies.isEmpty }
    var isPaired: Bool { browser != nil && !destRegID.isEmpty && !pairingID.isEmpty }
    var authNetwork: String { GMConstants.googleNetwork }

    /// Hex of the session UUID bytes, as the web client sends it in the device id.
    var sessionIDHex: String { sessionID.replacingOccurrences(of: "-", with: "").lowercased() }

    mutating func clearPairing() {
        requestCrypto = .generate()
        refreshKey = .generate()
        browserData = nil; mobileData = nil
        tachyonToken = Data(); tachyonExpiry = .distantPast
        destRegID = ""; destPhoneID = 0; pairingID = ""
    }
}

enum Keychain {
    private static let service = "GMessagesMac.auth"
    private static let account = "default"

    static func save(_ auth: AuthData) {
        guard let data = try? JSONEncoder().encode(auth) else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load() -> AuthData? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(AuthData.self, from: d)
    }

    static func clear() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}
