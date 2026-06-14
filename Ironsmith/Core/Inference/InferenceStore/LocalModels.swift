import Foundation

extension InferenceStore {
    func downloadFromCatalog(_ entry: MLXModelCatalog.Entry) {
        guard let repository else { return }
        guard providers.contains(where: { $0.kind == .local }) else { return }
        guard !persistedModels.contains(where: { $0.identifier == entry.identifier }) else {
            return
        }

        let model = ModelConfig(
            identifier: entry.identifier,
            displayName: entry.displayName,
            providerIdentifier: ProviderConfig.localProviderIdentifier,
            source: .mlx,
            installState: .downloading,
            localDirectoryPath: nil,
            downloadProgress: 0
        )

        do {
            try repository.insertPersistedModel(model)
            try repository.save()
            try refreshData()
            downloadLocalModel(model)
        } catch {
            repository.rollback()
            presentError(error)
        }
    }

    func downloadLocalModel(_ model: ModelConfig) {
        let modelID = model.id
        model.installState = .downloading
        model.downloadProgress = 0
        saveChanges()

        Task { @MainActor in
            do {
                let directory = try await dependencies.localModelClient.downloadModel(
                    model.identifier
                ) { progress in
                    Task { @MainActor in
                        guard let model = self.persistedModels.first(where: { $0.id == modelID })
                        else { return }
                        model.downloadProgress = progress
                        self.saveChanges()
                    }
                }

                guard let model = self.persistedModels.first(where: { $0.id == modelID }) else {
                    return
                }
                model.localDirectoryPath = directory.path
                model.installState = .installed
                model.downloadProgress = 1
                self.saveChanges()
                self.reconcileSelectedModel()
            } catch {
                guard let model = self.persistedModels.first(where: { $0.id == modelID }) else {
                    return
                }
                self.repository?.deletePersistedModel(model)
                self.saveChanges()
                try? self.refreshData()
                self.presentError(error)
            }
        }
    }

    func deleteLocalModel(_ model: ModelConfig) {
        guard let repository else { return }
        guard model.isPersistedLocalModel else { return }

        do {
            try dependencies.localModelClient.deleteModel(model.identifier)
        } catch {
            presentError(error)
            return
        }

        repository.deletePersistedModel(model)
        saveChanges()
        try? refreshData()
        reconcileSelectedModel()
    }
}
