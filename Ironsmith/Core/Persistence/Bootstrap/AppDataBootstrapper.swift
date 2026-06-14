import FoundationModels
import Foundation
import SwiftData

enum AppDataBootstrapper {
    static func bootstrapIfNeeded(in context: ModelContext) throws {
        try IronsmithPaths.ensureDirectoriesExist()

        let providers = try context.fetch(FetchDescriptor<ProviderConfig>())

        if !providers.contains(where: { $0.identifier == ProviderConfig.localProviderIdentifier }) {
            let provider = ProviderCatalog.makeProvider(for: .local) ?? ProviderConfig(
                identifier: ProviderConfig.localProviderIdentifier,
                displayName: "Local",
                baseURLString: "",
                authMode: .none,
                origin: .builtIn
            )
            context.insert(provider)
        }

        let existingModels = try context.fetch(FetchDescriptor<ModelConfig>())
        if !existingModels.contains(where: {
            $0.identifier == ModelConfig.appleFoundationIdentifier &&
            $0.providerIdentifier == ProviderConfig.localProviderIdentifier
        }) {
            if IronsmithRuntimeEnvironment.isRunningTests || SystemLanguageModel.default.availability == .available {
                let model = ModelConfig(
                    identifier: ModelConfig.appleFoundationIdentifier,
                    displayName: "Apple Foundation Model",
                    providerIdentifier: ProviderConfig.localProviderIdentifier,
                    source: .appleFoundation,
                    installState: .builtIn
                )
                context.insert(model)
            }
        }

        if context.hasChanges {
            try context.save()
        }
    }
}
