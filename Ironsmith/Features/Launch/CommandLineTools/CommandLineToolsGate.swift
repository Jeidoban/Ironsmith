import Foundation
import Observation

enum LaunchRoute: Equatable {
    case checking
    case onboarding
    case shell
}

@MainActor
@Observable
final class CommandLineToolsGate {
    var route: LaunchRoute = .checking
    var swiftCompilerPath: String?
    var isCheckingInstallation = false
    var notFoundMessageID = 0

    private let client: CommandLineToolsClient
    private var refreshTask: Task<Void, Never>?
    private var hasStarted = false

    init(client: CommandLineToolsClient = .live()) {
        self.client = client
    }

    func start() {
        guard !hasStarted else {
            return
        }

        hasStarted = true
        runAvailabilityCheck(showsCheckingRoute: true, showsNotFoundMessage: false)
    }

    func refreshNow() {
        runAvailabilityCheck(showsCheckingRoute: false, showsNotFoundMessage: true)
    }

    private func runAvailabilityCheck(showsCheckingRoute: Bool, showsNotFoundMessage: Bool) {
        refreshTask?.cancel()
        isCheckingInstallation = true
        if showsCheckingRoute {
            route = .checking
        }
        refreshTask = Task { [weak self] in
            await self?.refreshStatus(showsNotFoundMessage: showsNotFoundMessage)
        }
    }

    func refreshStatus(showsNotFoundMessage: Bool = false) async {
        isCheckingInstallation = true
        defer { isCheckingInstallation = false }

        let availability = await client.detectAvailability()
        guard !Task.isCancelled else { return }

        switch availability {
        case .available(let path):
            swiftCompilerPath = path
            route = .shell
        case .unavailable:
            swiftCompilerPath = nil
            route = .onboarding
            if showsNotFoundMessage {
                notFoundMessageID += 1
            }
        }
    }
}
