import Foundation

nonisolated enum OpenAICodexBackend {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let authorizeURL = URL(string: "https://auth.openai.com/oauth/authorize")!
    static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    static let redirectURI = "http://localhost:1455/auth/callback"
    static let scope = "openid profile email offline_access"
    static let originator = "codex_cli_rs"
    static let backendBaseURL = URL(string: "https://chatgpt.com/backend-api/codex/")!
    static let modelsURL = URL(string: "https://chatgpt.com/backend-api/codex/models")!
    static let responsesLiteHeader = "X-OpenAI-Internal-Codex-Responses-Lite"
    static var modelCatalogClientVersion: String {
        CodexCLIClient.bundledVersion() ?? "0.142.5"
    }
    static var userAgent: String {
        "\(originator)/\(modelCatalogClientVersion)"
    }
    static let modelIdentifierPrefix = "codex:"

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
    var usesResponsesLite = false
}

extension ModelConfig {
    var isOpenAICodexModel: Bool {
        OpenAICodexBackend.rawCodexModelIdentifier(from: identifier) != nil
    }

    var openAICodexRawIdentifier: String? {
        OpenAICodexBackend.rawCodexModelIdentifier(from: identifier)
    }
}
