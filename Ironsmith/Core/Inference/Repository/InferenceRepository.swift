import Foundation
import SwiftData

@MainActor
struct InferenceRepository {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    var hasChanges: Bool {
        modelContext.hasChanges
    }

    func bootstrapIfNeeded() throws {
        try AppDataBootstrapper.bootstrapIfNeeded(in: modelContext)
    }

    func fetchProviders() throws -> [ProviderConfig] {
        try modelContext.fetch(FetchDescriptor<ProviderConfig>())
            .sorted {
                let lhsSortOrder = ProviderCatalog.descriptor(for: $0.kind)?.sortOrder ?? 900
                let rhsSortOrder = ProviderCatalog.descriptor(for: $1.kind)?.sortOrder ?? 900

                if lhsSortOrder == rhsSortOrder {
                    return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                }
                return lhsSortOrder < rhsSortOrder
            }
    }

    func fetchPersistedModels() throws -> [ModelConfig] {
        try modelContext.fetch(FetchDescriptor<ModelConfig>())
            .filter(\.isPersistedLocalModel)
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func insertProvider(_ provider: ProviderConfig) {
        modelContext.insert(provider)
    }

    func insertPersistedModel(_ model: ModelConfig) throws {
        guard model.isPersistedLocalModel else {
            throw InferenceRepositoryError.cannotPersistRemoteModel
        }
        modelContext.insert(model)
    }

    func removeProvider(_ provider: ProviderConfig) {
        modelContext.delete(provider)
    }

    func deletePersistedModel(_ model: ModelConfig) {
        modelContext.delete(model)
    }

    func save() throws {
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func rollback() {
        modelContext.rollback()
    }
}

enum InferenceRepositoryError: LocalizedError {
    case cannotPersistRemoteModel

    var errorDescription: String? {
        switch self {
        case .cannotPersistRemoteModel:
            return "Remote AI models are transient and cannot be saved to SwiftData."
        }
    }
}
