import AnyLanguageModel
import Foundation
import Supabase
import SwiftData
import Testing
@testable import Ironsmith

extension ToolLibraryTests {
    @Test
    func appVersionComparatorDetectsNewerRelease() {
        #expect(AppVersionComparator.isRelease("v1.2.0", newerThan: "1.1.9"))
        #expect(AppVersionComparator.isRelease("1.10", newerThan: "1.9"))
    }

    @Test
    func appVersionComparatorHidesCurrentOrOlderRelease() {
        #expect(!(AppVersionComparator.isRelease("v1.0.0", newerThan: "1.0")))
        #expect(!(AppVersionComparator.isRelease("1.2.0", newerThan: "1.2.1")))
    }

    @Test
    func appVersionComparatorIgnoresUnparsableVersions() {
        #expect(!(AppVersionComparator.isRelease("v1.2-beta", newerThan: "1.1")))
        #expect(!(AppVersionComparator.isRelease("1.2", newerThan: nil)))
        #expect(!(AppVersionComparator.isRelease("1.2", newerThan: "beta")))
    }

    @MainActor
    @Test
    func appUpdateStoreSavesNewerRelease() async throws {
        let userDefaults = try Self.makeIsolatedUserDefaults()
        let release = AppUpdateRelease(
            tagName: "v1.2.0",
            releaseURL: URL(string: "https://github.com/sparkle-project/Sparkle/releases/tag/2.0.0")!
        )
        let capture = AppUpdateFetchCapture(result: .success(release))
        let store = AppUpdateStore(
            client: AppUpdateClient(fetchLatestRelease: { try await capture.fetch() }),
            currentVersion: "1.1.0",
            userDefaults: userDefaults
        )

        await store.refresh(now: Date(timeIntervalSinceReferenceDate: 100))

        #expect(store.availableUpdate == release)
        #expect(store.shouldShowUpdateButton)
        #expect(userDefaults.string(forKey: "appUpdate.latestReleaseTag") == "v1.2.0")
    }

    @MainActor
    @Test
    func appUpdateStoreClearsStaleUpdateWhenCurrentReleaseIsInstalled() async throws {
        let userDefaults = try Self.makeIsolatedUserDefaults()
        userDefaults.set("v1.2.0", forKey: "appUpdate.latestReleaseTag")
        userDefaults.set("https://github.com/sparkle-project/Sparkle/releases/tag/2.0.0", forKey: "appUpdate.latestReleaseURL")
        let release = AppUpdateRelease(
            tagName: "v1.2.0",
            releaseURL: URL(string: "https://github.com/sparkle-project/Sparkle/releases/tag/2.0.0")!
        )
        let capture = AppUpdateFetchCapture(result: .success(release))
        let store = AppUpdateStore(
            client: AppUpdateClient(fetchLatestRelease: { try await capture.fetch() }),
            currentVersion: "1.2.0",
            userDefaults: userDefaults
        )

        await store.refresh(now: Date(timeIntervalSinceReferenceDate: 100))

        #expect(store.availableUpdate == nil)
        #expect(!(store.shouldShowUpdateButton))
        #expect(userDefaults.string(forKey: "appUpdate.latestReleaseTag") == nil)
    }

    @MainActor
    @Test
    func appUpdateStoreKeepsKnownUpdateWhenFetchFails() async throws {
        let userDefaults = try Self.makeIsolatedUserDefaults()
        userDefaults.set("v1.2.0", forKey: "appUpdate.latestReleaseTag")
        userDefaults.set("https://github.com/sparkle-project/Sparkle/releases/tag/2.0.0", forKey: "appUpdate.latestReleaseURL")
        let capture = AppUpdateFetchCapture(result: .failure(AppUpdateFetchError.failed))
        let store = AppUpdateStore(
            client: AppUpdateClient(fetchLatestRelease: { try await capture.fetch() }),
            currentVersion: "1.1.0",
            userDefaults: userDefaults
        )

        await store.refresh(now: Date(timeIntervalSinceReferenceDate: 100))

        #expect(store.availableUpdate?.tagName == "v1.2.0")
        #expect(store.shouldShowUpdateButton)
    }

    @MainActor
    @Test
    func appUpdateStoreStartupRefreshIgnoresDailyThrottle() async throws {
        let userDefaults = try Self.makeIsolatedUserDefaults()
        let release = AppUpdateRelease(
            tagName: "v1.2.0",
            releaseURL: URL(string: "https://github.com/sparkle-project/Sparkle/releases/tag/2.0.0")!
        )
        let capture = AppUpdateFetchCapture(result: .success(release))
        let store = AppUpdateStore(
            client: AppUpdateClient(fetchLatestRelease: { try await capture.fetch() }),
            currentVersion: "1.1.0",
            userDefaults: userDefaults
        )

        await store.refreshIfDue(now: Date(timeIntervalSinceReferenceDate: 100))
        await store.refreshOnStartup(now: Date(timeIntervalSinceReferenceDate: 101))

        #expect(await capture.fetchCount == 2)
        #expect(store.availableUpdate == release)
    }

    @MainActor
    @Test
    func appUpdateStoreClearsInstalledCachedUpdateOnInit() async throws {
        let userDefaults = try Self.makeIsolatedUserDefaults()
        userDefaults.set("v1.2.0", forKey: "appUpdate.latestReleaseTag")
        userDefaults.set("https://github.com/sparkle-project/Sparkle/releases/tag/2.0.0", forKey: "appUpdate.latestReleaseURL")
        let capture = AppUpdateFetchCapture(result: .failure(AppUpdateFetchError.failed))
        let store = AppUpdateStore(
            client: AppUpdateClient(fetchLatestRelease: { try await capture.fetch() }),
            currentVersion: "1.2.0",
            userDefaults: userDefaults
        )

        #expect(store.availableUpdate == nil)
        #expect(!(store.shouldShowUpdateButton))
        #expect(userDefaults.string(forKey: "appUpdate.latestReleaseTag") == nil)
        #expect(userDefaults.string(forKey: "appUpdate.latestReleaseURL") == nil)
        #expect(await capture.fetchCount == 0)
    }

    @MainActor
    @Test
    func appUpdateStoreThrottlesDailyChecks() async throws {
        let userDefaults = try Self.makeIsolatedUserDefaults()
        let release = AppUpdateRelease(
            tagName: "v1.2.0",
            releaseURL: URL(string: "https://github.com/sparkle-project/Sparkle/releases/tag/2.0.0")!
        )
        let capture = AppUpdateFetchCapture(result: .success(release))
        let store = AppUpdateStore(
            client: AppUpdateClient(fetchLatestRelease: { try await capture.fetch() }),
            currentVersion: "1.1.0",
            userDefaults: userDefaults
        )

        await store.refreshIfDue(now: Date(timeIntervalSinceReferenceDate: 100))
        await store.refreshIfDue(now: Date(timeIntervalSinceReferenceDate: 100 + AppUpdateStore.checkInterval - 1))

        #expect(await capture.fetchCount == 1)
        #expect(userDefaults.object(forKey: "appUpdate.lastCheckDate") == nil)

        await store.refreshIfDue(now: Date(timeIntervalSinceReferenceDate: 100 + AppUpdateStore.checkInterval))

        #expect(await capture.fetchCount == 2)
    }
}
