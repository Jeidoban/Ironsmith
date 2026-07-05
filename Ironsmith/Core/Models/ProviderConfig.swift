//
//  ProviderConfig.swift
//  Ironsmith
//

import Foundation

enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case local
    case ironsmith
    case openAI = "openai"
    case anthropic
    case gemini
    case ollama
    case customOpenAICompatible = "custom_openai_compatible"

    var id: String { rawValue }
}

enum ProviderOrigin: String, Codable, CaseIterable {
    case builtIn = "built_in"
    case custom = "custom"
}

enum ProviderAuthMode: String, Codable, CaseIterable {
    case none
    case apiKey = "api_key"
    case platformCredits = "platform_credits"
}

typealias ProviderConfig = IronsmithSchemaV3.ProviderConfig

extension ProviderConfig {
    static let localProviderIdentifier = "local"

    var kind: ProviderKind {
        if origin == .custom { return .customOpenAICompatible }
        switch identifier {
        case Self.localProviderIdentifier: return .local
        case ProviderKind.ironsmith.rawValue: return .ironsmith
        case ProviderKind.openAI.rawValue: return .openAI
        case ProviderKind.anthropic.rawValue: return .anthropic
        case ProviderKind.gemini.rawValue: return .gemini
        case ProviderKind.ollama.rawValue: return .ollama
        default: return .customOpenAICompatible
        }
    }

    var isRemovable: Bool {
        kind != .local
    }

    var apiKeyReference: String? {
        authMode == .apiKey ? "provider.\(identifier)" : nil
    }
}
