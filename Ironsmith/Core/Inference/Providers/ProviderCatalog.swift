import AnyLanguageModel
import Foundation

enum ProviderModelListResponseFormat {
    case openAI
    case anthropic
    case gemini
    case ollama
    case ironsmith
}

struct ProviderDescriptor: Identifiable, Hashable {
    let kind: ProviderKind
    let displayName: String
    let defaultBaseURLString: String
    let authMode: ProviderAuthMode
    let origin: ProviderOrigin
    let sortOrder: Int
    let modelsPath: String?
    let responseFormat: ProviderModelListResponseFormat?

    var id: ProviderKind { kind }
}

enum ProviderCatalog {
    static let descriptors: [ProviderDescriptor] = [
        .init(
            kind: .local,
            displayName: "Local",
            defaultBaseURLString: "",
            authMode: .none,
            origin: .builtIn,
            sortOrder: 0,
            modelsPath: nil,
            responseFormat: nil
        ),
        .init(
            kind: .ollama,
            displayName: "Ollama",
            defaultBaseURLString: OllamaLanguageModel.defaultBaseURL.absoluteString,
            authMode: .apiKey,
            origin: .builtIn,
            sortOrder: 100,
            modelsPath: "api/tags",
            responseFormat: .ollama
        ),
        .init(
            kind: .ironsmith,
            displayName: "Ironsmith",
            defaultBaseURLString: IronsmithBackendConfiguration.liveOpenAICompatibleBaseURLString,
            authMode: .platformCredits,
            origin: .builtIn,
            sortOrder: 200,
            modelsPath: "models",
            responseFormat: .ironsmith
        ),
        .init(
            kind: .openAI,
            displayName: "OpenAI",
            defaultBaseURLString: OpenAILanguageModel.defaultBaseURL.absoluteString,
            authMode: .apiKey,
            origin: .builtIn,
            sortOrder: 300,
            modelsPath: "models",
            responseFormat: .openAI
        ),
        .init(
            kind: .anthropic,
            displayName: "Anthropic",
            defaultBaseURLString: AnthropicLanguageModel.defaultBaseURL.absoluteString,
            authMode: .apiKey,
            origin: .builtIn,
            sortOrder: 400,
            modelsPath: "v1/models",
            responseFormat: .anthropic
        ),
        .init(
            kind: .gemini,
            displayName: "Gemini",
            defaultBaseURLString: GeminiLanguageModel.defaultBaseURL.absoluteString,
            authMode: .apiKey,
            origin: .builtIn,
            sortOrder: 500,
            modelsPath: "v1beta/models",
            responseFormat: .gemini
        ),
        .init(
            kind: .customOpenAICompatible,
            displayName: "OpenAI-Compatible",
            defaultBaseURLString: "",
            authMode: .apiKey,
            origin: .custom,
            sortOrder: 600,
            modelsPath: "models",
            responseFormat: .openAI
        ),
    ]

    static var addableBuiltInDescriptors: [ProviderDescriptor] {
        descriptors.filter { $0.kind != .local && $0.origin == .builtIn }
    }

    static func descriptor(for kind: ProviderKind) -> ProviderDescriptor? {
        descriptors.first { $0.kind == kind }
    }

    static func makeProvider(for kind: ProviderKind) -> ProviderConfig? {
        guard let descriptor = descriptor(for: kind) else { return nil }
        return ProviderConfig(
            identifier: kind == .local ? ProviderConfig.localProviderIdentifier : kind.rawValue,
            displayName: descriptor.displayName,
            baseURLString: descriptor.defaultBaseURLString,
            authMode: descriptor.authMode,
            origin: descriptor.origin,
            isEnabled: true
        )
    }
}
