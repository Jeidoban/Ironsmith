import Foundation
import SwiftData
import Testing
@testable import Ironsmith

struct PersistenceTests {
    @MainActor
    @Test
    func inMemoryModelContainerSupportsPhaseTwoSchema() throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)

        let provider = ProviderConfig(
            identifier: "local",
            displayName: "Local",
            baseURLString: "",
            authMode: .none,
            origin: .builtIn
        )
        context.insert(provider)

        let tool = Tool(name: "Clipboard Cleaner", packageRootPath: "/tmp/clipboard-cleaner")
        context.insert(tool)

        let model = ModelConfig(
            identifier: "local.apple-foundation",
            displayName: "Apple Foundation Model",
            providerIdentifier: provider.identifier,
            source: .appleFoundation,
            installState: .builtIn
        )
        context.insert(model)

        try context.save()

        #expect(try context.fetch(FetchDescriptor<Tool>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<ModelConfig>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<ProviderConfig>()).count == 1)
        #expect(tool.executableName == "ClipboardCleaner")
        #expect(tool.bundleIdentifier.hasPrefix("com.ironsmith.generated.clipboardcleaner."))
        #expect(tool.sandboxEnabled)
        #expect(tool.appBundleURL.lastPathComponent == "Clipboard Cleaner.app")
    }

    @MainActor
    @Test
    func diskBackedModelContainerReopensCurrentToolSchema() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("ironsmith.sqlite")
        let config = ModelConfiguration(url: storeURL)

        do {
            let container = try ModelContainer(
                for: Tool.self,
                ModelConfig.self,
                ProviderConfig.self,
                configurations: config
            )
            let context = ModelContext(container)
            context.insert(
                Tool(
                    name: "Incomplete",
                    packageRootPath: "/tmp/incomplete",
                    generationState: .stopped,
                    generationPhase: .generatingSource,
                    generationMode: .create,
                    pendingPrompt: "Build a resumable app"
                )
            )
            try context.save()
        }

        do {
            let container = try IronsmithModelContainerFactory.make(configuration: config)
            let context = ModelContext(container)
            let tool = try #require(try context.fetch(FetchDescriptor<Tool>()).first)
            #expect(tool.generationState == ToolGenerationState.stopped)
            #expect(tool.generationPhase == ToolGenerationPhase.generatingSource)
            #expect(tool.generationMode == ToolGenerationMode.create)
            #expect(tool.pendingPrompt == "Build a resumable app")
            #expect(container.schema.version == IronsmithSchemaV1.versionIdentifier)
            #expect(container.migrationPlan != nil)
        }
    }

    @MainActor
    @Test
    func legacyStoreIsCopiedBackedUpAndReopenedWithoutDeletingSource() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let legacyDirectoryURL = root.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectoryURL, withIntermediateDirectories: true)
        let legacyStoreURL = legacyDirectoryURL.appendingPathComponent("default.store")

        do {
            let container = try ModelContainer(
                for: Tool.self,
                ModelConfig.self,
                ProviderConfig.self,
                configurations: ModelConfiguration(url: legacyStoreURL)
            )
            let context = ModelContext(container)
            context.insert(Tool(name: "Legacy Tool", packageRootPath: "/tmp/legacy-tool"))
            try context.save()
        }

        let locations = IronsmithPersistentStoreLocations(
            databaseDirectoryURL: root
                .appendingPathComponent(".ironsmith", isDirectory: true)
                .appendingPathComponent("db", isDirectory: true),
            legacyStoreURL: legacyStoreURL
        )
        try IronsmithPersistentStorePreparer(locations: locations)
            .prepare(startupDate: Date(timeIntervalSince1970: 1_750_000_000))

        #expect(FileManager.default.fileExists(atPath: legacyStoreURL.path))
        #expect(FileManager.default.fileExists(atPath: locations.storeURL.path))

        let backupDirectoryURL = try #require(
            try Self.startupBackupDirectories(in: locations).first
        )
        let backupStoreURL = backupDirectoryURL.appendingPathComponent(IronsmithPaths.databaseFileName)
        #expect(FileManager.default.fileExists(atPath: backupStoreURL.path))

        do {
            let container = try IronsmithModelContainerFactory.make(
                configuration: ModelConfiguration(url: locations.storeURL)
            )
            let context = ModelContext(container)
            let tool = try #require(try context.fetch(FetchDescriptor<Tool>()).first)
            #expect(tool.name == "Legacy Tool")
        }

        do {
            let container = try IronsmithModelContainerFactory.make(
                configuration: ModelConfiguration(url: backupStoreURL)
            )
            let context = ModelContext(container)
            let tool = try #require(try context.fetch(FetchDescriptor<Tool>()).first)
            #expect(tool.name == "Legacy Tool")
        }
    }

    @Test
    func existingStoreIsBackedUpInsteadOfBeingReplacedByLegacyStore() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let legacyStoreURL = root.appendingPathComponent("legacy/default.store")
        try FileManager.default.createDirectory(
            at: legacyStoreURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("legacy".utf8).write(to: legacyStoreURL)

        let locations = IronsmithPersistentStoreLocations(
            databaseDirectoryURL: root
                .appendingPathComponent(".ironsmith", isDirectory: true)
                .appendingPathComponent("db", isDirectory: true),
            legacyStoreURL: legacyStoreURL
        )
        try FileManager.default.createDirectory(
            at: locations.databaseDirectoryURL,
            withIntermediateDirectories: true
        )
        try Data("current".utf8).write(to: locations.storeURL)

        try IronsmithPersistentStorePreparer(locations: locations)
            .prepare(startupDate: Date(timeIntervalSince1970: 1_750_000_000))

        #expect(try Data(contentsOf: locations.storeURL) == Data("current".utf8))
        #expect(try Data(contentsOf: legacyStoreURL) == Data("legacy".utf8))

        let backupDirectoryURL = try #require(
            try Self.startupBackupDirectories(in: locations).first
        )
        let backupStoreURL = backupDirectoryURL.appendingPathComponent(IronsmithPaths.databaseFileName)
        #expect(try Data(contentsOf: backupStoreURL) == Data("current".utf8))
    }

    @Test
    func startupBackupsRetainOnlyTheThreeNewestSnapshots() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let locations = IronsmithPersistentStoreLocations(
            databaseDirectoryURL: root
                .appendingPathComponent(".ironsmith", isDirectory: true)
                .appendingPathComponent("db", isDirectory: true),
            legacyStoreURL: root.appendingPathComponent("legacy/default.store")
        )
        try FileManager.default.createDirectory(
            at: locations.databaseDirectoryURL,
            withIntermediateDirectories: true
        )
        try Data("current".utf8).write(to: locations.storeURL)

        let preparer = IronsmithPersistentStorePreparer(locations: locations)
        for offset in 0..<5 {
            try preparer.prepare(
                startupDate: Date(timeIntervalSince1970: 1_750_000_000 + Double(offset))
            )
        }

        let backupNames = try Self.startupBackupDirectories(in: locations)
            .map(\.lastPathComponent)
            .sorted()

        #expect(backupNames == [
            "20250615-150642-000",
            "20250615-150643-000",
            "20250615-150644-000",
        ])
    }

    @Test
    func persistentStorePathUsesIronsmithDatabaseDirectory() {
        let expectedDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ironsmith/db", isDirectory: true)

        #expect(IronsmithPaths.databaseDirectory == expectedDirectory)
        #expect(
            IronsmithPaths.databaseURL
                == expectedDirectory.appendingPathComponent(IronsmithPaths.databaseFileName)
        )
        #expect(
            IronsmithPaths.databaseBackupsDirectory
                == expectedDirectory.appendingPathComponent("backups", isDirectory: true)
        )
    }

    @Test
    func generatedBundleIdentifiersUseASCIISafeComponents() throws {
        let id = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let bundleIdentifier = ToolBundleIdentifier.make(executableName: "Résumé Helper 東京", id: id)
        let allowedCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789-.")

        #expect(bundleIdentifier == "com.ironsmith.generated.resume-helper.11111111-2222-3333-4444-555555555555")
        #expect(bundleIdentifier.allSatisfy { allowedCharacters.contains($0) })
    }

    @Test
    func welcomeOnboardingStoreDefaultsToIncomplete() {
        let store = Self.makeWelcomeOnboardingStore()

        #expect(!store.hasCompleted)
    }

    @Test
    func welcomeOnboardingStorePersistsCompletionAcrossInstances() {
        let suiteName = "IronsmithTests.WelcomeOnboarding.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)

        let firstStore = WelcomeOnboardingStore(userDefaults: userDefaults)
        firstStore.complete()
        let secondStore = WelcomeOnboardingStore(userDefaults: userDefaults)

        #expect(secondStore.hasCompleted)
    }

    private static func makeWelcomeOnboardingStore() -> WelcomeOnboardingStore {
        let suiteName = "IronsmithTests.WelcomeOnboarding.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        return WelcomeOnboardingStore(userDefaults: userDefaults)
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ironsmith-persistence-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func startupBackupDirectories(
        in locations: IronsmithPersistentStoreLocations
    ) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: locations.backupsDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
    }
}
