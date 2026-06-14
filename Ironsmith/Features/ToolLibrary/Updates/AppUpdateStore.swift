import AppKit
import Foundation
import Observation

struct AppUpdateRelease: Equatable, Sendable {
    var tagName: String
    var releaseURL: URL
}

struct AppUpdateClient {
    var fetchLatestRelease: @Sendable () async throws -> AppUpdateRelease

    nonisolated static let live = AppUpdateClient {
        let url = URL(string: "https://api.github.com/repos/Jeidoban/Ironsmith/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Ironsmith", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw AppUpdateError.releaseCheckFailed
        }

        let release = try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
        guard let releaseURL = URL(string: release.htmlURL) else {
            throw AppUpdateError.invalidReleaseURL
        }

        return AppUpdateRelease(tagName: release.tagName, releaseURL: releaseURL)
    }
}

@MainActor
@Observable
final class AppUpdateStore {
    nonisolated static let checkInterval: TimeInterval = 86_400

    private(set) var availableUpdate: AppUpdateRelease?

    @ObservationIgnored private let client: AppUpdateClient
    @ObservationIgnored private let currentVersion: String?
    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private var automaticCheckTask: Task<Void, Never>?
    @ObservationIgnored private var lastCheckDate: Date?

    init(
        client: AppUpdateClient = .live,
        currentVersion: String? = AppUpdateStore.bundleShortVersion(),
        userDefaults: UserDefaults = .standard
    ) {
        self.client = client
        self.currentVersion = currentVersion
        self.userDefaults = userDefaults
        availableUpdate = Self.cachedRelease(in: userDefaults, currentVersion: currentVersion)
        if availableUpdate == nil {
            Self.clearCachedRelease(in: userDefaults)
        }
    }

    deinit {
        automaticCheckTask?.cancel()
    }

    var shouldShowUpdateButton: Bool {
        availableUpdate != nil
    }

    func startAutomaticChecks() {
        guard automaticCheckTask == nil else { return }

        automaticCheckTask = Task { @MainActor [weak self] in
            await self?.refreshOnStartup()

            while let self, !Task.isCancelled {
                await self.refreshIfDue()
                let sleepNanoseconds = self.nanosecondsUntilNextCheck(from: Date())
                do {
                    try await Task.sleep(nanoseconds: sleepNanoseconds)
                } catch {
                    return
                }
            }
        }
    }

    func refreshOnStartup(now: Date = Date()) async {
        await refresh(now: now)
    }

    func refreshIfDue(now: Date = Date()) async {
        guard shouldCheck(now: now) else { return }
        await refresh(now: now)
    }

    func refresh(now: Date = Date()) async {
        lastCheckDate = now

        do {
            let release = try await client.fetchLatestRelease()
            apply(release)
        } catch {
            // Release checks are best-effort. A private repo or transient network
            // failure should never interrupt generation or settings flows.
        }
    }

    func openAvailableUpdate() {
        guard let releaseURL = availableUpdate?.releaseURL else { return }
        NSWorkspace.shared.open(releaseURL)
    }

    private func shouldCheck(now: Date) -> Bool {
        guard let lastCheckDate else {
            return true
        }

        return now.timeIntervalSince(lastCheckDate) >= Self.checkInterval
    }

    private func nanosecondsUntilNextCheck(from now: Date) -> UInt64 {
        let elapsed = lastCheckDate.map { now.timeIntervalSince($0) } ?? Self.checkInterval
        let remaining = max(60, Self.checkInterval - elapsed)
        return UInt64(remaining * 1_000_000_000)
    }

    private func apply(_ release: AppUpdateRelease) {
        guard AppVersionComparator.isRelease(release.tagName, newerThan: currentVersion) else {
            clearAvailableUpdate()
            return
        }

        availableUpdate = release
        userDefaults.set(release.tagName, forKey: Self.latestReleaseTagKey)
        userDefaults.set(release.releaseURL.absoluteString, forKey: Self.latestReleaseURLKey)
    }

    private func clearAvailableUpdate() {
        availableUpdate = nil
        Self.clearCachedRelease(in: userDefaults)
    }

    nonisolated private static func cachedRelease(
        in userDefaults: UserDefaults,
        currentVersion: String?
    ) -> AppUpdateRelease? {
        guard let tagName = userDefaults.string(forKey: latestReleaseTagKey),
              let releaseURLString = userDefaults.string(forKey: latestReleaseURLKey),
              let releaseURL = URL(string: releaseURLString),
              AppVersionComparator.isRelease(tagName, newerThan: currentVersion)
        else {
            return nil
        }

        return AppUpdateRelease(tagName: tagName, releaseURL: releaseURL)
    }

    private static func clearCachedRelease(in userDefaults: UserDefaults) {
        userDefaults.removeObject(forKey: latestReleaseTagKey)
        userDefaults.removeObject(forKey: latestReleaseURLKey)
    }

    nonisolated private static func bundleShortVersion(bundle: Bundle = .main) -> String? {
        bundle.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    nonisolated private static let latestReleaseTagKey = "appUpdate.latestReleaseTag"
    nonisolated private static let latestReleaseURLKey = "appUpdate.latestReleaseURL"
}

enum AppVersionComparator {
    nonisolated static func isRelease(_ releaseTag: String, newerThan currentVersion: String?) -> Bool {
        guard let releaseVersion = AppVersion(releaseTag),
              let currentVersion = AppVersion(currentVersion)
        else {
            return false
        }

        return releaseVersion > currentVersion
    }
}

nonisolated private enum AppUpdateError: Error {
    case invalidReleaseURL
    case releaseCheckFailed
}

nonisolated private struct GitHubReleaseResponse: Decodable {
    var tagName: String
    var htmlURL: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

nonisolated private struct AppVersion: Comparable {
    private let components: [Int]

    init?(_ rawValue: String?) {
        guard var rawValue else { return nil }
        rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawValue.hasPrefix("v") || rawValue.hasPrefix("V") {
            rawValue.removeFirst()
        }

        let rawComponents = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard !rawComponents.isEmpty else { return nil }

        var components: [Int] = []
        for rawComponent in rawComponents {
            guard !rawComponent.isEmpty,
                  rawComponent.allSatisfy(\.isNumber),
                  let component = Int(rawComponent)
            else {
                return nil
            }
            components.append(component)
        }

        self.components = components
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let maxCount = max(lhs.components.count, rhs.components.count)
        for index in 0..<maxCount {
            let lhsComponent = index < lhs.components.count ? lhs.components[index] : 0
            let rhsComponent = index < rhs.components.count ? rhs.components[index] : 0
            if lhsComponent != rhsComponent {
                return lhsComponent < rhsComponent
            }
        }

        return false
    }
}
