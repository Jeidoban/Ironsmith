import Foundation
import UserNotifications

struct ToolGenerationNotification: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case finished
        case stopped
    }

    var kind: Kind
    var toolName: String
    var detail: String?
}

struct ToolGenerationNotificationClient {
    var notify: (_ notification: ToolGenerationNotification) async -> Void

    static let disabled = ToolGenerationNotificationClient { _ in }

    static let live = ToolGenerationNotificationClient { notification in
        await ToolGenerationNotificationCenter.shared.deliver(notification)
    }
}

private final class ToolGenerationNotificationCenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ToolGenerationNotificationCenter()

    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    func deliver(_ notification: ToolGenerationNotification) async {
        do {
            guard try await ensureAuthorization() else { return }

            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "ironsmith.generation.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            try await center.add(request)
        } catch {
            // Notifications are best-effort and should never interrupt generation.
        }
    }

    private func ensureAuthorization() async throws -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            return try await center.requestAuthorization(options: [.alert, .sound])
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

private extension ToolGenerationNotification {
    var title: String {
        switch kind {
        case .finished:
            return "Ironsmith finished"
        case .stopped:
            return "Ironsmith stopped"
        }
    }

    var body: String {
        switch kind {
        case .finished:
            return "\(toolName) is ready."
        case .stopped:
            guard let detail, !detail.isEmpty else {
                return "\(toolName) stopped."
            }
            return "\(toolName) stopped. \(detail)"
        }
    }
}
