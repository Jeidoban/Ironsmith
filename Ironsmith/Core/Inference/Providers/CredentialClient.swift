import Foundation

nonisolated struct CredentialClient {
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

extension CredentialClient {
    nonisolated static let openAICodexCredentialReference = "provider.openai.codexOAuth"

    nonisolated func loadOpenAICodexCredential() throws -> OpenAICodexCredential? {
        guard let dataString = try loadAPIKey(Self.openAICodexCredentialReference) else {
            return nil
        }
        guard let data = dataString.data(using: .utf8) else {
            throw CredentialStoreError.invalidData
        }
        return try JSONDecoder().decode(OpenAICodexCredential.self, from: data)
    }

    nonisolated func saveOpenAICodexCredential(_ credential: OpenAICodexCredential) throws {
        let data = try JSONEncoder().encode(credential)
        guard let dataString = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.invalidData
        }
        try saveAPIKey(dataString, Self.openAICodexCredentialReference)
    }

    nonisolated func deleteOpenAICodexCredential() throws {
        try deleteAPIKey(Self.openAICodexCredentialReference)
    }
}
