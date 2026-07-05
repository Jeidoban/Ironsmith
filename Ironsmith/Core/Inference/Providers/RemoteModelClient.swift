import Foundation

struct RemoteModelClient {
    var discoverModels: (ProviderConfig, String?) async throws -> [ModelConfig]
}

extension RemoteModelClient {
    static let discoveryTimeout: TimeInterval = 10

    static func live(
        accountClient: IronsmithAccountClient = .unconfigured,
        openAICodexAuthClient: OpenAICodexAuthClient = .unconfigured
    ) -> Self {
        Self { provider, apiKey in
            if provider.kind == .ironsmith {
                let data = try await accountClient.invokeAPIData("api/v1/models", .get)
                return try Self.decodeModels(data, for: provider)
            }

            if provider.kind == .openAI {
                return try await Self.discoverOpenAIModels(
                    provider: provider,
                    apiKey: apiKey,
                    openAICodexAuthClient: openAICodexAuthClient
                )
            }

            let request = try Self.makeModelListRequest(for: provider, apiKey: apiKey)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw RemoteModelDiscoveryError.invalidResponse
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                throw RemoteModelDiscoveryError.fetchFailed(statusCode: httpResponse.statusCode)
            }

            return try Self.decodeModels(data, for: provider)
        }
    }

    private static func discoverOpenAIModels(
        provider: ProviderConfig,
        apiKey: String?,
        openAICodexAuthClient: OpenAICodexAuthClient
    ) async throws -> [ModelConfig] {
        var models: [ModelConfig] = []
        var firstError: Error?

        if let apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !apiKey.isEmpty {
            do {
                let request = try makeModelListRequest(for: provider, apiKey: apiKey)
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw RemoteModelDiscoveryError.invalidResponse
                }
                guard (200...299).contains(httpResponse.statusCode) else {
                    throw RemoteModelDiscoveryError.fetchFailed(statusCode: httpResponse.statusCode)
                }
                models.append(contentsOf: try decodeModels(data, for: provider))
            } catch {
                firstError = error
            }
        }

        do {
            let codexModels = try await openAICodexAuthClient.discoverModels()
            models.append(contentsOf: makeCodexModelConfigs(codexModels, provider: provider))
        } catch OpenAICodexAuthClientError.missingCredential {
        } catch {
            firstError = firstError ?? error
        }

        if models.isEmpty, let firstError {
            throw firstError
        }

        return models
            .removingDuplicateSelectionIdentifiers()
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    static func makeModelListRequest(for provider: ProviderConfig, apiKey: String?) throws -> URLRequest {
        guard provider.kind != .local else {
            throw RemoteModelDiscoveryError.localProviderNotSupported
        }
        guard let descriptor = ProviderCatalog.descriptor(for: provider.kind),
              let modelsPath = descriptor.modelsPath
        else {
            throw RemoteModelDiscoveryError.unsupportedProvider
        }

        let baseURLString = provider.baseURLString.isEmpty
            ? descriptor.defaultBaseURLString
            : provider.baseURLString
        guard let baseURL = try? ProviderBaseURLValidator.validatedURL(from: baseURLString) else {
            throw RemoteModelDiscoveryError.invalidBaseURL
        }

        var request = URLRequest(url: baseURL.appendingPathComponent(modelsPath))
        request.httpMethod = "GET"
        request.timeoutInterval = discoveryTimeout

        if let apiKey, !apiKey.isEmpty {
            switch descriptor.responseFormat {
            case .anthropic:
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            case .gemini:
                request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            case .openAI:
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            case .ollama:
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            case .ironsmith:
                break
            case nil:
                break
            }
        }

        return request
    }

    static func decodeModels(_ data: Data, for provider: ProviderConfig) throws -> [ModelConfig] {
        guard let descriptor = ProviderCatalog.descriptor(for: provider.kind),
              let responseFormat = descriptor.responseFormat
        else {
            throw RemoteModelDiscoveryError.unsupportedProvider
        }

        let entries: [RemoteModelEntry] = switch responseFormat {
        case .openAI:
            filterDiscoverableModels(
                try JSONDecoder().decode(OpenAIModelsResponse.self, from: data).data.map {
                    ($0.id, $0.id)
                },
                for: provider.kind
            ).map { RemoteModelEntry(identifier: $0.identifier, displayName: $0.displayName) }
        case .anthropic:
            filterDiscoverableModels(
                try JSONDecoder().decode(AnthropicModelsResponse.self, from: data).data.map {
                    ($0.id, $0.displayName ?? $0.id)
                },
                for: provider.kind
            ).map { RemoteModelEntry(identifier: $0.identifier, displayName: $0.displayName) }
        case .gemini:
            filterDiscoverableModels(
                try JSONDecoder().decode(GeminiModelsResponse.self, from: data).models
                    .filter { $0.supportedGenerationMethods.contains("generateContent") }
                    .map {
                        let identifier = $0.baseModelId ?? $0.name.removingPrefix("models/")
                        return (identifier, $0.displayName ?? identifier)
                    },
                for: provider.kind
            ).map { RemoteModelEntry(identifier: $0.identifier, displayName: $0.displayName) }
        case .ollama:
            filterDiscoverableModels(
                try JSONDecoder().decode(OllamaModelsResponse.self, from: data).models.map {
                    let identifier = $0.name ?? $0.model
                    return (identifier, identifier)
                },
                for: provider.kind
            ).map { RemoteModelEntry(identifier: $0.identifier, displayName: $0.displayName) }
        case .ironsmith:
            try JSONDecoder().decode(IronsmithModelsResponse.self, from: data).data.map {
                RemoteModelEntry(
                    identifier: $0.id,
                    displayName: $0.displayName,
                    estimatedToolCredits: $0.estimatedToolCredits
                )
            }
        }

        return entries
            .map {
                ModelConfig(
                    identifier: $0.identifier,
                    displayName: $0.displayName,
                    providerIdentifier: provider.identifier,
                    source: .remote,
                    installState: .installed,
                    estimatedToolCredits: $0.estimatedToolCredits
                )
            }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    static func makeCodexModelConfigs(
        _ codexModels: [OpenAICodexModel],
        provider: ProviderConfig
    ) -> [ModelConfig] {
        codexModels.map { model in
            ModelConfig(
                identifier: OpenAICodexBackend.codexModelIdentifier(for: model.identifier),
                displayName: "\(model.displayName) (Codex)",
                providerIdentifier: provider.identifier,
                source: .remote,
                installState: .installed
            )
        }
    }

    private static func filterDiscoverableModels(
        _ entries: [(identifier: String, displayName: String)],
        for providerKind: ProviderKind
    ) -> [(identifier: String, displayName: String)] {
        let textEntries = entries.filter { isTextGenerationModel($0.identifier, displayName: $0.displayName, providerKind: providerKind) }
        return removingSnapshotAliases(from: textEntries)
    }

    private static func isTextGenerationModel(
        _ identifier: String,
        displayName: String,
        providerKind: ProviderKind
    ) -> Bool {
        let searchableName = "\(identifier) \(displayName)".lowercased()

        let sharedExcludedTerms = [
            "audio",
            "dall-e",
            "embedding",
            "imagen",
            "image",
            "moderation",
            "realtime",
            "speech",
            "transcribe",
            "tts",
            "veo",
            "video",
            "whisper",
        ]

        if sharedExcludedTerms.contains(where: { searchableName.contains($0) }) {
            return false
        }

        switch providerKind {
        case .gemini:
            let excludedGeminiTerms = [
                "aqa",
                "chirp",
                "computer use",
                "computer-use",
                "lyria",
                "nano banana",
                "nano-banana",
                "robotics",
            ]
            return !excludedGeminiTerms.contains(where: { searchableName.contains($0) })

        case .openAI:
            return identifier.hasPrefix("gpt-")
                || identifier.hasPrefix("chatgpt-")
                || identifier.hasPrefix("o")

        case .customOpenAICompatible, .ironsmith, .ollama:
            return true

        case .anthropic:
            return identifier.hasPrefix("claude-")

        case .local:
            return false
        }
    }

    private static func removingSnapshotAliases(
        from entries: [(identifier: String, displayName: String)]
    ) -> [(identifier: String, displayName: String)] {
        let identifiers = Set(entries.map(\.identifier))
        return entries.filter { entry in
            guard let stableAlias = entry.identifier.removingDateSnapshotSuffix else {
                return true
            }
            return !identifiers.contains(stableAlias)
        }
    }
}

