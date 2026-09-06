import Foundation
import SwiftData

private struct IronsmithV1ToolMigrationValues {
    let appKindRawValue: String
    let generationStateRawValue: String
    let generationPhaseRawValue: String?
    let generationModeRawValue: String?
}

private final class IronsmithV1ToV2MigrationScratchpad: @unchecked Sendable {
    var toolValues: [UUID: IronsmithV1ToolMigrationValues] = [:]
    var modelInstallStateRawValues: [UUID: String] = [:]

    func reset() {
        toolValues = [:]
        modelInstallStateRawValues = [:]
    }
}

private struct IronsmithV8ToolMigrationValues {
    let packageRootPath: String
    let generationState: ToolGenerationState
    let storeId: String?
    let storeAppId: String?
    let storeVersionId: String?
    let storeVersionNumber: Int?
    let storeSourceSha256: String?
    let storeRemixedFromVersionId: String?
    let storeInspiredByVersionIdsRawValue: String?
    let contextSnapshot: StoreGenerationContextSnapshot?
}

private final class IronsmithV8ToV9MigrationScratchpad: @unchecked Sendable {
    var toolValues: [UUID: IronsmithV8ToolMigrationValues] = [:]

    func reset() {
        toolValues = [:]
    }
}

enum IronsmithSchemaMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [
            IronsmithSchemaV1.self,
            IronsmithSchemaV2.self,
            IronsmithSchemaV3.self,
            IronsmithSchemaV4.self,
            IronsmithSchemaV5.self,
            IronsmithSchemaV6.self,
            IronsmithSchemaV7.self,
            IronsmithSchemaV8.self,
            IronsmithSchemaV9.self,
        ]
    }

    static var stages: [MigrationStage] {
        let scratchpad = IronsmithV1ToV2MigrationScratchpad()
        let storeRemixScratchpad = IronsmithV8ToV9MigrationScratchpad()

        return [
            .custom(
                fromVersion: IronsmithSchemaV1.self,
                toVersion: IronsmithSchemaV2.self,
                willMigrate: { context in
                    let tools = try context.fetch(FetchDescriptor<IronsmithSchemaV1.Tool>())
                    scratchpad.toolValues = Dictionary(
                        uniqueKeysWithValues: tools.map { tool in
                            (
                                tool.id,
                                IronsmithV1ToolMigrationValues(
                                    appKindRawValue: tool.appKindRawValue,
                                    generationStateRawValue: tool.generationStateRawValue,
                                    generationPhaseRawValue: tool.generationPhaseRawValue,
                                    generationModeRawValue: tool.generationModeRawValue
                                )
                            )
                        }
                    )

                    let models = try context.fetch(FetchDescriptor<IronsmithSchemaV1.ModelConfig>())
                    scratchpad.modelInstallStateRawValues = Dictionary(
                        uniqueKeysWithValues: models.map { model in
                            (model.id, model.installStateRaw)
                        }
                    )
                },
                didMigrate: { context in
                    defer { scratchpad.reset() }

                    let tools = try context.fetch(FetchDescriptor<IronsmithSchemaV2.Tool>())
                    for tool in tools {
                        let values = scratchpad.toolValues[tool.id]
                        tool.appKind =
                            values
                            .flatMap { ToolAppKind(rawValue: $0.appKindRawValue) }
                            ?? .window
                        tool.generationState =
                            values
                            .flatMap { ToolGenerationState(rawValue: $0.generationStateRawValue) }
                            ?? .ready
                        tool.generationPhase = values?.generationPhaseRawValue
                            .flatMap(ToolGenerationPhase.init(rawValue:))
                        tool.generationMode = values?.generationModeRawValue
                            .flatMap(ToolGenerationMode.init(rawValue:))
                    }

                    let models = try context.fetch(FetchDescriptor<IronsmithSchemaV2.ModelConfig>())
                    for model in models {
                        if model.source == .appleFoundation {
                            model.installState = .builtIn
                        } else {
                            model.installState =
                                scratchpad.modelInstallStateRawValues[model.id]
                                .flatMap(ModelInstallState.init(rawValue:))
                                ?? .downloadable
                        }
                    }

                    try context.save()
                }
            ),
            .custom(
                fromVersion: IronsmithSchemaV2.self,
                toVersion: IronsmithSchemaV3.self,
                willMigrate: nil,
                didMigrate: { context in
                    let models = try context.fetch(FetchDescriptor<IronsmithSchemaV3.ModelConfig>())
                    for model in models where model.source == .mlx {
                        context.delete(model)
                    }

                    try context.save()
                }
            ),
            .custom(
                fromVersion: IronsmithSchemaV3.self,
                toVersion: IronsmithSchemaV4.self,
                willMigrate: nil,
                didMigrate: { context in
                    let models = try context.fetch(
                        FetchDescriptor<IronsmithSchemaV4.ModelConfig>()
                    )
                    for model in models {
                        model.reasoningEffortRawValues = nil
                    }

                    let providers = try context.fetch(
                        FetchDescriptor<IronsmithSchemaV4.ProviderConfig>()
                    )
                    for provider in providers {
                        provider.openAICompatibleAPIVariant = .chatCompletions
                    }
                    try context.save()
                }
            ),
            .lightweight(
                fromVersion: IronsmithSchemaV4.self,
                toVersion: IronsmithSchemaV5.self
            ),
            .custom(
                fromVersion: IronsmithSchemaV5.self,
                toVersion: IronsmithSchemaV6.self,
                willMigrate: nil,
                didMigrate: { context in
                    let tools = try context.fetch(
                        FetchDescriptor<IronsmithSchemaV6.Tool>()
                    )
                    for tool in tools {
                        tool.category = .utilities
                    }
                    try context.save()
                }
            ),
            .lightweight(
                fromVersion: IronsmithSchemaV6.self,
                toVersion: IronsmithSchemaV7.self
            ),
            .lightweight(
                fromVersion: IronsmithSchemaV7.self,
                toVersion: IronsmithSchemaV8.self
            ),
            .custom(
                fromVersion: IronsmithSchemaV8.self,
                toVersion: IronsmithSchemaV9.self,
                willMigrate: { context in
                    let tools = try context.fetch(FetchDescriptor<IronsmithSchemaV8.Tool>())
                    storeRemixScratchpad.toolValues = Dictionary(
                        uniqueKeysWithValues: tools.map { tool in
                            let snapshot = tool.storeGenerationContextPayloadJSON
                                .flatMap { $0.data(using: .utf8) }
                                .flatMap {
                                    try? JSONDecoder().decode(
                                        StoreGenerationContextSnapshot.self,
                                        from: $0
                                    )
                                }
                            return (
                                tool.id,
                                IronsmithV8ToolMigrationValues(
                                    packageRootPath: tool.packageRootPath,
                                    generationState: tool.generationState,
                                    storeId: tool.storeId,
                                    storeAppId: tool.storeAppId,
                                    storeVersionId: tool.storeVersionId,
                                    storeVersionNumber: tool.storeVersionNumber,
                                    storeSourceSha256: tool.storeSourceSha256,
                                    storeRemixedFromVersionId: tool.storeRemixedFromVersionId,
                                    storeInspiredByVersionIdsRawValue:
                                        tool.storeInspiredByVersionIdsRawValue,
                                    contextSnapshot: snapshot
                                )
                            )
                        }
                    )

                },
                didMigrate: { context in
                    defer { storeRemixScratchpad.reset() }
                    let tools = try context.fetch(FetchDescriptor<IronsmithSchemaV9.Tool>())
                    for tool in tools {
                        guard let values = storeRemixScratchpad.toolValues[tool.id] else {
                            continue
                        }
                        let snapshotProvenance = values.contextSnapshot.map(
                            IronsmithV8StoreMigration.provenance
                        )
                        let legacySource = IronsmithV8StoreMigration.legacySource(values)
                        let fallbackSource = values.storeRemixedFromVersionId.map {
                            StoreVersionReference(versionId: $0)
                        }
                        let rawInspirations = IronsmithV8StoreMigration.references(
                            rawValue: values.storeInspiredByVersionIdsRawValue
                        )
                        let inspirations = IronsmithV8StoreMigration.mergedInspirations(
                            snapshot: values.contextSnapshot,
                            snapshotProvenance: snapshotProvenance,
                            rawInspirations: rawInspirations
                        )
                        let provenance = StoreProvenance(
                            remixSource: legacySource
                                ?? snapshotProvenance?.remixSource
                                ?? fallbackSource,
                            inspirations: inspirations
                        ).normalized
                        tool.storeMetadata = provenance.map {
                            ToolStoreMetadata(provenance: $0)
                        }

                        if values.generationState != .ready,
                            let snapshot = values.contextSnapshot
                        {
                            try? ToolStoreRemixStateClient.live.stage(
                                snapshot,
                                URL(
                                    fileURLWithPath: values.packageRootPath,
                                    isDirectory: true
                                )
                            )
                        } else {
                            try? ToolStoreRemixStateClient.live.clear(
                                URL(
                                    fileURLWithPath: values.packageRootPath,
                                    isDirectory: true
                                )
                            )
                        }
                    }
                    try context.save()
                }
            ),
        ]
    }
}

