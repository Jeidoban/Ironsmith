import SwiftData

enum IronsmithSchemaMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [
            IronsmithSchemaV1.self,
        ]
    }

    static var stages: [MigrationStage] {
        []
    }
}
