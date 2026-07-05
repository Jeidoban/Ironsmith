import CryptoKit
import Foundation
@preconcurrency import Network

typealias OpenAICodexOAuthLaunchFlow = @MainActor @Sendable (_ url: URL) async throws -> Void

nonisolated struct OpenAICodexAuthClient {
    static let refreshWindow: TimeInterval = 5 * 60

    var credential: @Sendable () throws -> OpenAICodexCredential?
    var signIn: @Sendable (_ launchFlow: @escaping OpenAICodexOAuthLaunchFlow) async throws -> OpenAICodexCredential
    var signOut: @Sendable () throws -> Void
    var validCredential: @Sendable () async throws -> OpenAICodexCredential
    var discoverModels: @Sendable () async throws -> [OpenAICodexModel]
}

extension OpenAICodexAuthClient {
    static func live(credentialClient: CredentialClient) -> Self {
        let tokenStore = OpenAICodexTokenStore(credentialClient: credentialClient)

        return Self(
            credential: {
                try credentialClient.loadOpenAICodexCredential()
            },
            signIn: { launchFlow in
                let credential = try await Self.performBrowserSignIn(launchFlow: launchFlow)
                try credentialClient.saveOpenAICodexCredential(credential)
                return credential
            },
            signOut: {
                try credentialClient.deleteOpenAICodexCredential()
            },
            validCredential: {
                try await tokenStore.validCredential()
            },
            discoverModels: {
                let credential = try await tokenStore.validCredential()
                return try await Self.fetchModels(credential: credential)
            }
        )
    }

    static var unconfigured: Self {
        Self(
            credential: { nil },
            signIn: { _ in throw OpenAICodexAuthClientError.missingCredential },
            signOut: {},
            validCredential: { throw OpenAICodexAuthClientError.missingCredential },
            discoverModels: { throw OpenAICodexAuthClientError.missingCredential }
        )
    }

    private static func performBrowserSignIn(
        launchFlow: @escaping OpenAICodexOAuthLaunchFlow
    ) async throws -> OpenAICodexCredential {
        let pkce = try OpenAICodexPKCE()
        let state = OpenAICodexRandom.base64URLString(byteCount: 32)
        let callbackReceiver = OpenAICodexLoopbackOAuthReceiver(
            port: OpenAICodexBackend.redirectPort,
            path: OpenAICodexBackend.redirectPath,
            expectedState: state
        )
        let authorizeURL = try authorizationURL(pkce: pkce, state: state)

        let code = try await callbackReceiver.receiveCode {
            try await launchFlow(authorizeURL)
        }
        let tokenResponse = try await exchangeCodeForTokens(code: code, verifier: pkce.verifier)
        return credential(from: tokenResponse)
    }

