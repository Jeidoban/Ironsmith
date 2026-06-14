import Observation

@MainActor
@Observable
final class MenuBarPopoverPresentationStore {
    private(set) var showCount = 0
    private(set) var closeCount = 0

    func didShow() {
        showCount += 1
    }

    func willClose() {
        closeCount += 1
    }
}
