import SwiftUI

struct ProviderLogoView: View {
    let kind: ProviderKind
    var size: CGFloat = 32
    var showsBackground = true

    var body: some View {
        providerMark
            .frame(width: size, height: size)
            .background(backgroundShape)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var backgroundShape: some View {
        if showsBackground {
            RoundedRectangle(cornerRadius: min(size * 0.25, 8))
                .fill(.quaternary.opacity(0.38))
        }
    }

    @ViewBuilder
    private var providerMark: some View {
        switch kind {
        case .ironsmith:
            Image("ProviderLogoIronsmith")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(.secondary)
                .padding(size * 0.08)
        case .openAI, .anthropic, .gemini, .ollama:
            Text(badgeText)
                .font(.system(size: badgeFontSize, weight: .bold, design: .rounded))
                .foregroundStyle(badgeColor)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        case .local:
            Image(systemName: "desktopcomputer")
                .font(.system(size: size * 0.5, weight: .medium))
                .foregroundStyle(.secondary)
        case .customOpenAICompatible:
            Image(systemName: "network")
                .font(.system(size: size * 0.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var badgeText: String {
        switch kind {
        case .openAI:
            return "GPT"
        case .anthropic:
            return "A"
        case .gemini:
            return "G"
        case .ollama:
            return "O"
        case .ironsmith, .local, .customOpenAICompatible:
            return ""
        }
    }

    private var badgeColor: Color {
        SettingsBrandMarkStyle.color(
            forHex: SettingsBrandMarkStyle.providerColorHex(for: kind),
            fallback: .primary
        )
    }

    private var badgeFontSize: CGFloat {
        badgeText.count > 1 ? size * 0.28 : size * 0.52
    }
}

#Preview("Provider Logos") {
    HStack {
        ProviderLogoView(kind: .local)
        ProviderLogoView(kind: .ironsmith)
        ProviderLogoView(kind: .openAI)
        ProviderLogoView(kind: .anthropic)
        ProviderLogoView(kind: .gemini)
        ProviderLogoView(kind: .ollama)
        ProviderLogoView(kind: .customOpenAICompatible)
    }
    .padding()
}

enum SettingsBrandMarkStyle {
    static let claudeOrangeHex = "#D97757"
    static let deepSeekBlueHex = "#4D6BFE"
    static let gemmaPurpleHex = "#8E75B2"
    static let metaBlueHex = "#0082FB"
    static let microsoftBlueHex = "#00A4EF"
    static let mistralOrangeHex = "#FA500F"
    static let ollamaBlackHex = "#000000"
    static let openAIGreenHex = "#10A37F"
    static let qwenIndigoHex = "#665CEE"

    static func providerColorHex(for kind: ProviderKind) -> String? {
        switch kind {
        case .openAI:
            return openAIGreenHex
        case .anthropic:
            return claudeOrangeHex
        case .gemini:
            return gemmaPurpleHex
        case .ollama:
            return ollamaBlackHex
        case .local, .ironsmith, .customOpenAICompatible:
            return nil
        }
    }

    static func modelColorHex(
        forIdentifier identifier: String,
        displayName: String,
        providerKind: ProviderKind? = nil
    ) -> String? {
        let searchableName = "\(identifier) \(displayName)".lowercased()
        if providerKind == .openAI || searchableName.contains("gpt") || searchableName.contains("openai") {
            return openAIGreenHex
        }
        if providerKind == .anthropic || searchableName.contains("claude") || searchableName.contains("anthropic") {
            return claudeOrangeHex
        }
        if providerKind == .gemini || searchableName.contains("gemma") || searchableName.contains("gemini") {
            return gemmaPurpleHex
        }
        if searchableName.contains("deepseek") {
            return deepSeekBlueHex
        }
        if searchableName.contains("qwen") {
            return qwenIndigoHex
        }
        if searchableName.contains("mistral")
            || searchableName.contains("mixtral")
            || searchableName.contains("codestral")
            || searchableName.contains("devstral")
            || searchableName.contains("magistral")
            || searchableName.contains("ministral")
            || searchableName.contains("pixtral")
            || searchableName.contains("voxtral") {
            return mistralOrangeHex
        }
        if searchableName.contains("llama") || searchableName.contains("meta") {
            return metaBlueHex
        }
        if searchableName.contains("microsoft") || searchableName.contains("phi") {
            return microsoftBlueHex
        }
        if providerKind == .ollama || searchableName.contains("ollama") {
            return ollamaBlackHex
        }
        return nil
    }

    static func color(forHex hex: String?, fallback: Color = .secondary) -> Color {
        guard let hex = hex?.uppercased() else {
            return fallback
        }
        if hex == openAIGreenHex {
            return Color(red: 16.0 / 255.0, green: 163.0 / 255.0, blue: 127.0 / 255.0)
        }
        if hex == ollamaBlackHex {
            return .primary
        }
        if hex == claudeOrangeHex {
            return Color(red: 217.0 / 255.0, green: 119.0 / 255.0, blue: 87.0 / 255.0)
        }
        if hex == deepSeekBlueHex {
            return Color(red: 77.0 / 255.0, green: 107.0 / 255.0, blue: 254.0 / 255.0)
        }
        if hex == gemmaPurpleHex {
            return Color(red: 142.0 / 255.0, green: 117.0 / 255.0, blue: 178.0 / 255.0)
        }
        if hex == metaBlueHex {
            return Color(red: 0.0 / 255.0, green: 130.0 / 255.0, blue: 251.0 / 255.0)
        }
        if hex == microsoftBlueHex {
            return Color(red: 0.0 / 255.0, green: 164.0 / 255.0, blue: 239.0 / 255.0)
        }
        if hex == mistralOrangeHex {
            return Color(red: 250.0 / 255.0, green: 80.0 / 255.0, blue: 15.0 / 255.0)
        }
        if hex == qwenIndigoHex {
            return Color(red: 102.0 / 255.0, green: 92.0 / 255.0, blue: 238.0 / 255.0)
        }
        return fallback
    }
}