private enum IronsmithV8StoreMigration {
    static func legacySource(
        _ values: IronsmithV8ToolMigrationValues
    ) -> StoreVersionReference? {
        guard let versionId = values.storeVersionId else { return nil }
        return StoreVersionReference(
            versionId: versionId,
            storeId: values.storeId,
            appId: values.storeAppId,
            appName: nil,
            versionNumber: values.storeVersionNumber,
            sourceSha256: values.storeSourceSha256
        )
    }

    static func provenance(
        _ snapshot: StoreGenerationContextSnapshot
    ) -> StoreProvenance {
        let plan = snapshot.plan
        let remixSource = plan.base.map {
            StoreVersionReference(
                versionId: $0.versionId,
                storeId: $0.storeId,
                appId: $0.appId,
                appName: $0.appName,
                versionNumber: $0.versionNumber,
                sourceSha256: $0.sourceSha256
            )
        }
        let inspirations: [StoreVersionReference] = plan.inspirations.map { inspiration in
            return StoreVersionReference(
                versionId: inspiration.versionId,
                storeId: inspiration.storeId,
                appId: inspiration.appId,
                appName: inspiration.appName,
                versionNumber: nil,
                sourceSha256: nil
            )
        }
        return StoreProvenance(
            remixSource: remixSource,
            inspirations: inspirations
        ).normalized ?? StoreProvenance(remixSource: nil, inspirations: [])
    }

    static func references(rawValue: String?) -> [StoreVersionReference] {
        rawValue?
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { StoreVersionReference(versionId: String($0)) } ?? []
    }

    static func mergedInspirations(
        snapshot: StoreGenerationContextSnapshot?,
        snapshotProvenance: StoreProvenance?,
        rawInspirations: [StoreVersionReference]
    ) -> [StoreVersionReference] {
        var inspirations = snapshotProvenance?.inspirations ?? []
        var representedVersionIDs = Set(inspirations.map(\.versionId))
        let unresolvedReferences =
            (snapshot?.plan.inspirations.map {
                StoreVersionReference(versionId: $0.versionId)
            } ?? []) + rawInspirations
        inspirations.append(
            contentsOf: unresolvedReferences.filter {
                representedVersionIDs.insert($0.versionId).inserted
            }
        )
        return inspirations
    }
}
