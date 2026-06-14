import Foundation
import Observation

@MainActor
@Observable
final class ModelSelectionStore {
    private enum Key {
        static let selectedModelID = "modelSelection.selectedModelID"
    }

    var selectedModelID: String? {
        didSet {
            if let selectedModelID {
                userDefaults.set(selectedModelID, forKey: Key.selectedModelID)
            } else {
                userDefaults.removeObject(forKey: Key.selectedModelID)
            }
        }
    }

    @ObservationIgnored private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.selectedModelID = userDefaults.string(forKey: Key.selectedModelID)
    }
}
