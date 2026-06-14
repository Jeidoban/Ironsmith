import Foundation

struct WelcomeOnboardingStore {
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var hasCompleted: Bool {
        userDefaults.bool(forKey: IronsmithPreferenceKeys.hasCompletedWelcomeOnboarding)
    }

    func complete() {
        userDefaults.set(true, forKey: IronsmithPreferenceKeys.hasCompletedWelcomeOnboarding)
    }
}
