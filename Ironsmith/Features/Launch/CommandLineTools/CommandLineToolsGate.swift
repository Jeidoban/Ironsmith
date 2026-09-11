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
    var availability: CommandLineToolsAvailability?
    var isCheckingInstallation = false
    var notFoundMessageID = 0

    private let client: CommandLineToolsClient
    private var refreshTask: Task<Void, Never>?
    private var hasStarted = false
    private var hasRequestedInstallation = false

    init(client: CommandLineToolsClient = .live()) {
        self.client = client
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        runAvailabilityCheck(showsCheckingRoute: true, requestsInstallationIfMissing: true)
    }

    func refreshNow() {
        runAvailabilityCheck(showsCheckingRoute: false, showsNotFoundMessage: true)
    }

    private func runAvailabilityCheck(
        showsCheckingRoute: Bool,
        showsNotFoundMessage: Bool = false,
        requestsInstallationIfMissing: Bool = false
    ) {
        refreshTask?.cancel()
        isCheckingInstallation = true
        if showsCheckingRoute {
            route = .checking
        }
        refreshTask = Task { [weak self] in
            await self?.refreshStatus(
                showsNotFoundMessage: showsNotFoundMessage,
                requestsInstallationIfMissing: requestsInstallationIfMissing
            )
        }
    }

    func refreshStatus(
        showsNotFoundMessage: Bool = false,
        requestsInstallationIfMissing: Bool = false
    ) async {
        isCheckingInstallation = true
        defer { isCheckingInstallation = false }

        let availability = await client.detectAvailability()
        guard !Task.isCancelled else { return }
        self.availability = availability

        switch availability {
        case .available:
            route = .shell
        case .unsupported:
            route = .onboarding
        case .unavailable:
            route = .onboarding
            if showsNotFoundMessage {
                notFoundMessageID += 1
            }
            if requestsInstallationIfMissing, !hasRequestedInstallation {
                hasRequestedInstallation = true
                await client.requestInstallation()
            }
        }
    }
}