    private static func authorizationURL(pkce: OpenAICodexPKCE, state: String) throws -> URL {
        var components = URLComponents(url: OpenAICodexBackend.authorizeURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: OpenAICodexBackend.clientID),
            URLQueryItem(name: "redirect_uri", value: OpenAICodexBackend.redirectURI),
            URLQueryItem(name: "scope", value: "openid profile email offline_access"),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: "ironsmith"),
        ]
        guard let url = components?.url else {
            throw OpenAICodexAuthClientError.invalidAuthorizationURL
        }
        return url
    }

    private static func exchangeCodeForTokens(
        code: String,
        verifier: String
    ) async throws -> OpenAICodexTokenResponse {
        try await tokenRequest(
            form: [
                "grant_type": "authorization_code",
                "client_id": OpenAICodexBackend.clientID,
                "code": code,
                "code_verifier": verifier,
                "redirect_uri": OpenAICodexBackend.redirectURI,
            ]
        )
    }

    static func refreshCredential(
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

    private static func tokenRequest<T: Decodable>(
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

    private static func fetchModels(credential: OpenAICodexCredential) async throws -> [OpenAICodexModel] {
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

    static func decodeModels(_ data: Data) throws -> [OpenAICodexModel] {
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

    private static func modelEntries(from value: Any) -> [OpenAICodexModel] {
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
        return [OpenAICodexModel(identifier: identifier, displayName: displayName)]
    }

    private static func stringValue(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    private static func isSupportedCodexModel(_ identifier: String) -> Bool {
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

    private static func credential(from response: OpenAICodexTokenResponse) -> OpenAICodexCredential {
        let claims = OpenAICodexJWTClaims.bestClaims(
            idToken: response.idToken,
            accessToken: response.accessToken
        )
        let expiresAt = response.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
        return OpenAICodexCredential(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresAt: expiresAt,
            idToken: response.idToken,
            accountID: claims.accountID,
            email: claims.email
        )
    }

    private static func formURLEncodedBody(_ values: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
            .sorted { $0.name < $1.name }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }
}

private actor OpenAICodexTokenStore {
    private let credentialClient: CredentialClient

    init(credentialClient: CredentialClient) {
        self.credentialClient = credentialClient
    }

    func validCredential() async throws -> OpenAICodexCredential {
        guard let credential = try credentialClient.loadOpenAICodexCredential() else {
            throw OpenAICodexAuthClientError.missingCredential
        }

        if let expiresAt = credential.expiresAt,
           expiresAt.timeIntervalSinceNow > OpenAICodexAuthClient.refreshWindow {
            return credential
        }

        let refreshed = try await OpenAICodexAuthClient.refreshCredential(credential)
        try credentialClient.saveOpenAICodexCredential(refreshed)
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

private struct OpenAICodexPKCE {
    let verifier: String
    let challenge: String

    init() throws {
        verifier = OpenAICodexRandom.base64URLString(byteCount: 64)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        challenge = Data(digest).openAICodexBase64URLEncodedString()
    }
}

private enum OpenAICodexRandom {
    static func base64URLString(byteCount: Int) -> String {
        var data = Data(count: byteCount)
        _ = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, byteCount, $0.baseAddress!)
        }
        return data.openAICodexBase64URLEncodedString()
    }
}

private extension Data {
    func openAICodexBase64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private struct OpenAICodexJWTClaims {
    var accountID: String?
    var email: String?

    static func bestClaims(idToken: String?, accessToken: String) -> Self {
        decode(token: idToken) ?? decode(token: accessToken) ?? Self()
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
            email: object["email"] as? String
        )
    }
}

nonisolated enum OpenAICodexAuthClientError: LocalizedError, Equatable {
    case browserLaunchFailed
    case callbackTimedOut
    case invalidAuthorizationURL
    case invalidCallback
    case invalidModelURL
    case invalidResponse
    case missingCredential
    case missingRefreshToken
    case oauthFailed(String)
    case requestFailed(statusCode: Int, message: String)
    case stateMismatch

    var errorDescription: String? {
        switch self {
        case .browserLaunchFailed:
            return "Could not open the ChatGPT sign-in page."
        case .callbackTimedOut:
            return "ChatGPT sign-in timed out."
        case .invalidAuthorizationURL:
            return "Could not create the ChatGPT sign-in URL."
        case .invalidCallback:
            return "ChatGPT returned an invalid sign-in callback."
        case .invalidModelURL:
            return "Could not create the ChatGPT model list URL."
        case .invalidResponse:
            return "ChatGPT returned an invalid response."
        case .missingCredential:
            return "Sign in with ChatGPT before using Codex models."
        case .missingRefreshToken:
            return "Sign in with ChatGPT again before using Codex models."
        case .oauthFailed(let message):
            return "ChatGPT sign-in failed: \(message)"
        case .requestFailed(let statusCode, let message):
            return "ChatGPT returned HTTP \(statusCode): \(message)"
        case .stateMismatch:
            return "ChatGPT sign-in returned an unexpected state."
        }
    }
}
