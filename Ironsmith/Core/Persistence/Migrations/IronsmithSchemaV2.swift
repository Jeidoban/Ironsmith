import Foundation
import SwiftData

enum IronsmithSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version {
        Schema.Version(2, 0, 0)
    }

    static var models: [any PersistentModel.Type] {
        [
            Tool.self,
            ModelConfig.self,
            ProviderConfig.self,
        ]
    }

    @Model
    final class Tool {
        @Attribute(.unique) var id: UUID
        var name: String
        var executableName: String
        var bundleIdentifier: String
        var sandboxEnabled: Bool
        var appKind: ToolAppKind = ToolAppKind.window
        @Attribute(originalName: "appKindRawValue") var legacyAppKindRawValue: String = ToolAppKind.window.rawValue
        var menuBarSystemImage: String = ToolMenuBarSymbol.fallback
        var sandboxPermissionRawValues: String?
        var resourcePermissionRawValues: String?
        var packageRootPath: String
        var generationState: ToolGenerationState = ToolGenerationState.ready
        @Attribute(originalName: "generationStateRawValue") var legacyGenerationStateRawValue: String = ToolGenerationState.ready.rawValue
        var generationPhase: ToolGenerationPhase? = ToolGenerationPhase.completed
        @Attribute(originalName: "generationPhaseRawValue") var legacyGenerationPhaseRawValue: String?
        var generationMode: ToolGenerationMode?
        @Attribute(originalName: "generationModeRawValue") var legacyGenerationModeRawValue: String?
        var pendingPrompt: String?
        var generationErrorSummary: String?
        var generationRepairErrorCount: Int? = nil
        var storeId: String?
        var storeAppId: String?
        var storeVersionId: String?
        var storeVersionNumber: Int?
        var storeSourceSha256: String?
        var storeImportedAt: Date?
        var storeRemixedFromVersionId: String?
        var createdAt: Date
        var updatedAt: Date

        init(
            id: UUID = UUID(),
            name: String,
            executableName: String? = nil,
            bundleIdentifier: String? = nil,
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
            storeId: String? = nil,
            storeAppId: String? = nil,
            storeVersionId: String? = nil,
            storeVersionNumber: Int? = nil,
            storeSourceSha256: String? = nil,
            storeImportedAt: Date? = nil,
            storeRemixedFromVersionId: String? = nil,
            createdAt: Date = .now,
            updatedAt: Date = .now
        ) {
            self.id = id
            self.name = name
            let resolvedExecutableName = executableName ?? ToolNameSanitizer.executableName(from: name)
            self.executableName = resolvedExecutableName
            self.bundleIdentifier = bundleIdentifier ?? ToolBundleIdentifier.make(executableName: resolvedExecutableName)
            self.sandboxEnabled = sandboxEnabled
            self.appKind = appKind
            self.legacyAppKindRawValue = appKind.rawValue
            self.menuBarSystemImage = ToolMenuBarSymbol.validated(menuBarSystemImage)
            self.sandboxPermissionRawValues = sandboxPermissions?.rawValueList
            self.resourcePermissionRawValues = resourcePermissions?.rawValueList
            self.packageRootPath = packageRootPath
            self.generationState = generationState
            self.legacyGenerationStateRawValue = generationState.rawValue
            self.generationPhase = generationPhase
            self.legacyGenerationPhaseRawValue = generationPhase?.rawValue
            self.generationMode = generationMode
            self.legacyGenerationModeRawValue = generationMode?.rawValue
            self.pendingPrompt = pendingPrompt
            self.generationErrorSummary = generationErrorSummary
            self.generationRepairErrorCount = generationRepairErrorCount
            self.storeId = storeId
            self.storeAppId = storeAppId
            self.storeVersionId = storeVersionId
            self.storeVersionNumber = storeVersionNumber
            self.storeSourceSha256 = storeSourceSha256
            self.storeImportedAt = storeImportedAt
            self.storeRemixedFromVersionId = storeRemixedFromVersionId
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
        var localDirectoryPath: String?
        var downloadProgress: Double?
        var installState: ModelInstallState
        @Attribute(originalName: "installStateRaw") var legacyInstallStateRawValue: String
        var estimatedToolCredits: Int?

        init(
            id: UUID = UUID(),
            identifier: String,
            displayName: String,
            providerIdentifier: String,
            source: ModelSource,
            installState: ModelInstallState = .downloadable,
            localDirectoryPath: String? = nil,
            downloadProgress: Double? = nil,
            estimatedToolCredits: Int? = nil
        ) {
            self.id = id
            self.identifier = identifier
            self.displayName = displayName
            self.providerIdentifier = providerIdentifier
            self.source = source
            let resolvedInstallState: ModelInstallState = source == .appleFoundation ? .builtIn : installState
            self.installState = resolvedInstallState
            self.legacyInstallStateRawValue = resolvedInstallState.rawValue
            self.localDirectoryPath = localDirectoryPath
            self.downloadProgress = downloadProgress
            self.estimatedToolCredits = estimatedToolCredits
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

        init(
            id: UUID = UUID(),
            identifier: String,
            displayName: String,
            baseURLString: String,
            authMode: ProviderAuthMode,
            origin: ProviderOrigin,
            isEnabled: Bool = true
        ) {
            self.id = id
            self.identifier = identifier
            self.displayName = displayName
            self.baseURLString = baseURLString
            self.authMode = authMode
            self.origin = origin
            self.isEnabled = isEnabled
        }
    }
}
