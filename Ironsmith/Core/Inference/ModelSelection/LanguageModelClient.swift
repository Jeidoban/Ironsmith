import AnyLanguageModel
import Foundation
#if canImport(Hub)
import Hub
#endif

struct LanguageModelClient {
    var makeLanguageModel: (ModelConfig, ProviderConfig?) async throws -> any LanguageModel
}

extension LanguageModelClient {
    static func live(
        credentialClient: CredentialClient,
        localModelClient: LocalModelClient,
        accountClient: IronsmithAccountClient = .unconfigured,
        openAICodexAuthClient: OpenAICodexAuthClient = .unconfigured
    ) -> Self {
        Self(
            makeLanguageModel: { model, provider in
                try await Self.makeLiveLanguageModel(
                    for: model,
                    provider: provider,
                    credentialClient: credentialClient,
                    localModelClient: localModelClient,
                    accountClient: accountClient,
                    openAICodexAuthClient: openAICodexAuthClient
                )
            }
        )
    }

    private static func makeLiveLanguageModel(
        for model: ModelConfig,
        provider: ProviderConfig?,
        credentialClient: CredentialClient,
        localModelClient: LocalModelClient,
        accountClient: IronsmithAccountClient,
        openAICodexAuthClient: OpenAICodexAuthClient
    ) async throws -> any LanguageModel {
        switch model.source {
        case .appleFoundation:
            return SystemLanguageModel.default

        case .mlx:
            #if canImport(Hub)
            let hub = try localModelClient.makeHubAPI()
            guard let hub = hub as? HubApi else {
                throw LanguageModelClientError.mlxUnavailable
            }
            let directory = model.localDirectoryPath.map(URL.init(fileURLWithPath:))
            return MLXLanguageModel(modelId: model.identifier, hub: hub, directory: directory)
            #else
            throw LanguageModelClientError.mlxUnavailable
            #endif

        case .remote:
            guard let provider else {
                throw LanguageModelClientError.missingProvider
            }

            switch provider.kind {
            case .ironsmith:
                let token = try await accountClient.generationAccessToken()
                guard !token.isEmpty else { throw LanguageModelClientError.missingAccountSession }
                let baseURL = try providerBaseURL(provider)
                return OpenAILanguageModel(
                    baseURL: baseURL,
                    apiKey: token,
                    model: model.identifier,
                    apiVariant: .responses,
                    session: remoteGenerationSession(for: baseURL)
                )

            case .openAI:
                if let codexModelIdentifier = model.openAICodexRawIdentifier {
                    let credential = try await openAICodexAuthClient.validCredential()
                    var headers: [String: String] = [:]
                    if let accountID = credential.accountID, !accountID.isEmpty {
                        headers["ChatGPT-Account-Id"] = accountID
                    }
                    return OpenAILanguageModel(
                        baseURL: OpenAICodexBackend.backendBaseURL,
                        apiKey: credential.accessToken,
                        model: codexModelIdentifier,
                        apiVariant: .responses,
                        session: remoteGenerationSession(
                            for: OpenAICodexBackend.backendBaseURL,
                            headers: headers
                        )
                    )
                }

                let token = try apiKey(for: provider, credentialClient: credentialClient)
                let baseURL = try providerBaseURL(provider)
                return OpenAILanguageModel(
                    baseURL: baseURL,
                    apiKey: token,
                    model: model.identifier,
                    apiVariant: .responses,
                    session: remoteGenerationSession(for: baseURL)
                )

            case .customOpenAICompatible:
                let token = try optionalAPIKey(for: provider, credentialClient: credentialClient)
                let baseURL = try providerBaseURL(provider)
                return OpenAILanguageModel(
                    baseURL: baseURL,
                    apiKey: token,
                    model: model.identifier,
                    apiVariant: .chatCompletions,
                    session: remoteGenerationSession(for: baseURL)
                )

            case .ollama:
                let token = try optionalAPIKey(for: provider, credentialClient: credentialClient)
                let baseURL = try providerBaseURL(provider)
                return OllamaLanguageModel(
                    baseURL: baseURL,
                    model: model.identifier,
                    session: remoteGenerationSession(
                        for: baseURL,
                        headers: token.isEmpty ? [:] : ["Authorization": "Bearer \(token)"]
                    )
                )

            case .anthropic:
                let token = try apiKey(for: provider, credentialClient: credentialClient)
                let baseURL = try providerBaseURL(provider)
                return AnthropicLanguageModel(
                    baseURL: baseURL,
                    apiKey: token,
                    model: model.identifier,
                    session: remoteGenerationSession(for: baseURL)
                )

            case .gemini:
                let token = try apiKey(for: provider, credentialClient: credentialClient)
                let baseURL = try providerBaseURL(provider)
                return GeminiLanguageModel(
                    baseURL: baseURL,
                    apiKey: token,
                    model: model.identifier,
                    session: remoteGenerationSession(for: baseURL)
                )

            case .local:
                throw LanguageModelClientError.missingProvider
            }
        }
    }

    private static func providerBaseURL(_ provider: ProviderConfig) throws -> URL {
        let descriptor = ProviderCatalog.descriptor(for: provider.kind)
        let baseURLString = provider.baseURLString.isEmpty
            ? descriptor?.defaultBaseURLString ?? ""
            : provider.baseURLString
        guard let baseURL = try? ProviderBaseURLValidator.validatedURL(from: baseURLString) else {
            throw LanguageModelClientError.invalidProviderURL
        }
        return baseURL
    }

    private static func remoteGenerationSession(for baseURL: URL, headers: [String: String] = [:]) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if !headers.isEmpty {
            configuration.httpAdditionalHeaders = headers
        }

        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 1_800

        return URLSession(configuration: configuration)
    }

    private static func apiKey(
        for provider: ProviderConfig,
        credentialClient: CredentialClient
    ) throws -> String {
        guard let reference = provider.apiKeyReference else {
            throw LanguageModelClientError.missingAPIKey
        }
        guard let apiKey = try credentialClient.loadAPIKey(reference), !apiKey.isEmpty else {
            throw LanguageModelClientError.missingAPIKey
        }
        return apiKey
    }

    private static func optionalAPIKey(
        for provider: ProviderConfig,
        credentialClient: CredentialClient
    ) throws -> String {
        guard let reference = provider.apiKeyReference else {
            return ""
        }
        return try credentialClient.loadAPIKey(reference) ?? ""
    }
}

private extension URL {
    var isLoopback: Bool {
        guard let host = host(percentEncoded: false)?.lowercased() else {
            return false
        }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

enum LanguageModelClientError: LocalizedError {
    case foundationModelsUnavailable
    case invalidProviderURL
    case missingAccountSession
    case mlxUnavailable
    case missingAPIKey
    case missingProvider

    var errorDescription: String? {
        switch self {
        case .foundationModelsUnavailable:
            return "Apple Foundation Model is unavailable on this system."
        case .invalidProviderURL:
            return "The provider URL is invalid."
        case .missingAccountSession:
            return "Sign in with Ironsmith before using Ironsmith credits."
        case .mlxUnavailable:
            return "MLX local AI models are unavailable in this build."
        case .missingAPIKey:
            return "This provider is missing an API key."
        case .missingProvider:
            return "The selected AI model is missing its provider configuration."
        }
    }
}
