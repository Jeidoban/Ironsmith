import Foundation

struct CredentialClient {
    var loadAPIKey: (String) throws -> String?
    var saveAPIKey: (String, String) throws -> Void
    var deleteAPIKey: (String) throws -> Void
}

extension CredentialClient {
    static var live: Self {
        let store = ProviderCredentialStore()
        return Self(
            loadAPIKey: { reference in
                try store.loadAPIKey(for: reference)
            },
            saveAPIKey: { apiKey, reference in
                try store.saveAPIKey(apiKey, for: reference)
            },
            deleteAPIKey: { reference in
                try store.deleteAPIKey(for: reference)
            }
        )
    }
}
