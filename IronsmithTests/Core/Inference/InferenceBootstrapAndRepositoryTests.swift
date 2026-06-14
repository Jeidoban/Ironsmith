import AnyLanguageModel
import Foundation
import Supabase
import SwiftData
import Testing
@testable import Ironsmith

extension InferenceTests {
    @MainActor
    @Test
    func appDataBootstrapperSeedsLocalProvider() throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)

        try AppDataBootstrapper.bootstrapIfNeeded(in: context)

        let providers = try context.fetch(FetchDescriptor<ProviderConfig>())

        #expect(providers.contains(where: { $0.identifier == ProviderConfig.localProviderIdentifier }))
    }

    @MainActor
    @Test
    func appDataBootstrapperSeedsAppleFoundationModelDuringTests() throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)

        try AppDataBootstrapper.bootstrapIfNeeded(in: context)

        let models = try context.fetch(FetchDescriptor<ModelConfig>())

        #expect(models.contains {
            $0.identifier == ModelConfig.appleFoundationIdentifier &&
            $0.providerIdentifier == ProviderConfig.localProviderIdentifier &&
            $0.source == .appleFoundation
        })
    }

    @MainActor
    @Test
    func appDataBootstrapperIsIdempotent() throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)

        try AppDataBootstrapper.bootstrapIfNeeded(in: context)
        try AppDataBootstrapper.bootstrapIfNeeded(in: context)

        let providers = try context.fetch(FetchDescriptor<ProviderConfig>())
        #expect(providers.filter { $0.identifier == ProviderConfig.localProviderIdentifier }.count == 1)
    }

    @MainActor
    @Test
    func repositoryRejectsRemoteModels() throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let repository = InferenceRepository(modelContext: context)
        let remoteModel = ModelConfig(
            identifier: "gpt-test",
            displayName: "gpt-test",
            providerIdentifier: ProviderKind.openAI.rawValue,
            source: .remote,
            installState: .installed
        )

        var didThrow = false
        do {
            try repository.insertPersistedModel(remoteModel)
        } catch {
            didThrow = true
        }

        let persistedModels = try context.fetch(FetchDescriptor<ModelConfig>())
        #expect(didThrow)
        #expect(persistedModels.isEmpty)
    }
}
