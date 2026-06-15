import Foundation
import Observation
import Supabase
import SwiftData

enum OllamaInstallationStatus: Equatable {
    case unknown
    case checking
    case installed
    case notInstalled
}

struct OllamaModelTransferState: Equatable {
    var status: String
    var progress: Double?
}

struct ProviderConnectionIssue: Equatable {
    var message: String
}

enum InferenceMessages {
    static let noAvailableModels =
        "No AI model is available. Go to Settings to add an AI model provider."
}

@MainActor
@Observable
final class InferenceStore {
    static let onboardingPreferredIronsmithModelIdentifier = "deepseek/deepseek-v4-flash"

    struct ProviderChoice: Identifiable, Hashable {
        let kind: ProviderKind
        let title: String

        var id: ProviderKind { kind }

        init(descriptor: ProviderDescriptor) {
            kind = descriptor.kind
            title = descriptor.displayName
        }
    }

    var providers: [ProviderConfig] = []
    var persistedModels: [ModelConfig] = []
    var remoteModels: [ModelConfig] = []
    var selectedModelID: String?
    var presentedErrorMessage: String?
    var ollamaInstallationStatus: OllamaInstallationStatus = .unknown
    var ollamaPullStates: [String: OllamaModelTransferState] = [:]
    var ollamaDeletingModelKeys: Set<String> = []
    var providerConnectionIssues: [String: ProviderConnectionIssue] = [:]
    var startingOllamaProviderIDs: Set<String> = []
    var selectedModelFallbackMessage: String?
    var ironsmithSession: Session?
    var ironsmithAccountSummary: IronsmithAccountSummary?
    var ironsmithCreditPacks: [IronsmithCreditPack] = []
    var isRefreshingIronsmithAccount = false
    var isRefreshingIronsmithCreditPacks = false
    var isCreatingIronsmithCheckoutSession = false
    var generationPreferences: GenerationPreferencesStore
    var modelSelection: ModelSelectionStore

    // Internal coordination state shared by the responsibility-focused InferenceStore extensions.
    var hasLoaded = false
    var isLoading = false
    var pendingIronsmithAccountRefreshAfterCheckout = false
    var repository: InferenceRepository?
    let dependencies: InferenceDependencies

    init(
        dependencies: InferenceDependencies? = nil,
        generationPreferences: GenerationPreferencesStore? = nil,
        modelSelection: ModelSelectionStore? = nil
    ) {
        self.dependencies = dependencies ?? .live
        self.generationPreferences = generationPreferences ?? GenerationPreferencesStore()
        self.modelSelection = modelSelection ?? ModelSelectionStore()
        selectedModelID = self.modelSelection.selectedModelID
    }

    var hasLoadedModels: Bool {
        hasLoaded
    }

    func loadIfNeeded(modelContext: ModelContext) async {
        if repository == nil {
            repository = InferenceRepository(modelContext: modelContext)
        }
        guard !hasLoaded, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            try repository?.bootstrapIfNeeded()
            try refreshData(reconcileSelection: false)
        } catch {
            presentError(error)
            return
        }

        ironsmithSession = dependencies.accountClient.currentSession()
        let selectedRemoteProvider = providers.first { provider in
            provider.kind != .local
                && selectedModelID?.hasPrefix("\(provider.identifier)::") == true
        }
        if let selectedRemoteProvider {
            await refreshDiscoveredModels(for: selectedRemoteProvider)
        }

        reconcileSelectedModel()
        hasLoaded = true

        let backgroundProviders = providers.filter {
            $0.kind != .local && $0.identifier != selectedRemoteProvider?.identifier
        }
        guard !backgroundProviders.isEmpty else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            for provider in backgroundProviders {
                await refreshDiscoveredModels(for: provider)
            }
            reconcileSelectedModel()
        }
    }

    func prepareSettings(modelContext: ModelContext) async {
        await loadIfNeeded(modelContext: modelContext)
        await refreshServerProvidersForSettings()
    }

    func clearPresentedError() {
        presentedErrorMessage = nil
    }

    func presentError(_ error: Error) {
        guard let message = IronsmithErrorPresentation.message(for: error) else {
            return
        }
        presentedErrorMessage = message
    }

    func saveChanges() {
        guard let repository else { return }
        do {
            try repository.save()
        } catch {
            repository.rollback()
            presentError(error)
        }
    }

    func refreshData(reconcileSelection: Bool = true) throws {
        guard let repository else { return }
        providers = try repository.fetchProviders()
        persistedModels = try repository.fetchPersistedModels()
        if reconcileSelection {
            reconcileSelectedModel()
        }
    }
}

enum InferenceStoreError: LocalizedError {
    case missingSelectedModel
    case insufficientIronsmithCredits

    var errorDescription: String? {
        switch self {
        case .missingSelectedModel:
            return InferenceMessages.noAvailableModels
        case .insufficientIronsmithCredits:
            return
                "Your AI credits have run out. Buy more below, or switch to a local or API-key model to keep going."
        }
    }
}

enum ProviderCreationError: LocalizedError {
    case invalidBaseURL
    case missingDisplayName
    case missingAPIKey
    case ollamaNotInstalled
    case unsupportedProvider

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Enter a valid provider base URL."
        case .missingDisplayName:
            return "Enter a display name for the provider."
        case .missingAPIKey:
            return "Enter an API key before adding the provider."
        case .ollamaNotInstalled:
            return "Install Ollama before adding it as a provider."
        case .unsupportedProvider:
            return "This provider is not available."
        }
    }
}
