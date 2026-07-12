import Foundation

nonisolated enum ToolReasoningEffort: String, Codable, CaseIterable, Hashable, Sendable {
    case `default`
    case low
    case medium
    case high
    case xhigh
    case max

    static let explicitCases = Set(allCases.filter { $0 != .default })

    var displayName: String {
        switch self {
        case .default: "Default"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "XHigh"
        case .max: "Max"
        }
    }
}

nonisolated enum ToolReasoningSupport {
    static func supportedEfforts(
        for model: ModelConfig?,
        provider: ProviderConfig?
    ) -> Set<ToolReasoningEffort> {
        guard let model, let provider else { return [] }
        switch provider.kind {
        case .ironsmith, .anthropic:
            return model.reasoningEfforts
        case .openAI:
            return openAIEfforts(for: model.openAICodexRawIdentifier ?? model.identifier)
        case .customOpenAICompatible:
            return ToolReasoningEffort.explicitCases
        case .local, .gemini, .ollama:
            return []
        }
    }

    static func effectiveEffort(
        requested: ToolReasoningEffort,
        model: ModelConfig?,
        provider: ProviderConfig?
    ) -> ToolReasoningEffort {
        guard requested != .default else { return .default }
        return supportedEfforts(for: model, provider: provider).contains(requested)
            ? requested
            : .default
    }

    private static func openAIEfforts(for identifier: String) -> Set<ToolReasoningEffort> {
        let id = identifier.lowercased().replacingOccurrences(
            of: #"-\d{4}-\d{2}-\d{2}$"#,
            with: "",
            options: .regularExpression
        )
        if ["gpt-5.6", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"].contains(id) {
            return [.low, .medium, .high, .xhigh, .max]
        }
        if ["gpt-5.5-pro", "gpt-5.4-pro", "gpt-5.2-pro"].contains(id) {
            return [.medium, .high, .xhigh]
        }
        if id == "gpt-5-pro" {
            return [.high]
        }
        if [
            "gpt-5.5",
            "gpt-5.4", "gpt-5.4-mini", "gpt-5.4-nano",
            "gpt-5.3-codex",
            "gpt-5.2", "gpt-5.2-codex",
        ].contains(id) {
            return [.low, .medium, .high, .xhigh]
        }
        if [
            "gpt-5", "gpt-5-mini", "gpt-5-nano", "gpt-5-codex",
            "gpt-5.1", "gpt-5.1-codex", "gpt-5.1-codex-max", "gpt-5.1-codex-mini",
        ].contains(id) {
            return [.low, .medium, .high]
        }
        return []
    }
}

extension ModelConfig {
    var reasoningEfforts: Set<ToolReasoningEffort> {
        Set(
            (reasoningEffortRawValues ?? "")
                .split(separator: ",")
                .compactMap { ToolReasoningEffort(rawValue: String($0)) }
                .filter { $0 != .default }
        )
    }
}
