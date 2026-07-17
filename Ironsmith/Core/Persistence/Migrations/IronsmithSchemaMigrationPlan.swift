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

enum IronsmithSchemaMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [
            IronsmithSchemaV1.self,
            IronsmithSchemaV2.self,
            IronsmithSchemaV3.self,
            IronsmithSchemaV4.self,
            IronsmithSchemaV5.self,
        ]
    }

    static var stages: [MigrationStage] {
        let scratchpad = IronsmithV1ToV2MigrationScratchpad()

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
                        tool.appKind = values
                            .flatMap { ToolAppKind(rawValue: $0.appKindRawValue) }
                            ?? .window
                        tool.generationState = values
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
                            model.installState = scratchpad.modelInstallStateRawValues[model.id]
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
        ]
    }
}
