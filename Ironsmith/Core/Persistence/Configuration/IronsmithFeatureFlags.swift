import Foundation

enum IronsmithFeatureFlags {
    nonisolated static func isStoreEnabled(
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        userDefaults.bool(forKey: IronsmithPreferenceKeys.featureStoreEnabled)
    }

    nonisolated static func setStoreEnabled(
        _ isEnabled: Bool,
        userDefaults: UserDefaults = .standard
    ) {
        userDefaults.set(isEnabled, forKey: IronsmithPreferenceKeys.featureStoreEnabled)
    }

    nonisolated static func isDiagnosticWholeFileRewriteEnabled(
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        userDefaults.bool(
            forKey: IronsmithPreferenceKeys.featureDiagnosticWholeFileRewriteEnabled
        )
    }

    nonisolated static func setDiagnosticWholeFileRewriteEnabled(
        _ isEnabled: Bool,
        userDefaults: UserDefaults = .standard
    ) {
        userDefaults.set(
            isEnabled,
            forKey: IronsmithPreferenceKeys.featureDiagnosticWholeFileRewriteEnabled
        )
    }
}
