import SwiftData

enum IronsmithModelContainerFactory {
    static func make(isRunningTests: Bool) throws -> ModelContainer {
        if isRunningTests {
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            return try make(configuration: config)
        }

        let locations = try IronsmithPersistentStoreLocations.live()
        try IronsmithPersistentStorePreparer(locations: locations).prepare()
        return try make(configuration: ModelConfiguration(url: locations.storeURL))
    }

    static func make(configuration: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(
            for: Schema(versionedSchema: IronsmithSchemaV4.self),
            migrationPlan: IronsmithSchemaMigrationPlan.self,
            configurations: configuration
        )
    }
}
