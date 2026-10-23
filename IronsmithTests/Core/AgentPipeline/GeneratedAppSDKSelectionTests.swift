import Foundation
import Testing

@testable import Ironsmith

// TODO(CLTSwiftUIMacrosWorkaround): Remove this test file with the CLT SDK fallback.
struct GeneratedAppSDKSelectionTests {
    @Test func selectsNewestOlderSDKWhenCLT27LacksSwiftUIMacros() throws {
        let fixture = try SDKFixture(defaultVersion: "27.0", olderVersions: ["26.0", "26.5"])
        defer { fixture.remove() }

        let fallback = GeneratedAppSDKSelection.candidateFallbackSDKRoot(
            developerDirectory: fixture.developerDirectory
        )
        #expect(fallback == fixture.sdkURL("26.5"))
    }

    @Test func usesDefaultSDKAfterPluginAppears() throws {
        let fixture = try SDKFixture(defaultVersion: "27.0", olderVersions: ["26.5"])
        defer { fixture.remove() }
        let beforeFix = GeneratedAppSDKSelection.candidateFallbackSDKRoot(
            developerDirectory: fixture.developerDirectory
        )
        #expect(beforeFix == fixture.sdkURL("26.5"))
        try fixture.addSwiftUIMacrosPlugin()

        let afterFix = GeneratedAppSDKSelection.candidateFallbackSDKRoot(
            developerDirectory: fixture.developerDirectory
        )
        #expect(afterFix == nil)
    }

    @Test func leavesWorkingOlderSDKAlone() throws {
        let fixture = try SDKFixture(defaultVersion: "26.5", olderVersions: ["26.0"])
        defer { fixture.remove() }

        let fallback = GeneratedAppSDKSelection.candidateFallbackSDKRoot(
            developerDirectory: fixture.developerDirectory
        )
        #expect(fallback == nil)
    }

    @Test func doesNotSelectUnsupportedOrMissingSDK() throws {
        let fixture = try SDKFixture(defaultVersion: "27.0", olderVersions: ["25.4"])
        defer { fixture.remove() }

        let fallback = GeneratedAppSDKSelection.candidateFallbackSDKRoot(
            developerDirectory: fixture.developerDirectory
        )
        #expect(fallback == nil)
    }

    @Test func cachesLaunchSelectionUntilTheNextToolsCheck() async throws {
        let fixture = try SDKFixture(defaultVersion: "27.0", olderVersions: ["26.5"])
        defer { fixture.remove() }
        let cache = GeneratedAppSDKSelectionCache()
        let availability = CommandLineToolsAvailability.available(
            CommandLineToolsSelection(
                developerDirectory: fixture.developerDirectory.path,
                swiftVersion: .init(major: 6, minor: 4),
                sdkVersion: .init(major: 27, minor: 0)
            )
        )

        await cache.update(for: availability)
        let selected = await cache.environmentOverrides(environment: [:])
        #expect(selected["SDKROOT"] == fixture.sdkURL("26.5").path)

        try fixture.addSwiftUIMacrosPlugin()
        #expect(await cache.environmentOverrides(environment: [:]) == selected)

        await cache.update(for: availability)
        #expect(await cache.environmentOverrides(environment: [:]).isEmpty)
    }

    @Test func respectsExplicitSDKROOTAndClearsUnavailableTools() async throws {
        let fixture = try SDKFixture(defaultVersion: "27.0", olderVersions: ["26.5"])
        defer { fixture.remove() }
        let cache = GeneratedAppSDKSelectionCache()
        await cache.update(for: .available(
            CommandLineToolsSelection(
                developerDirectory: fixture.developerDirectory.path,
                swiftVersion: .init(major: 6, minor: 4),
                sdkVersion: .init(major: 27, minor: 0)
            )
        ))

        #expect(await cache.environmentOverrides(environment: ["SDKROOT": "/custom/macOS.sdk"]).isEmpty)
        await cache.update(for: .unavailable)
        #expect(await cache.environmentOverrides(environment: [:]).isEmpty)
    }

    @Test func leavesSelectionsReportingSDK26Alone() async throws {
        let fixture = try SDKFixture(defaultVersion: "27.0", olderVersions: ["26.5"])
        defer { fixture.remove() }
        let cache = GeneratedAppSDKSelectionCache()
        await cache.update(for: .available(
            CommandLineToolsSelection(
                developerDirectory: fixture.developerDirectory.path,
                swiftVersion: .init(major: 6, minor: 2),
                sdkVersion: .init(major: 26, minor: 5)
            )
        ))
        #expect(await cache.environmentOverrides(environment: [:]).isEmpty)
    }

    @Test func cancelledOlderToolsCheckCannotReplaceNewerSelection() async throws {
        let fixture = try SDKFixture(defaultVersion: "27.0", olderVersions: ["26.5"])
        defer { fixture.remove() }
        let cache = GeneratedAppSDKSelectionCache()
        let newSelection = CommandLineToolsSelection(
            developerDirectory: fixture.developerDirectory.path,
            swiftVersion: .init(major: 6, minor: 4),
            sdkVersion: .init(major: 27, minor: 0)
        )
        await cache.update(for: .available(newSelection))

        let cancelledCheck = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await cache.update(for: .unavailable)
        }
        await cancelledCheck.value

        #expect(
            await cache.environmentOverrides(environment: [:])["SDKROOT"]
                == fixture.sdkURL("26.5").path
        )
    }
}

private struct SDKFixture {
    let developerDirectory: URL

    init(defaultVersion: String, olderVersions: [String]) throws {
        developerDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ironsmith-sdk-selection-\(UUID().uuidString)",
            isDirectory: true
        )
        let sdkDirectory = developerDirectory.appendingPathComponent("SDKs", isDirectory: true)
        try FileManager.default.createDirectory(at: sdkDirectory, withIntermediateDirectories: true)
        for version in Set(olderVersions + [defaultVersion]) {
            let sdkURL = self.sdkURL(version)
            try FileManager.default.createDirectory(at: sdkURL, withIntermediateDirectories: true)
            let settings = try PropertyListSerialization.data(
                fromPropertyList: ["Version": version],
                format: .xml,
                options: 0
            )
            try settings.write(to: sdkURL.appendingPathComponent("SDKSettings.plist"))
        }
        try FileManager.default.createSymbolicLink(
            at: sdkDirectory.appendingPathComponent("MacOSX.sdk"),
            withDestinationURL: sdkURL(defaultVersion)
        )
    }

    func sdkURL(_ version: String) -> URL {
        developerDirectory.appendingPathComponent("SDKs/MacOSX\(version).sdk", isDirectory: true)
    }

    func addSwiftUIMacrosPlugin() throws {
        let pluginURL = developerDirectory.appendingPathComponent(
            "usr/lib/swift/host/plugins/libSwiftUIMacros.dylib"
        )
        try FileManager.default.createDirectory(
            at: pluginURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: pluginURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: developerDirectory)
    }
}
