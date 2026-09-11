import Foundation
import Testing

@testable import Ironsmith

struct CommandLineToolsClientTests {
    @Test func parsesSelectedSwiftAndSDKVersions() throws {
        let swift = try #require(
            CommandLineToolsVersion.parseSwiftVersion(
                from: "swift-driver version: 1.168.6 Apple Swift version 6.4 (swiftlang-6.4.0)"
            )
        )
        let sdk = try #require(CommandLineToolsVersion.parseSDKVersion(from: "27.0"))

        #expect(swift == .init(major: 6, minor: 4))
        #expect(sdk == .init(major: 27, minor: 0))
    }

    @Test func rejectsUnrecognizedVersionOutput() {
        #expect(CommandLineToolsVersion.parseSwiftVersion(from: "development snapshot") == nil)
        #expect(CommandLineToolsVersion.parseSDKVersion(from: "unknown") == nil)
    }

    @Test(arguments: [
        (
            swift: CommandLineToolsVersion(major: 6, minor: 1),
            sdk: CommandLineToolsVersion(major: 26, minor: 0), supported: false
        ),
        (
            swift: CommandLineToolsVersion(major: 6, minor: 2),
            sdk: CommandLineToolsVersion(major: 25, minor: 4), supported: false
        ),
        (
            swift: CommandLineToolsVersion(major: 6, minor: 2),
            sdk: CommandLineToolsVersion(major: 26, minor: 0), supported: true
        ),
        (
            swift: CommandLineToolsVersion(major: 7, minor: 0),
            sdk: CommandLineToolsVersion(major: 28, minor: 0), supported: true
        ),
    ])
    func enforcesGeneratedToolMinimumVersions(
        swift: CommandLineToolsVersion,
        sdk: CommandLineToolsVersion,
        supported: Bool
    ) {
        #expect(
            CommandLineToolsClient.isSupported(swiftVersion: swift, sdkVersion: sdk)
                == supported
        )
    }

    @Test func recognizesXcodeAndStandaloneSelections() {
        let xcode = CommandLineToolsSelection(
            developerDirectory: "/Applications/Xcode.app/Contents/Developer",
            swiftVersion: .init(major: 6, minor: 2),
            sdkVersion: .init(major: 26, minor: 0)
        )
        let standalone = CommandLineToolsSelection(
            developerDirectory: "/Library/Developer/CommandLineTools",
            swiftVersion: .init(major: 6, minor: 2),
            sdkVersion: .init(major: 26, minor: 0)
        )

        #expect(xcode.usesXcode)
        #expect(!standalone.usesXcode)
    }

    #if DEBUG
    @Test func debugStatesRepresentEveryLaunchGateOutcome() throws {
        #expect(CommandLineToolsDebugState.automatic.availability == nil)
        #expect(CommandLineToolsDebugState.missing.availability == .unavailable)

        let supported = try #require(CommandLineToolsDebugState.supported.availability)
        guard case .available = supported else {
            Issue.record("Supported debug state should pass the launch gate")
            return
        }

        let standalone = try #require(
            CommandLineToolsDebugState.outdatedStandalone.availability
        )
        guard case .unsupported(let standaloneSelection) = standalone else {
            Issue.record("Standalone update debug state should be unsupported")
            return
        }
        #expect(!standaloneSelection.usesXcode)

        let xcode = try #require(CommandLineToolsDebugState.outdatedXcode.availability)
        guard case .unsupported(let xcodeSelection) = xcode else {
            Issue.record("Xcode update debug state should be unsupported")
            return
        }
        #expect(xcodeSelection.usesXcode)
    }

    @Test func debugStateDefaultsToAutomaticForUnknownStoredValues() {
        let suiteName = "CommandLineToolsClientTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        #expect(CommandLineToolsDebugState.selected(userDefaults: userDefaults) == .automatic)

        userDefaults.set(
            CommandLineToolsDebugState.outdatedXcode.rawValue,
            forKey: IronsmithPreferenceKeys.debugCommandLineToolsState
        )
        #expect(
            CommandLineToolsDebugState.selected(userDefaults: userDefaults) == .outdatedXcode
        )

        userDefaults.set(
            "future-state",
            forKey: IronsmithPreferenceKeys.debugCommandLineToolsState
        )
        #expect(CommandLineToolsDebugState.selected(userDefaults: userDefaults) == .automatic)
    }
    #endif
}
