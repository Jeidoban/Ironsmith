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
}
