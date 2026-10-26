import Foundation

/// Work around standalone CLT releases that ship SwiftUI's SDK 27 macro declarations
/// without the host-side SwiftUIMacros plugin needed to compile them.
/// TODO(CLTSwiftUIMacrosWorkaround): Remove this file and its tests once Apple ships
/// standalone Command Line Tools with libSwiftUIMacros.dylib for the current macOS SDK.
nonisolated enum GeneratedAppSDKSelection {
    private static let cache = GeneratedAppSDKSelectionCache()

    static func update(for availability: CommandLineToolsAvailability) async {
        await cache.update(for: availability)
    }

    static func environmentOverrides(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> [String: String] {
        await cache.environmentOverrides(environment: environment)
    }

    static func candidateFallbackSDKRoot(
        developerDirectory: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let sdkDirectory = developerDirectory.appendingPathComponent("SDKs", isDirectory: true)
        let defaultSDK = sdkDirectory.appendingPathComponent("MacOSX.sdk", isDirectory: true)
        let pluginURL = developerDirectory.appendingPathComponent(
            "usr/lib/swift/host/plugins/libSwiftUIMacros.dylib"
        )
        guard let defaultVersion = sdkVersion(at: defaultSDK), defaultVersion.major >= 27,
            !fileManager.fileExists(atPath: pluginURL.path),
            let sdkURLs = try? fileManager.contentsOfDirectory(
                at: sdkDirectory,
                includingPropertiesForKeys: nil
            )
        else {
            return nil
        }

        return sdkURLs.compactMap { sdkURL -> (version: SDKVersion, url: URL)? in
            guard sdkURL.lastPathComponent.hasPrefix("MacOSX"),
                sdkURL.pathExtension == "sdk",
                let version = sdkVersion(at: sdkURL),
                version.major >= GeneratedToolRequirements.sdkMajorVersion,
                version.major < 27
            else {
                return nil
            }
            return (version, sdkURL.resolvingSymlinksInPath())
        }
        .max { $0.version < $1.version }?.url
    }

    private struct SDKVersion: Comparable {
        let major: Int
        let minor: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
        }
    }

    private static func sdkVersion(at sdkURL: URL) -> SDKVersion? {
        let settingsURL = sdkURL.appendingPathComponent("SDKSettings.plist")
        guard let data = try? Data(contentsOf: settingsURL),
            let settings = try? PropertyListSerialization.propertyList(
                from: data,
                format: nil
            ) as? [String: Any],
            let version = settings["Version"] as? String
        else {
            return nil
        }
        let components = version.split(separator: ".")
        guard components.count >= 2,
            let major = Int(components[0]),
            let minor = Int(components[1])
        else {
            return nil
        }
        return SDKVersion(major: major, minor: minor)
    }
}

actor GeneratedAppSDKSelectionCache {
    private var sdkRoot: URL?

    func update(for availability: CommandLineToolsAvailability) {
        guard !Task.isCancelled else { return }
        guard case .available(let selection) = availability,
            selection.sdkVersion.major >= 27
        else {
            sdkRoot = nil
            return
        }
        sdkRoot = GeneratedAppSDKSelection.candidateFallbackSDKRoot(
            developerDirectory: URL(fileURLWithPath: selection.developerDirectory, isDirectory: true)
        )
    }

    func environmentOverrides(environment: [String: String]) -> [String: String] {
        // An explicit SDK choice belongs to the caller, not Ironsmith.
        guard environment["SDKROOT"]?.isEmpty != false, let sdkRoot else { return [:] }
        return ["SDKROOT": sdkRoot.path]
    }
}
