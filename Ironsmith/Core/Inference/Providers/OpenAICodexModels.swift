import Foundation

nonisolated enum OpenAICodexBackend {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    static let backendBaseURL = URL(string: "https://chatgpt.com/backend-api/codex/")!
    static let modelsURL = URL(string: "https://chatgpt.com/backend-api/codex/models")!
    static var modelCatalogClientVersion: String {
        CodexCLIClient.bundledVersion() ?? "0.142.5"
    }
    static let modelIdentifierPrefix = "codex:"

    /*
     Legacy PKCE OAuth constants, commented out for reference only. Codex CLI now owns
     browser login and writes auth.json under Ironsmith's CODEX_HOME.

     static let issuerURL = URL(string: "https://auth.openai.com")!
     static let authorizeURL = URL(string: "https://auth.openai.com/oauth/authorize")!
     static let redirectURI = "http://localhost:1455/auth/callback"
     static let redirectPort: UInt16 = 1455
     static let redirectPath = "/auth/callback"
     */

    static func codexModelIdentifier(for rawIdentifier: String) -> String {
        "\(modelIdentifierPrefix)\(rawIdentifier)"
    }

    static func rawCodexModelIdentifier(from identifier: String) -> String? {
        guard identifier.hasPrefix(modelIdentifierPrefix) else { return nil }
        return String(identifier.dropFirst(modelIdentifierPrefix.count))
    }
}

nonisolated struct OpenAICodexCredential: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var idToken: String?
    var accountID: String?
    var email: String?

    var statusText: String {
        if let email, !email.isEmpty {
            return email
        }
        if accountID != nil {
            return "Signed in"
        }
        return "Connected"
    }
}

nonisolated struct OpenAICodexModel: Equatable, Sendable {
    var identifier: String
    var displayName: String
}

extension ModelConfig {
    var isOpenAICodexModel: Bool {
        OpenAICodexBackend.rawCodexModelIdentifier(from: identifier) != nil
    }

    var openAICodexRawIdentifier: String? {
        OpenAICodexBackend.rawCodexModelIdentifier(from: identifier)
    }
}
