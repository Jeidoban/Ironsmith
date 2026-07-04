import Observation

@MainActor
@Observable
final class MenuBarPopoverPresentationStore {
    private(set) var isShown = false
    private(set) var showCount = 0
    private(set) var closeCount = 0

    func didShow() {
        isShown = true
        showCount += 1
    }

    func willClose() {
        isShown = false
        closeCount += 1
    }
}
