import Foundation

nonisolated struct OpenAICodexAuthClient {
    static let refreshWindow: TimeInterval = 30 * 60

    var credential: @Sendable () throws -> OpenAICodexCredential?
    var signIn: @Sendable () async throws -> OpenAICodexCredential
    var signOut: @Sendable () async throws -> Void
    var validCredential: @Sendable () async throws -> OpenAICodexCredential
    var discoverModels: @Sendable () async throws -> [OpenAICodexModel]
    var modelMetadata: @Sendable (String) async throws -> OpenAICodexModel? = { _ in nil }
}

extension OpenAICodexAuthClient {
    nonisolated static func live(
        pkceAuthClient: OpenAICodexPKCEAuthClient = .live(),
        authFileClient: CodexAuthFileClient = .live(),
        refreshCredential: @escaping @Sendable (OpenAICodexCredential) async throws -> OpenAICodexCredential = { credential in
            try await Self.refreshCredential(credential)
        }
    ) -> Self {
        let tokenStore = OpenAICodexTokenStore(
            authFileClient: authFileClient,
            refreshCredential: refreshCredential
        )
        let modelCatalog = OpenAICodexModelCatalog {
            let credential = try await tokenStore.validCredential()
            return try await Self.fetchModels(credential: credential)
        }

        return Self(
            credential: {
                try authFileClient.credential()
            },
            signIn: {
                let credential = try await pkceAuthClient.signIn()
                try authFileClient.saveCredential(credential)
                await modelCatalog.invalidate()
                return credential
            },
            signOut: {
                try authFileClient.deleteCredential()
                await modelCatalog.invalidate()
            },
            validCredential: {
                try await tokenStore.validCredential()
            },
            discoverModels: {
                try await modelCatalog.refresh()
            },
            modelMetadata: { identifier in
                try await modelCatalog.model(identifier: identifier)
            }
        )
    }

    nonisolated static var unconfigured: Self {
        Self(
            credential: { nil },
            signIn: { throw OpenAICodexAuthClientError.missingCredential },
            signOut: {},
            validCredential: { throw OpenAICodexAuthClientError.missingCredential },
            discoverModels: { throw OpenAICodexAuthClientError.missingCredential },
            modelMetadata: { _ in throw OpenAICodexAuthClientError.missingCredential }
        )
    }

    nonisolated static func refreshCredential(
        _ credential: OpenAICodexCredential
    ) async throws -> OpenAICodexCredential {
        guard let refreshToken = credential.refreshToken, !refreshToken.isEmpty else {
            throw OpenAICodexAuthClientError.missingRefreshToken
        }

        let response: OpenAICodexTokenResponse = try await tokenRequest(
            form: [
                "grant_type": "refresh_token",
                "client_id": OpenAICodexBackend.clientID,
                "refresh_token": refreshToken,
            ]
        )

        var refreshed = Self.credential(from: response)
        if refreshed.refreshToken == nil {
            refreshed.refreshToken = refreshToken
        }
        if refreshed.idToken == nil {
            refreshed.idToken = credential.idToken
        }
        if refreshed.accountID == nil {
            refreshed.accountID = credential.accountID
        }
        if refreshed.email == nil {
            refreshed.email = credential.email
        }
        return refreshed
    }

