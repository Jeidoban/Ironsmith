import Foundation

extension InferenceStore {
    var availableModels: [ModelConfig] {
        let installedPersistedModels = enabledPersistedModels
            .filter {
                $0.installState == .installed || $0.installState == .builtIn
            }
        return (installedPersistedModels + remoteModels)
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    var selectedModel: ModelConfig? {
        guard let selectedModelID else { return nil }
        return availableModels.first(where: { $0.selectionIdentifier == selectedModelID })
    }

    var selectedModelUsesIronsmith: Bool {
        guard let selectedModel else { return false }
        return provider(for: selectedModel)?.kind == .ironsmith
    }

    func clearSelectedModelFallbackMessage() {
        selectedModelFallbackMessage = nil
    }

    func setAppleFoundationModelEnabled(_ isEnabled: Bool) {
        guard isAppleFoundationModelEnabled != isEnabled else { return }
        isAppleFoundationModelEnabled = isEnabled
        reconcileSelectedModel()
    }

    @discardableResult
    func selectIronsmithModel(identifier: String) -> Bool {
        guard let provider = providers.first(where: { $0.kind == .ironsmith }),
            let model = remoteModels.first(where: {
                $0.providerIdentifier == provider.identifier && $0.identifier == identifier
            })
        else {
            return false
        }

        selectModel(model.selectionIdentifier)
        return true
    }

    func reconcileSelectedModel() {
        if let selectedModelID,
            availableModels.contains(where: { $0.selectionIdentifier == selectedModelID })
        {
            modelSelection.selectedModelID = selectedModelID
            return
        }

        let unavailableSelectionID = selectedModelID
        guard !availableModels.isEmpty else {
            selectModel(
                nil,
                fallbackMessage: unavailableSelectionID == nil
                    ? nil : InferenceMessages.noAvailableModels
            )
            return
        }

        selectModel(
            availableModels.first?.selectionIdentifier,
            fallbackMessage: unavailableSelectionID.map {
                let modelName = Self.modelName(fromSelectionIdentifier: $0)
                return
                    "The previously selected AI model, \(modelName), is not available. Switching to the first available AI model."
            }
        )
    }

    func selectModel(_ selectionIdentifier: String?) {
        selectModel(selectionIdentifier, fallbackMessage: nil)
    }

    private func selectModel(_ selectionIdentifier: String?, fallbackMessage: String?) {
        selectedModelID = selectionIdentifier
        modelSelection.selectedModelID = selectionIdentifier
        selectedModelFallbackMessage = fallbackMessage
    }

    private static func modelName(fromSelectionIdentifier selectionIdentifier: String) -> String {
        selectionIdentifier.components(separatedBy: "::").last ?? selectionIdentifier
    }

    var enabledPersistedModels: [ModelConfig] {
        persistedModels.filter {
            isAppleFoundationModelEnabled || $0.source != .appleFoundation
        }
    }
}
