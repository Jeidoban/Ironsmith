import Foundation
import SwiftData

enum IronsmithSchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version {
        Schema.Version(3, 0, 0)
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
        var installState: ModelInstallState
        var estimatedToolCredits: Int?

        init(
            id: UUID = UUID(),
            identifier: String,
            displayName: String,
            providerIdentifier: String,
            source: ModelSource,
            installState: ModelInstallState = .downloadable,
            estimatedToolCredits: Int? = nil
        ) {
            self.id = id
            self.identifier = identifier
            self.displayName = displayName
            self.providerIdentifier = providerIdentifier
            self.source = source
            let resolvedInstallState: ModelInstallState = source == .appleFoundation ? .builtIn : installState
            self.installState = resolvedInstallState
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
