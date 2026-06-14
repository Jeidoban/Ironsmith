import SwiftData

enum IronsmithModelContainerFactory {
    static func make(isRunningTests: Bool) throws -> ModelContainer {
        if isRunningTests {
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            return try ModelContainer(
                for: Tool.self,
                ModelConfig.self,
                ProviderConfig.self,
                configurations: config
            )
        }

        return try ModelContainer(for: Tool.self, ModelConfig.self, ProviderConfig.self)
    }
}
