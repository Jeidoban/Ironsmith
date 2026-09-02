import Foundation
import SwiftData

enum IronsmithSchemaV9: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(9, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [Tool.self, ModelConfig.self, ProviderConfig.self]
    }

    struct StoreVersionReference: Codable, Equatable, Identifiable, Sendable {
        var versionId: String
        var storeId: String? = nil
        var appId: String? = nil
        var appName: String? = nil
        var versionNumber: Int? = nil
        var sourceSha256: String? = nil

        var id: String { versionId }
    }

    struct StorePublication: Codable, Equatable, Sendable {
        var storeId: String
        var appId: String
        var versionId: String
        var versionNumber: Int
        var sourceSha256: String
        var ownerUserId: String
        var publishedAt: Date
    }

    struct StoreProvenance: Codable, Equatable, Sendable {
        var remixSource: StoreVersionReference?
        var inspirations: [StoreVersionReference]
    }

    struct StoreMetadata: Codable, Equatable, Sendable {
        var publication: StorePublication? = nil
        var provenance: StoreProvenance? = nil
    }

    @Model
    final class Tool {
        @Attribute(.unique) var id: UUID
        var name: String
        var executableName: String
        var bundleIdentifier: String
        var category: StoreAppCategory = StoreAppCategory.utilities
        var sandboxEnabled: Bool
        var appKind: ToolAppKind = ToolAppKind.window
        var menuBarSystemImage: String = ToolMenuBarSymbol.fallback
        var sandboxPermissionRawValues: String?
        var resourcePermissionRawValues: String?
        var packageRootPath: String
        var generationState: ToolGenerationState = ToolGenerationState.ready
        var generationPhase: ToolGenerationPhase? = ToolGenerationPhase.completed
        var generationMode: ToolGenerationMode?
        var pendingPrompt: String?
        var generationErrorSummary: String?
        var generationRepairErrorCount: Int? = nil
        var storeMetadataData: Data?
        var createdAt: Date
        var updatedAt: Date

        init(
            id: UUID = UUID(),
            name: String,
            executableName: String? = nil,
            bundleIdentifier: String? = nil,
            category: StoreAppCategory = .utilities,
            sandboxEnabled: Bool = true,
            appKind: ToolAppKind = .window,
            menuBarSystemImage: String = ToolMenuBarSymbol.fallback,
            sandboxPermissions: GeneratedAppSandboxPermissions? = nil,
            resourcePermissions: GeneratedAppResourcePermissions? = nil,
            packageRootPath: String,
            generationState: ToolGenerationState = .ready,
            generationPhase: ToolGenerationPhase? = .completed,
            generationMode: ToolGenerationMode? = nil,
            pendingPrompt: String? = nil,
            generationErrorSummary: String? = nil,
            generationRepairErrorCount: Int? = nil,
            storeMetadata: StoreMetadata? = nil,
            createdAt: Date = .now,
            updatedAt: Date = .now
        ) {
            self.id = id
            self.name = name
            let resolvedExecutableName =
                executableName ?? ToolNameSanitizer.executableName(from: name)
            self.executableName = resolvedExecutableName
            self.bundleIdentifier =
                bundleIdentifier
                ?? ToolBundleIdentifier.make(executableName: resolvedExecutableName)
            self.category = category
            self.sandboxEnabled = sandboxEnabled
            self.appKind = appKind
            self.menuBarSystemImage = ToolMenuBarSymbol.validated(menuBarSystemImage)
            self.sandboxPermissionRawValues = sandboxPermissions?.rawValueList
            self.resourcePermissionRawValues = resourcePermissions?.rawValueList
            self.packageRootPath = packageRootPath
            self.generationState = generationState
            self.generationPhase = generationPhase
            self.generationMode = generationMode
            self.pendingPrompt = pendingPrompt
            self.generationErrorSummary = generationErrorSummary
            self.generationRepairErrorCount = generationRepairErrorCount
            self.storeMetadataData = storeMetadata.flatMap { try? JSONEncoder().encode($0) }
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    @Model
    final class ModelConfig {
        @Attribute(.unique) var id: UUID
        var identifier: String
        var displayName: String
        var providerIdentifier: String
        var source: ModelSource
        var installState: ModelInstallState
        var estimatedToolCredits: Int?
        var reasoningEffortRawValues: String?
        var supportsImageInput: Bool = false
        var contextWindowTokens: Int?

        init(
            id: UUID = UUID(),
            identifier: String,
            displayName: String,
            providerIdentifier: String,
            source: ModelSource,
            installState: ModelInstallState = .downloadable,
            estimatedToolCredits: Int? = nil,
            reasoningEfforts: [ToolReasoningEffort] = [],
            supportsImageInput: Bool = false,
            contextWindowTokens: Int? = nil
        ) {
            self.id = id
            self.identifier = identifier
            self.displayName = displayName
            self.providerIdentifier = providerIdentifier
            self.source = source
            self.installState = source == .appleFoundation ? .builtIn : installState
            self.estimatedToolCredits = estimatedToolCredits
            self.reasoningEffortRawValues =
                reasoningEfforts
                .filter { $0 != .default }
                .map(\.rawValue)
                .joined(separator: ",")
            self.supportsImageInput = supportsImageInput
            self.contextWindowTokens = contextWindowTokens
        }
    }

    @Model
    final class ProviderConfig {
        @Attribute(.unique) var id: UUID
        var identifier: String
        var displayName: String
        @Attribute(originalName: "baseURLTemplate") var baseURLString: String
        var authMode: ProviderAuthMode
        var origin: ProviderOrigin
        var isEnabled: Bool
        var openAICompatibleAPIVariant: OpenAICompatibleAPIVariant =
            OpenAICompatibleAPIVariant.chatCompletions

        init(
            id: UUID = UUID(),
            identifier: String,
            displayName: String,
            baseURLString: String,
            authMode: ProviderAuthMode,
            origin: ProviderOrigin,
            isEnabled: Bool = true,
            openAICompatibleAPIVariant: OpenAICompatibleAPIVariant = .chatCompletions
        ) {
            self.id = id
            self.identifier = identifier
            self.displayName = displayName
            self.baseURLString = baseURLString
            self.authMode = authMode
            self.origin = origin
            self.isEnabled = isEnabled
            self.openAICompatibleAPIVariant = openAICompatibleAPIVariant
        }
    }
}
