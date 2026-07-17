import Foundation
import Testing
@testable import Ironsmith

struct FeatureFlagTests {
    @Test
    func storeFeatureFlagDefaultsOff() throws {
        let userDefaults = try Self.makeIsolatedUserDefaults()

        #expect(!IronsmithFeatureFlags.isStoreEnabled(userDefaults: userDefaults))
    }

    @Test
    func storeFeatureFlagReadsAndWritesPreferenceKey() throws {
        let userDefaults = try Self.makeIsolatedUserDefaults()

        IronsmithFeatureFlags.setStoreEnabled(true, userDefaults: userDefaults)
        #expect(IronsmithFeatureFlags.isStoreEnabled(userDefaults: userDefaults))
        #expect(userDefaults.bool(forKey: IronsmithPreferenceKeys.featureStoreEnabled))

        IronsmithFeatureFlags.setStoreEnabled(false, userDefaults: userDefaults)
        #expect(!IronsmithFeatureFlags.isStoreEnabled(userDefaults: userDefaults))
    }

    @Test
    func diagnosticWholeFileRewriteFeatureFlagDefaultsOff() throws {
        let userDefaults = try Self.makeIsolatedUserDefaults()

        #expect(!IronsmithFeatureFlags.isDiagnosticWholeFileRewriteEnabled(
            userDefaults: userDefaults
        ))
    }

    @Test
    func diagnosticWholeFileRewriteFeatureFlagReadsAndWritesPreferenceKey() throws {
        let userDefaults = try Self.makeIsolatedUserDefaults()

        IronsmithFeatureFlags.setDiagnosticWholeFileRewriteEnabled(
            true,
            userDefaults: userDefaults
        )
        #expect(IronsmithFeatureFlags.isDiagnosticWholeFileRewriteEnabled(
            userDefaults: userDefaults
        ))
        #expect(userDefaults.bool(
            forKey: IronsmithPreferenceKeys.featureDiagnosticWholeFileRewriteEnabled
        ))

        IronsmithFeatureFlags.setDiagnosticWholeFileRewriteEnabled(
            false,
            userDefaults: userDefaults
        )
        #expect(!IronsmithFeatureFlags.isDiagnosticWholeFileRewriteEnabled(
            userDefaults: userDefaults
        ))
    }

    private static func makeIsolatedUserDefaults() throws -> UserDefaults {
        let suiteName = "IronsmithTests.FeatureFlags.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        return userDefaults
    }
}
