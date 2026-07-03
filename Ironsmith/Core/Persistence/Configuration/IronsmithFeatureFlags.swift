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
}
