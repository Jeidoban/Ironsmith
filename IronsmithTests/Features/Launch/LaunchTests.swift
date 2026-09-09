import Foundation
import Testing

@testable import Ironsmith

struct LaunchTests {
    @Test func commandLineToolsClientUsesTestOverride() async {
        let availableClient = CommandLineToolsClient.live(environment: [
            "IRONSMITH_TEST_SWIFTC_AVAILABLE": "1"
        ])
        let unavailableClient = CommandLineToolsClient.live(environment: [
            "IRONSMITH_TEST_SWIFTC_AVAILABLE": "0"
        ])

        guard case .available = await availableClient.detectAvailability() else {
            Issue.record("Expected the available developer-tools override.")
            return
        }
        #expect(await unavailableClient.detectAvailability() == .unavailable)
    }

    @MainActor
    @Test func gateInitialRouteIsChecking() {
        let gate = CommandLineToolsGate(client: .fixed(availability: .available(Self.selection())))

        #expect(gate.route == .checking)
        #expect(gate.availability == nil)
    }

    @MainActor
    @Test func availableToolsOpenTheLibrary() async {
        let selection = Self.selection()
        let gate = CommandLineToolsGate(client: .fixed(availability: .available(selection)))

        await gate.refreshStatus()

        #expect(gate.route == .shell)
        #expect(gate.availability == .available(selection))
        #expect(!gate.isCheckingInstallation)
    }

    @MainActor
    @Test func unsupportedToolsShowOnboardingWithoutRequestingInstallation() async {
        let recorder = InstallationRequestRecorder()
        let selection = Self.selection(swift: (6, 1))
        let gate = CommandLineToolsGate(
            client: .fixed(
                availability: .unsupported(selection),
                requestInstallation: { await recorder.record() }
            )
        )

        await gate.refreshStatus(requestsInstallationIfMissing: true)

        #expect(gate.route == .onboarding)
        #expect(gate.availability == .unsupported(selection))
        #expect(await recorder.count == 0)
    }

    @MainActor
    @Test func gateStartChecksOnceAndRequestsInstallationWhenToolsAreMissing() async {
        let availabilitySource = SequencedAvailabilitySource([
            .unavailable,
            .available(Self.selection()),
        ])
        let installationRecorder = InstallationRequestRecorder()
        let gate = CommandLineToolsGate(
            client: CommandLineToolsClient(
                detectAvailability: { await availabilitySource.nextAvailability() },
                requestInstallation: { await installationRecorder.record() }
            )
        )

        gate.start()

        await Self.eventually {
            let installationCount = await installationRecorder.count
            return gate.route == .onboarding && installationCount == 1
        }
        try? await Task.sleep(for: .milliseconds(20))

        #expect(gate.route == .onboarding)
        #expect(gate.availability == .unavailable)
        #expect(await availabilitySource.callCount() == 1)
        #expect(await installationRecorder.count == 1)
        #expect(gate.notFoundMessageID == 0)
    }

    @MainActor
    @Test func gateStartIsIdempotent() async {
        let availabilitySource = SequencedAvailabilitySource([.unavailable, .unavailable])
        let gate = CommandLineToolsGate(
            client: CommandLineToolsClient(
                detectAvailability: { await availabilitySource.nextAvailability() }
            )
        )

        gate.start()
        gate.start()

        await Self.eventually {
            await availabilitySource.callCount() > 0
        }

        #expect(await availabilitySource.callCount() == 1)
    }

    @MainActor
    @Test func gateRefreshNowChecksAgainAfterOnboarding() async {
        let availabilitySource = SequencedAvailabilitySource([
            .unavailable,
            .available(Self.selection()),
        ])
        let gate = CommandLineToolsGate(
            client: CommandLineToolsClient(
                detectAvailability: { await availabilitySource.nextAvailability() }
            )
        )

        gate.start()
        await Self.eventually { gate.route == .onboarding }
        gate.refreshNow()
        await Self.eventually { gate.route == .shell }

        #expect(gate.route == .shell)
        #expect(await availabilitySource.callCount() == 2)
    }

    @MainActor
    @Test func gateRefreshNowShowsNotFoundWhenStillMissing() async {
        let availabilitySource = SequencedAvailabilitySource([.unavailable, .unavailable])
        let gate = CommandLineToolsGate(
            client: CommandLineToolsClient(
                detectAvailability: { await availabilitySource.nextAvailability() }
            )
        )

        gate.start()
        await Self.eventually { gate.route == .onboarding }
        gate.refreshNow()
        await Self.eventually { await availabilitySource.callCount() >= 2 }

        #expect(gate.route == .onboarding)
        #expect(gate.notFoundMessageID == 1)
        #expect(await availabilitySource.callCount() == 2)
    }

    @MainActor
    @Test func gateStartDoesNotRecheckAfterShellRoute() async {
        let availabilitySource = SequencedAvailabilitySource([
            .available(Self.selection()),
            .unavailable,
        ])
        let gate = CommandLineToolsGate(
            client: CommandLineToolsClient(
                detectAvailability: { await availabilitySource.nextAvailability() }
            )
        )

        gate.start()
        await Self.eventually { gate.route == .shell }
        gate.start()
        try? await Task.sleep(for: .milliseconds(20))

        #expect(gate.route == .shell)
        #expect(await availabilitySource.callCount() == 1)
    }

    private static func selection(
        swift: (Int, Int) = (6, 2),
        sdk: (Int, Int) = (26, 0)
    ) -> CommandLineToolsSelection {
        CommandLineToolsSelection(
            developerDirectory: "/Library/Developer/CommandLineTools",
            swiftVersion: .init(major: swift.0, minor: swift.1),
            sdkVersion: .init(major: sdk.0, minor: sdk.1)
        )
    }

    @MainActor
    private static func eventually(
        timeoutNanoseconds: UInt64 = 5_000_000_000,
        _ predicate: @escaping @MainActor () async -> Bool
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor InstallationRequestRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

private actor SequencedAvailabilitySource {
    private var availabilities: [CommandLineToolsAvailability]
    private var count = 0

    init(_ availabilities: [CommandLineToolsAvailability]) {
        self.availabilities = availabilities
    }

    func callCount() -> Int {
        count
    }

    func nextAvailability() -> CommandLineToolsAvailability {
        count += 1
        if availabilities.isEmpty {
            return .unavailable
        }
        if availabilities.count == 1 {
            return availabilities[0]
        }
        return availabilities.removeFirst()
    }
}
