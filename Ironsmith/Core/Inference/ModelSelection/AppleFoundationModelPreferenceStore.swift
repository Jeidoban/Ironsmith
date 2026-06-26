import Foundation

struct AppleFoundationModelPreferenceStore {
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var isEnabled: Bool {
        get {
            userDefaults.bool(forKey: IronsmithPreferenceKeys.appleFoundationModelEnabled)
        }
        nonmutating set {
            userDefaults.set(newValue, forKey: IronsmithPreferenceKeys.appleFoundationModelEnabled)
        }
    }
}
