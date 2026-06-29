import SwiftData

enum IronsmithSchemaMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [
            IronsmithSchemaV1.self,
            IronsmithSchemaV2.self,
        ]
    }

    static var stages: [MigrationStage] {
        [
            .custom(
                fromVersion: IronsmithSchemaV1.self,
                toVersion: IronsmithSchemaV2.self,
                willMigrate: nil,
                didMigrate: { context in
                    let tools = try context.fetch(FetchDescriptor<IronsmithSchemaV2.Tool>())
                    for tool in tools {
                        tool.appKind = ToolAppKind(rawValue: tool.legacyAppKindRawValue) ?? .window
                        tool.generationState = ToolGenerationState(rawValue: tool.legacyGenerationStateRawValue) ?? .ready
                        tool.generationPhase = tool.legacyGenerationPhaseRawValue
                            .flatMap(ToolGenerationPhase.init(rawValue:))
                        tool.generationMode = tool.legacyGenerationModeRawValue
                            .flatMap(ToolGenerationMode.init(rawValue:))
                    }

                    let models = try context.fetch(FetchDescriptor<IronsmithSchemaV2.ModelConfig>())
                    for model in models {
                        if model.source == .appleFoundation {
                            model.installState = .builtIn
                        } else {
                            model.installState = ModelInstallState(rawValue: model.legacyInstallStateRawValue)
                                ?? .downloadable
                        }
                    }

                    try context.save()
                }
            ),
        ]
    }
}
