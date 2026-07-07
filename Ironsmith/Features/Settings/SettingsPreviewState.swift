import Foundation

@MainActor
enum SettingsPreviewState {
    enum Selection {
        case appleFoundation
        case remote
        case none
    }

    static func make(
        selectedModel: Selection = .appleFoundation
    ) -> InferenceStore {
        let suiteName = "Ironsmith.SettingsPreviewState.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        let appleFoundationModelPreferenceStore = AppleFoundationModelPreferenceStore(
            userDefaults: userDefaults
        )
        appleFoundationModelPreferenceStore.isEnabled = selectedModel == .appleFoundation
        let inferenceStore = InferenceStore(
            appleFoundationModelPreferenceStore: appleFoundationModelPreferenceStore
        )

        let localProvider = ProviderConfig(
            identifier: ProviderConfig.localProviderIdentifier,
            displayName: "Local",
            baseURLString: "",
            authMode: .none,
            origin: .builtIn
        )
        let openAIProvider = ProviderConfig(
            identifier: ProviderKind.openAI.rawValue,
            displayName: "OpenAI",
            baseURLString: "https://api.openai.com/v1/",
            authMode: .apiKey,
            origin: .builtIn
        )

        let appleFoundationModel = ModelConfig(
            identifier: ModelConfig.appleFoundationIdentifier,
            displayName: "Apple Foundation Model",
            providerIdentifier: localProvider.identifier,
            source: .appleFoundation,
            installState: .builtIn
        )

        let remoteModel = ModelConfig(
            identifier: "gpt-4o-mini",
            displayName: "gpt-4o-mini",
            providerIdentifier: openAIProvider.identifier,
            source: .remote,
            installState: .installed
        )

        inferenceStore.providers = [localProvider, openAIProvider]
        inferenceStore.persistedModels = [appleFoundationModel]
        inferenceStore.remoteModels = [remoteModel]

        switch selectedModel {
        case .appleFoundation:
            inferenceStore.selectedModelID = appleFoundationModel.selectionIdentifier
        case .remote:
            inferenceStore.selectedModelID = remoteModel.selectionIdentifier
        case .none:
            break
        }

        return inferenceStore
    }
}
