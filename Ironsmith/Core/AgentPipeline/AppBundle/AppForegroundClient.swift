import AppKit
import Foundation

struct AppForegroundClient: Sendable {
    var activate: @Sendable () async -> Void

    static let noop = AppForegroundClient {}

    static let live = AppForegroundClient {
        await MainActor.run {
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
}
