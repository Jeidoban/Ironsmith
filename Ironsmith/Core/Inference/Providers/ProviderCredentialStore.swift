import Foundation
import Security

struct ProviderCredentialStore {
    nonisolated static let apiKeyAccessibility = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

    private let service = "com.ironsmith.provider-credentials"

    func saveAPIKey(_ apiKey: String, for reference: String) throws {
        let data = Data(apiKey.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: reference,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: Self.apiKeyAccessibility,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData] = data
            insert[kSecAttrAccessible] = Self.apiKeyAccessibility
            let insertStatus = SecItemAdd(insert as CFDictionary, nil)
            guard insertStatus == errSecSuccess else {
                throw CredentialStoreError.unhandledStatus(insertStatus)
            }
            return
        }

        guard status == errSecSuccess else {
            throw CredentialStoreError.unhandledStatus(status)
        }
    }

    func loadAPIKey(for reference: String) throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: reference,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw CredentialStoreError.unhandledStatus(status)
        }
        guard
            let data = result as? Data,
            let apiKey = String(data: data, encoding: .utf8)
        else {
            throw CredentialStoreError.invalidData
        }
        return apiKey
    }

    func deleteAPIKey(for reference: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: reference,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.unhandledStatus(status)
        }
    }
}

enum CredentialStoreError: Error, LocalizedError {
    case invalidData
    case unhandledStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "The stored API key could not be decoded."
        case .unhandledStatus(let status):
            return "Keychain operation failed with status \(status)."
        }
    }
}
