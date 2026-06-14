import SwiftUI

struct ModelLogoView: View {
    let identifier: String
    let displayName: String
    let fallbackProviderKind: ProviderKind
    var size: CGFloat = 28

    init(model: ModelConfig, provider: ProviderConfig?, size: CGFloat = 28) {
        identifier = model.identifier
        displayName = model.displayName
        fallbackProviderKind = provider?.kind ?? .customOpenAICompatible
        self.size = size
    }

    init(identifier: String, displayName: String, fallbackProviderKind: ProviderKind, size: CGFloat = 28) {
        self.identifier = identifier
        self.displayName = displayName
        self.fallbackProviderKind = fallbackProviderKind
        self.size = size
    }

    var body: some View {
        modelMark
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(.quaternary.opacity(0.38), in: RoundedRectangle(cornerRadius: min(size * 0.25, 8)))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var modelMark: some View {
        if usesAppleLogo {
            Image(systemName: "apple.logo")
                .font(.system(size: size * 0.5, weight: .medium))
        } else {
            Text(badgeText)
                .font(.system(size: badgeFontSize, weight: .bold, design: .rounded))
                .foregroundStyle(badgeColor)
                .minimumScaleFactor(0.58)
                .lineLimit(1)
        }
    }

    private var usesAppleLogo: Bool {
        let searchableName = "\(identifier) \(displayName)".lowercased()
        return identifier == ModelConfig.appleFoundationIdentifier || searchableName.contains("apple foundation")
    }

    private var badgeText: String {
        SettingsModelPresentation.logoText(
            forIdentifier: identifier,
            displayName: displayName,
            providerKind: fallbackProviderKind
        )
    }

    private var badgeFontSize: CGFloat {
        badgeText.count > 1 ? size * 0.25 : size * 0.5
    }

    private var badgeColor: Color {
        SettingsBrandMarkStyle.color(
            forHex: SettingsBrandMarkStyle.modelColorHex(
                forIdentifier: identifier,
                displayName: displayName,
                providerKind: fallbackProviderKind
            )
        )
    }
}

enum SettingsModelPresentation {
    static func displayName(for model: ModelConfig, provider: ProviderConfig?) -> String {
        if model.source == .appleFoundation {
            return "Apple Foundation Model"
        }

        switch provider?.kind {
        case .customOpenAICompatible:
            return cleanedDisplayName(model.displayName, fallbackIdentifier: model.identifier)
        case .ollama:
            if let catalogDisplayName = OllamaModelCatalog.displayName(forIdentifier: model.identifier) {
                return catalogDisplayName
            }
            return cleanedDisplayName(model.displayName, fallbackIdentifier: model.identifier)
        default:
            return model.displayName
        }
    }

    static func logoText(
        forIdentifier identifier: String,
        displayName: String,
        providerKind: ProviderKind? = nil
    ) -> String {
        let searchableName = "\(identifier) \(displayName)".lowercased()
        if providerKind == .openAI || searchableName.contains("gpt") || searchableName.contains("openai") {
            return "GPT"
        }

        let source = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? identifier : displayName
        let tail = source
            .split(separator: "/")
            .last
            .map(String.init) ?? source
        let firstLetter = tail.first { $0.isLetter }
        return firstLetter.map { String($0).uppercased() } ?? "?"
    }

    private static func cleanedDisplayName(_ displayName: String, fallbackIdentifier: String) -> String {
        let source = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackIdentifier : displayName
        let tail = source
            .split(separator: "/")
            .last
            .map(String.init) ?? source
        var normalized = tail
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        for bitDepth in ["2", "3", "4", "5", "6", "8"] {
            normalized = normalized.replacingOccurrences(of: "\(bitDepth)-bit", with: "", options: .caseInsensitive)
            normalized = normalized.replacingOccurrences(of: "\(bitDepth)bit", with: "", options: .caseInsensitive)
        }
        let tokens = normalized
            .components(separatedBy: CharacterSet(charactersIn: "- "))
            .filter { !$0.isEmpty }
            .filter { !isDisplayNoise($0) }
            .map { formattedToken($0, keepsShortAcronyms: false) }

        let cleaned = tokens.joined(separator: " ")
        return cleaned.isEmpty ? source : cleaned
    }

    private static func isDisplayNoise(_ token: String) -> Bool {
        let lowercased = token.lowercased()
        if ["mlx", "gguf", "latest", "q4", "q5", "q6", "q8", "awq", "gptq", "f16", "fp16", "bf16", "bit", "k", "m", "s", "0"].contains(lowercased) {
            return true
        }
        if lowercased.hasSuffix("bit"), lowercased.dropLast(3).allSatisfy(\.isNumber) {
            return true
        }
        if lowercased.range(of: #"^q[2-8](_?k)?(_?[ms])?$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static func formattedToken(_ token: String, keepsShortAcronyms: Bool) -> String {
        let lowercased = token.lowercased()
        if ["ai", "glm", "gpt", "mlx", "oss"].contains(lowercased) {
            return lowercased.uppercased()
        }
        if lowercased == "deepseek" {
            return "DeepSeek"
        }
        if lowercased == "openchat" {
            return "OpenChat"
        }
        if lowercased == "starcoder" {
            return "StarCoder"
        }
        if lowercased == "codellama" {
            return "CodeLlama"
        }
        if lowercased == "qwen" {
            return "Qwen"
        }
        if lowercased == "llama" {
            return "Llama"
        }
        if lowercased == "gemma" {
            return "Gemma"
        }
        if lowercased == "mistral" {
            return "Mistral"
        }
        if lowercased.range(of: #"^[a-z]+\d"#, options: .regularExpression) != nil,
           let digitIndex = lowercased.firstIndex(where: \.isNumber) {
            let name = String(lowercased[..<digitIndex])
            let version = String(lowercased[digitIndex...])
            return "\(formattedToken(name, keepsShortAcronyms: keepsShortAcronyms)) \(version.uppercased())"
        }
        if lowercased.range(of: #"^\d+[a-z]+$"#, options: .regularExpression) != nil {
            return lowercased.uppercased()
        }
        if keepsShortAcronyms && lowercased.count <= 4 {
            return lowercased.uppercased()
        }
        return lowercased.prefix(1).uppercased() + String(lowercased.dropFirst())
    }
}

#Preview("AI Model Provider Logos") {
    HStack {
        ModelLogoView(identifier: ModelConfig.appleFoundationIdentifier, displayName: "Apple Foundation Model", fallbackProviderKind: .local)
        ModelLogoView(identifier: "mlx-community/Qwen3.5", displayName: "Qwen 3.5", fallbackProviderKind: .local)
        ModelLogoView(identifier: "mlx-community/gemma-4", displayName: "Gemma 4", fallbackProviderKind: .local)
        ModelLogoView(identifier: "openai/gpt-5.4", displayName: "GPT 5.4", fallbackProviderKind: .ironsmith)
        ModelLogoView(identifier: "anthropic/claude-sonnet-4.6", displayName: "Claude Sonnet 4.6", fallbackProviderKind: .ironsmith)
        ModelLogoView(identifier: "deepseek/deepseek-v4-flash", displayName: "DeepSeek V4 Flash", fallbackProviderKind: .ironsmith)
        ModelLogoView(identifier: "llama-3.1", displayName: "Llama 3.1", fallbackProviderKind: .local)
        ModelLogoView(identifier: "phi-4", displayName: "Phi 4", fallbackProviderKind: .local)
    }
    .padding()
}
