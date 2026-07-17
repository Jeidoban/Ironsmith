import ImagePlayground

extension InferenceStore {
    var availableImageGenerationProviders: [ToolImageGenerationProvider] {
        var result: [ToolImageGenerationProvider] = [.automatic]

        if isOpenAICodexImageGenerationAvailable || configuredImageProvider(.openAI) != nil {
            result.append(.openAI)
        }
        if configuredImageProvider(.gemini) != nil {
            result.append(.gemini)
        }
        if ImagePlaygroundViewController.isAvailable {
            result.append(.imagePlayground)
        }
        if ironsmithSession != nil, configuredImageProvider(.ironsmith) != nil {
            result.append(.ironsmith)
        }
        result.append(.disabled)
        return result
    }

    var effectiveImageGenerationProvider: ToolImageGenerationProvider {
        let selected = generationPreferences.imageGenerationProvider
        if selected == .automatic {
            return automaticImageGenerationProvider
        }
        if availableImageGenerationProviders.contains(selected) {
            return selected
        }
        return automaticImageGenerationProvider
    }

    func reconcileImageGenerationProvider() {
        let selected = generationPreferences.imageGenerationProvider
        if !availableImageGenerationProviders.contains(selected) {
            generationPreferences.imageGenerationProvider = .automatic
        }
    }

    private var automaticImageGenerationProvider: ToolImageGenerationProvider {
        if let selectedModel,
           let provider = provider(for: selectedModel),
           let matchedProvider = imageGenerationProvider(matching: provider.kind) {
            return matchedProvider
        }
        if isOpenAICodexImageGenerationAvailable {
            return .openAI
        }
        if configuredImageProvider(.openAI) != nil {
            return .openAI
        }
        if configuredImageProvider(.gemini) != nil {
            return .gemini
        }
        if ImagePlaygroundViewController.isAvailable {
            return .imagePlayground
        }
        if ironsmithSession != nil, configuredImageProvider(.ironsmith) != nil {
            return .ironsmith
        }
        return .disabled
    }

    private var isOpenAICodexImageGenerationAvailable: Bool {
        hasOpenAICodexCredential
            && providers.contains(where: { $0.kind == .openAI && $0.isEnabled })
    }

    private func imageGenerationProvider(
        matching providerKind: ProviderKind
    ) -> ToolImageGenerationProvider? {
        switch providerKind {
        case .openAI:
            return isOpenAICodexImageGenerationAvailable || configuredImageProvider(.openAI) != nil
                ? .openAI
                : nil
        case .gemini:
            return configuredImageProvider(.gemini) != nil ? .gemini : nil
        case .ironsmith:
            return ironsmithSession != nil && configuredImageProvider(.ironsmith) != nil
                ? .ironsmith
                : nil
        default:
            return nil
        }
    }

    private func configuredImageProvider(_ kind: ProviderKind) -> ProviderConfig? {
        providers.first { provider in
            guard provider.kind == kind, provider.isEnabled else { return false }
            switch kind {
            case .gemini, .openAI:
                guard let reference = provider.apiKeyReference else { return false }
                return ((try? dependencies.credentialClient.loadAPIKey(reference)) ?? "").isEmpty == false
            case .ironsmith:
                return true
            default:
                return false
            }
        }
    }
}
