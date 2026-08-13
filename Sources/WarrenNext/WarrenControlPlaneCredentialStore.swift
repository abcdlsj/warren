import Foundation
import Security

enum WarrenControlPlaneCredentialStore {
    private static let service = "com.abcdlsj.warren.control-plane"

    static func loadOrImport(
        environment: [String: String]
    ) -> (url: URL, hostID: String, credential: String)? {
        if let rawURL = environment["WARREN_CONTROL_PLANE_URL"],
           let url = validatedRelayURL(rawURL),
           let hostID = environment["WARREN_CONTROL_PLANE_HOST_ID"],
           UUID(uuidString: hostID) != nil,
           let credential = environment["WARREN_CONTROL_PLANE_HOST_TOKEN"],
           !credential.isEmpty {
            let canonicalHostID = hostID.lowercased()
            guard save(credential: credential, for: url, hostID: canonicalHostID) else { return nil }
            return (url, canonicalHostID, credential)
        }
        guard let rawURL = UserDefaults.standard.string(forKey: "controlPlane.url"),
              let url = validatedRelayURL(rawURL),
              let hostID = UserDefaults.standard.string(forKey: "controlPlane.hostID"),
              UUID(uuidString: hostID) != nil else { return nil }
        let canonicalHostID = hostID.lowercased()
        guard let credential = load(for: url, hostID: canonicalHostID) else { return nil }
        return (url, canonicalHostID, credential)
    }

    private static func save(credential: String, for url: URL, hostID: String) -> Bool {
        guard let data = credential.data(using: .utf8) else { return false }
        let account = keychainAccount(url: url, hostID: hostID)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { return false }
        UserDefaults.standard.set(url.absoluteString, forKey: "controlPlane.url")
        UserDefaults.standard.set(hostID, forKey: "controlPlane.hostID")
        return true
    }

    private static func load(for url: URL, hostID: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keychainAccount(url: url, hostID: hostID),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func keychainAccount(url: URL, hostID: String) -> String {
        "\(url.absoluteString)#\(hostID.lowercased())"
    }

    private static func validatedRelayURL(_ rawValue: String) -> URL? {
        guard let url = URL(string: rawValue),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "ws", "wss"].contains(scheme),
              url.host != nil else { return nil }
        return url
    }
}
