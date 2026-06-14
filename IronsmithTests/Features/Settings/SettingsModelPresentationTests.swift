import Testing
@testable import Ironsmith

struct SettingsModelPresentationTests {
    @Test
    func ollamaRecommendedModelsUseCatalogDisplayName() throws {
        let provider = try #require(ProviderCatalog.makeProvider(for: .ollama))
        let model = ModelConfig(
            identifier: "gemma4:e2b",
            displayName: "gemma4:e2b",
            providerIdentifier: provider.identifier,
            source: .remote,
            installState: .installed
        )

        #expect(SettingsModelPresentation.displayName(for: model, provider: provider) == "Gemma 4 E2B")
    }

    @Test
    func ollamaNonRecommendedModelsUseCleanDisplayName() throws {
        let provider = try #require(ProviderCatalog.makeProvider(for: .ollama))
        let model = ModelConfig(
            identifier: "qwen2.5-coder:7b-instruct-q4_K_M",
            displayName: "qwen2.5-coder:7b-instruct-q4_K_M",
            providerIdentifier: provider.identifier,
            source: .remote,
            installState: .installed
        )

        #expect(SettingsModelPresentation.displayName(for: model, provider: provider) == "Qwen 2.5 Coder 7B Instruct")
    }

    @Test
    func openAIModelLogoTextUsesGPT() {
        #expect(
            SettingsModelPresentation.logoText(
                forIdentifier: "o4-mini",
                displayName: "O4 Mini",
                providerKind: .openAI
            ) == "GPT"
        )
        #expect(
            SettingsModelPresentation.logoText(
                forIdentifier: "openai/o4-mini",
                displayName: "O4 Mini"
            ) == "GPT"
        )
    }

    @Test
    func nonOpenAIModelLogoTextUsesFirstModelLetter() {
        #expect(
            SettingsModelPresentation.logoText(
                forIdentifier: "anthropic/claude-sonnet-4.6",
                displayName: "Claude Sonnet 4.6",
                providerKind: .ironsmith
            ) == "C"
        )
        #expect(
            SettingsModelPresentation.logoText(
                forIdentifier: "deepseek/deepseek-v4-flash",
                displayName: "DeepSeek V4 Flash"
            ) == "D"
        )
    }

    @Test
    func providerBrandMarkColorsUseTextBadgePalette() {
        #expect(SettingsBrandMarkStyle.providerColorHex(for: .openAI) == SettingsBrandMarkStyle.openAIGreenHex)
        #expect(SettingsBrandMarkStyle.providerColorHex(for: .anthropic) == SettingsBrandMarkStyle.claudeOrangeHex)
        #expect(SettingsBrandMarkStyle.providerColorHex(for: .gemini) == SettingsBrandMarkStyle.gemmaPurpleHex)
        #expect(SettingsBrandMarkStyle.providerColorHex(for: .ollama) == SettingsBrandMarkStyle.ollamaBlackHex)
        #expect(SettingsBrandMarkStyle.providerColorHex(for: .ironsmith) == nil)
    }

    @Test
    func localProviderEmptyStateMentionsAppleIntelligenceOnAppleSilicon() throws {
        let provider = try #require(ProviderCatalog.makeProvider(for: .local))

        #expect(
            SettingsProviderModelEmptyState.message(
                for: provider,
                isAppleSiliconMac: true
            ) ==
                "No AI models available. Enable Apple Intelligence in macOS settings to use the built in model."
        )
    }

    @Test
    func providerEmptyStateUsesGenericCopyForOtherCases() throws {
        let localProvider = try #require(ProviderCatalog.makeProvider(for: .local))
        let openAIProvider = try #require(ProviderCatalog.makeProvider(for: .openAI))

        #expect(
            SettingsProviderModelEmptyState.message(
                for: localProvider,
                isAppleSiliconMac: false
            ) == "No AI models available."
        )
        #expect(
            SettingsProviderModelEmptyState.message(
                for: openAIProvider,
                isAppleSiliconMac: true
            ) == "No AI models available."
        )
    }

    @Test
    func modelBrandMarkColorsFollowModelFamily() {
        #expect(
            SettingsBrandMarkStyle.modelColorHex(
                forIdentifier: "openai/gpt-5.4",
                displayName: "GPT 5.4"
            ) == SettingsBrandMarkStyle.openAIGreenHex
        )
        #expect(
            SettingsBrandMarkStyle.modelColorHex(
                forIdentifier: "anthropic/claude-sonnet-4.6",
                displayName: "Claude Sonnet 4.6"
            ) == SettingsBrandMarkStyle.claudeOrangeHex
        )
        #expect(
            SettingsBrandMarkStyle.modelColorHex(
                forIdentifier: "mlx-community/gemma-4",
                displayName: "Gemma 4"
            ) == SettingsBrandMarkStyle.gemmaPurpleHex
        )
        #expect(
            SettingsBrandMarkStyle.modelColorHex(
                forIdentifier: "deepseek/deepseek-v4-flash",
                displayName: "DeepSeek V4 Flash"
            ) == SettingsBrandMarkStyle.deepSeekBlueHex
        )
        #expect(
            SettingsBrandMarkStyle.modelColorHex(
                forIdentifier: "mlx-community/Qwen3.5",
                displayName: "Qwen 3.5"
            ) == SettingsBrandMarkStyle.qwenIndigoHex
        )
        #expect(
            SettingsBrandMarkStyle.modelColorHex(
                forIdentifier: "mistral/mistral-large",
                displayName: "Mistral Large"
            ) == SettingsBrandMarkStyle.mistralOrangeHex
        )
        #expect(
            SettingsBrandMarkStyle.modelColorHex(
                forIdentifier: "meta-llama/llama-4",
                displayName: "Llama 4"
            ) == SettingsBrandMarkStyle.metaBlueHex
        )
        #expect(
            SettingsBrandMarkStyle.modelColorHex(
                forIdentifier: "microsoft/phi-4",
                displayName: "Phi 4"
            ) == SettingsBrandMarkStyle.microsoftBlueHex
        )
        #expect(
            SettingsBrandMarkStyle.modelColorHex(
                forIdentifier: "unknown-model",
                displayName: "Unknown Model",
                providerKind: .ollama
            ) == SettingsBrandMarkStyle.ollamaBlackHex
        )
        #expect(
            SettingsBrandMarkStyle.modelColorHex(
                forIdentifier: "unknown/model",
                displayName: "Unknown Model"
            ) == nil
        )
    }
}