    nonisolated static func tokenRequest<T: Decodable>(
        form: [String: String]
    ) async throws -> T {
        var request = URLRequest(url: OpenAICodexBackend.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formURLEncodedBody(form)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAICodexAuthClientError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw OpenAICodexAuthClientError.requestFailed(
                statusCode: httpResponse.statusCode,
                message: String(data: data, encoding: .utf8) ?? "Invalid response"
            )
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    nonisolated private static func fetchModels(credential: OpenAICodexCredential) async throws -> [OpenAICodexModel] {
        var components = URLComponents(url: OpenAICodexBackend.modelsURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_version", value: OpenAICodexBackend.modelCatalogClientVersion)
        ]
        guard let url = components?.url else {
            throw OpenAICodexAuthClientError.invalidModelURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = RemoteModelClient.discoveryTimeout
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID = credential.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAICodexAuthClientError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw OpenAICodexAuthClientError.requestFailed(
                statusCode: httpResponse.statusCode,
                message: String(data: data, encoding: .utf8) ?? "Invalid response"
            )
        }

        return try decodeModels(data)
    }

    nonisolated static func decodeModels(_ data: Data) throws -> [OpenAICodexModel] {
        let root = try JSONSerialization.jsonObject(with: data)
        let entries = modelEntries(from: root)
        var seen = Set<String>()
        return entries.compactMap { entry in
            guard isSupportedCodexModel(entry.identifier) else {
                return nil
            }
            guard seen.insert(entry.identifier).inserted else {
                return nil
            }
            return entry
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    nonisolated private static func modelEntries(from value: Any) -> [OpenAICodexModel] {
        if let array = value as? [Any] {
            return array.flatMap(modelEntries(from:))
        }

        guard let object = value as? [String: Any] else {
            return []
        }

        if let data = object["data"] {
            return modelEntries(from: data)
        }
        if let models = object["models"] {
            return modelEntries(from: models)
        }

        guard let identifier = stringValue(in: object, keys: ["id", "slug", "model", "name"]) else {
            return []
        }

        let displayName =
            stringValue(in: object, keys: ["display_name", "displayName", "title", "label"])
            ?? identifier
        return [
            OpenAICodexModel(
                identifier: identifier,
                displayName: displayName,
                usesResponsesLite: object["use_responses_lite"] as? Bool ?? false
            )
        ]
    }

    nonisolated private static func stringValue(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    nonisolated private static func isSupportedCodexModel(_ identifier: String) -> Bool {
        let excludedTerms = [
            "audio",
            "dall-e",
            "embedding",
            "image",
            "moderation",
            "realtime",
            "speech",
            "transcribe",
            "tts",
            "video",
            "whisper",
        ]
        if excludedTerms.contains(where: { identifier.localizedCaseInsensitiveContains($0) }) {
            return false
        }

        return identifier.hasPrefix("gpt-")
            || identifier.hasPrefix("o")
    }

    nonisolated static func credential(from response: OpenAICodexTokenResponse) -> OpenAICodexCredential {
        let claims = OpenAICodexJWTClaims.bestClaims(
            idToken: response.idToken,
            accessToken: response.accessToken
        )
        let expiresAt = response.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
            ?? claims.expiresAt
        return OpenAICodexCredential(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresAt: expiresAt,
            idToken: response.idToken,
            accountID: claims.accountID,
            email: claims.email
        )
    }

    nonisolated private static func formURLEncodedBody(_ values: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
            .sorted { $0.name < $1.name }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }
}

actor OpenAICodexModelCatalog {
    private let fetchModels: @Sendable () async throws -> [OpenAICodexModel]
    private var cachedModels: [OpenAICodexModel]?

    init(fetchModels: @escaping @Sendable () async throws -> [OpenAICodexModel]) {
        self.fetchModels = fetchModels
    }

    func models() async throws -> [OpenAICodexModel] {
        if let cachedModels {
            return cachedModels
        }

        return try await refresh()
    }

    func refresh() async throws -> [OpenAICodexModel] {
        let models = try await fetchModels()
        cachedModels = models
        return models
    }

    func model(identifier: String) async throws -> OpenAICodexModel? {
        try await models().first { $0.identifier == identifier }
    }

    func invalidate() {
        cachedModels = nil
    }
}

private actor OpenAICodexTokenStore {
    private let authFileClient: CodexAuthFileClient
    private let refreshCredential: @Sendable (OpenAICodexCredential) async throws -> OpenAICodexCredential

    init(
        authFileClient: CodexAuthFileClient,
        refreshCredential: @escaping @Sendable (OpenAICodexCredential) async throws -> OpenAICodexCredential
    ) {
        self.authFileClient = authFileClient
        self.refreshCredential = refreshCredential
    }

    func validCredential() async throws -> OpenAICodexCredential {
        guard let credential = try authFileClient.credential() else {
            throw OpenAICodexAuthClientError.missingCredential
        }

        if let expiresAt = credential.expiresAt,
           expiresAt.timeIntervalSinceNow > OpenAICodexAuthClient.refreshWindow {
            return credential
        }

        let refreshed = try await refreshCredential(credential)
        try authFileClient.saveCredential(refreshed)
        return refreshed
    }
}

nonisolated struct OpenAICodexTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let expiresIn: Int?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiresIn = "expires_in"
    }
}

nonisolated struct OpenAICodexJWTClaims {
    var accountID: String?
    var email: String?
    var expiresAt: Date?

    static func bestClaims(idToken: String?, accessToken: String) -> Self {
        let idClaims = decode(token: idToken)
        let accessClaims = decode(token: accessToken)
        return Self(
            accountID: idClaims?.accountID ?? accessClaims?.accountID,
            email: idClaims?.email ?? accessClaims?.email,
            expiresAt: accessClaims?.expiresAt ?? idClaims?.expiresAt
        )
    }

    private static func decode(token: String?) -> Self? {
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 {
            payload.append("=")
        }

        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        let authClaims = object["https://api.openai.com/auth"] as? [String: Any]
        let accountID =
            object["chatgpt_account_id"] as? String
            ?? authClaims?["chatgpt_account_id"] as? String
            ?? (object["organizations"] as? [[String: Any]])?.first?["id"] as? String
        return Self(
            accountID: accountID,
            email: object["email"] as? String,
            expiresAt: unixTimestamp(from: object["exp"])
        )
    }

    private static func unixTimestamp(from value: Any?) -> Date? {
        guard let number = value as? NSNumber else {
            return nil
        }
        return Date(timeIntervalSince1970: number.doubleValue)
    }
}

nonisolated enum OpenAICodexAuthClientError: LocalizedError, Equatable {
    case invalidOAuthAuthorizationURL
    case invalidOAuthState
    case invalidAuthFile
    case invalidModelURL
    case invalidResponse
    case missingOAuthCode
    case missingCodexBinary(String)
    case missingCredential
    case missingRefreshToken
    case oauthSignInFailed(String)
    case requestFailed(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidOAuthAuthorizationURL:
            return "Could not create the ChatGPT sign-in URL."
        case .invalidOAuthState:
            return "ChatGPT sign-in returned an invalid state. Try signing in again."
        case .invalidAuthFile:
            return "Codex sign-in data is invalid. Sign in with ChatGPT again."
        case .invalidModelURL:
            return "Could not create the ChatGPT model list URL."
        case .invalidResponse:
            return "ChatGPT returned an invalid response."
        case .missingOAuthCode:
            return "ChatGPT sign-in did not return an authorization code."
        case .missingCodexBinary(let message):
            return message
        case .missingCredential:
            return "Sign in with ChatGPT before using Codex models."
        case .missingRefreshToken:
            return "Sign in with ChatGPT again before using Codex models."
        case .oauthSignInFailed(let message):
            return message.isEmpty ? "ChatGPT sign-in failed." : message
        case .requestFailed(let statusCode, let message):
            return "ChatGPT returned HTTP \(statusCode): \(message)"
        }
    }
}
