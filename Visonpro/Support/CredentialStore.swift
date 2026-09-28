import Foundation
import Security
import StreamingCore

enum CredentialStore {
    private static let service = "com.liaoke.Visonpro.whep"

    static func load(for endpoint: String) throws -> StreamCredential {
        var query = baseQuery(endpoint)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .none }
        guard status == errSecSuccess, let data = result as? Data else { throw StoreError(status: status) }
        return try JSONDecoder().decode(StreamCredential.self, from: data)
    }

    static func save(_ credential: StreamCredential, for endpoint: String) throws {
        let query = baseQuery(endpoint)
        if credential == .none {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError(status: status) }
            return
        }
        let data = try JSONEncoder().encode(credential)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StoreError(status: status) }
    }

    private static func baseQuery(_ endpoint: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: endpoint]
    }

    private struct StoreError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "无法访问安全凭据（Keychain \(status)）。请重新保存连接设置。" }
    }
}