private extension Array where Element == ModelConfig {
    func removingDuplicateSelectionIdentifiers() -> [ModelConfig] {
        var seen = Set<String>()
        return filter { model in
            seen.insert(model.selectionIdentifier).inserted
        }
    }
}

enum RemoteModelDiscoveryError: LocalizedError {
    case invalidResponse
    case fetchFailed(statusCode: Int)
    case invalidBaseURL
    case localProviderNotSupported
    case unsupportedProvider

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The provider did not return a valid response."
        case .fetchFailed(let code):
            return "The provider returned HTTP \(code) when fetching AI models."
        case .invalidBaseURL:
            return "The provider base URL is invalid."
        case .localProviderNotSupported:
            return "Local providers do not support AI model discovery."
        case .unsupportedProvider:
            return "This provider does not support AI model discovery yet."
        }
    }
}

private struct RemoteModelEntry {
    let identifier: String
    let displayName: String
    let estimatedToolCredits: Int?

    init(identifier: String, displayName: String, estimatedToolCredits: Int? = nil) {
        self.identifier = identifier
        self.displayName = displayName
        self.estimatedToolCredits = estimatedToolCredits
    }
}

private struct OpenAIModelsResponse: Decodable {
    let data: [OpenAIModelEntry]
}

private struct OpenAIModelEntry: Decodable {
    let id: String
}

private struct IronsmithModelsResponse: Decodable {
    let data: [IronsmithModelEntry]
}

private struct IronsmithModelEntry: Decodable {
    let id: String
    let displayName: String
    let estimatedToolCredits: Int?
}

private struct AnthropicModelsResponse: Decodable {
    let data: [AnthropicModelEntry]
}

private struct AnthropicModelEntry: Decodable {
    let id: String
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

private struct OllamaModelsResponse: Decodable {
    let models: [OllamaModelEntry]
}

private struct OllamaModelEntry: Decodable {
    let name: String?
    let model: String
}

private struct GeminiModelsResponse: Decodable {
    let models: [GeminiModelEntry]
}

private struct GeminiModelEntry: Decodable {
    let name: String
    let baseModelId: String?
    let displayName: String?
    let supportedGenerationMethods: [String]
}

private extension String {
    func removingPrefix(_ prefix: String) -> String {
        guard hasPrefix(prefix) else { return self }
        return String(dropFirst(prefix.count))
    }

    var removingDateSnapshotSuffix: String? {
        let pattern = #"-\d{4}-\d{2}-\d{2}$"#
        guard let range = range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return String(self[..<range.lowerBound])
    }
}
