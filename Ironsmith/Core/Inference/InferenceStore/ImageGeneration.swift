import ImagePlayground

extension InferenceStore {
    var availableImageGenerationProviders: [ToolImageGenerationProvider] {
        var result: [ToolImageGenerationProvider] = []

        if ImagePlaygroundViewController.isAvailable {
            result.append(.imagePlayground)
        }
        if configuredImageProvider(.gemini) != nil {
            result.append(.gemini)
        }
        if providers.contains(where: { $0.kind == .openAI && $0.isEnabled }),
           hasOpenAICodexCredential || configuredImageProvider(.openAI) != nil {
            result.append(.openAI)
        }
        if ironsmithSession != nil, configuredImageProvider(.ironsmith) != nil {
            result.append(.ironsmith)
        }
        result.append(.disabled)
        return result
    }

    var effectiveImageGenerationProvider: ToolImageGenerationProvider {
        let selected = generationPreferences.imageGenerationProvider
        if availableImageGenerationProviders.contains(selected) {
            return selected
        }
        return availableImageGenerationProviders.contains(.imagePlayground)
            ? .imagePlayground
            : .disabled
    }

    func reconcileImageGenerationProvider() {
        let effective = effectiveImageGenerationProvider
        if generationPreferences.imageGenerationProvider != effective {
            generationPreferences.imageGenerationProvider = effective
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
