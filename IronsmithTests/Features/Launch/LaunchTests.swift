import Foundation
import Testing
@testable import Ironsmith

struct LaunchTests {
    @MainActor
    @Test
    func commandLineToolsClientUsesTestOverrideForSwiftCompilerAvailability() async {
        let availableClient = CommandLineToolsClient.live(environment: [
            "IRONSMITH_TEST_SWIFTC_AVAILABLE": "1"
        ])

        let unavailableClient = CommandLineToolsClient.live(environment: [
            "IRONSMITH_TEST_SWIFTC_AVAILABLE": "0"
        ])

        switch await availableClient.detectAvailability() {
        case .available(path: "/usr/bin/swiftc"):
            break
        default:
            Issue.record("Expected available swiftc override.")
        }

        switch await unavailableClient.detectAvailability() {
        case .unavailable:
            break
        default:
            Issue.record("Expected unavailable swiftc override.")
        }
    }

    @MainActor
    @Test
    func gateRoutesIntoShellWhenSwiftCompilerExists() async {
        let gate = CommandLineToolsGate(client: .fixed(availability: .available(path: "/usr/bin/swiftc")))

        await gate.refreshStatus()

        #expect(gate.route == .shell)
        #expect(gate.swiftCompilerPath == "/usr/bin/swiftc")
    }

    @MainActor
    @Test
    func gateRoutesIntoOnboardingWhenSwiftCompilerMissing() async {
        let gate = CommandLineToolsGate(client: .fixed(availability: .unavailable))

        await gate.refreshStatus()

        #expect(gate.route == .onboarding)
        #expect(gate.swiftCompilerPath == nil)
    }

    @MainActor
    @Test
    func gateInitialRouteIsChecking() {
        let gate = CommandLineToolsGate(client: .fixed(availability: .available(path: "/usr/bin/swiftc")))

        #expect(gate.route == .checking)
        #expect(gate.swiftCompilerPath == nil)
    }

    @MainActor
    @Test
    func gateStartChecksOnceWhenSwiftCompilerIsMissing() async {
        let availabilitySource = SequencedAvailabilitySource(
            [
                .unavailable,
                .available(path: "/usr/bin/swiftc")
            ]
        )
        let gate = CommandLineToolsGate(
            client: CommandLineToolsClient(
                detectAvailability: { await availabilitySource.nextAvailability() }
            )
        )

        gate.start()

        await Self.eventually {
            gate.route == .onboarding
        }

        try? await Task.sleep(nanoseconds: 20_000_000)

        #expect(gate.route == .onboarding)
        #expect(gate.swiftCompilerPath == nil)
        #expect(await availabilitySource.callCount() == 1)
        #expect(gate.notFoundMessageID == 0)
    }

    @MainActor
    @Test
    func gateStartIsIdempotent() async {
        let availabilitySource = SequencedAvailabilitySource(
            [
                .unavailable,
                .unavailable
            ]
        )
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
    @Test
    func gateRefreshNowChecksAgainAfterOnboarding() async {
        let availabilitySource = SequencedAvailabilitySource(
            [
                .unavailable,
                .available(path: "/usr/bin/swiftc")
            ]
        )
        let gate = CommandLineToolsGate(
            client: CommandLineToolsClient(
                detectAvailability: { await availabilitySource.nextAvailability() }
            )
        )

        gate.start()

        await Self.eventually {
            gate.route == .onboarding
        }

        gate.refreshNow()

        await Self.eventually {
            gate.route == .shell
        }

        #expect(gate.route == .shell)
        #expect(gate.swiftCompilerPath == "/usr/bin/swiftc")
        #expect(await availabilitySource.callCount() == 2)
    }

    @MainActor
    @Test
    func gateRefreshNowShowsNotFoundWhenStillMissing() async {
        let availabilitySource = SequencedAvailabilitySource(
            [
                .unavailable,
                .unavailable
            ]
        )
        let gate = CommandLineToolsGate(
            client: CommandLineToolsClient(
                detectAvailability: { await availabilitySource.nextAvailability() }
            )
        )

        gate.start()

        await Self.eventually {
            gate.route == .onboarding
        }

        gate.refreshNow()

        await Self.eventually {
            await availabilitySource.callCount() >= 2
        }

        #expect(gate.route == .onboarding)
        #expect(gate.swiftCompilerPath == nil)
        #expect(gate.notFoundMessageID == 1)
        #expect(await availabilitySource.callCount() == 2)
    }

    @MainActor
    @Test
    func gateStartDoesNotRecheckAfterShellRoute() async {
        let availabilitySource = SequencedAvailabilitySource(
            [
                .available(path: "/usr/bin/swiftc"),
                .available(path: "/unexpected/swiftc")
            ]
        )
        let gate = CommandLineToolsGate(
            client: CommandLineToolsClient(
                detectAvailability: { await availabilitySource.nextAvailability() }
            )
        )

        gate.start()

        await Self.eventually {
            gate.route == .shell
        }

        gate.start()
        try? await Task.sleep(nanoseconds: 20_000_000)

        #expect(gate.route == .shell)
        #expect(gate.swiftCompilerPath == "/usr/bin/swiftc")
        #expect(await availabilitySource.callCount() == 1)
    }

    @MainActor
    private static func eventually(
        timeoutNanoseconds: UInt64 = 5_000_000_000,
        _ predicate: @escaping @MainActor () async -> Bool
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
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
