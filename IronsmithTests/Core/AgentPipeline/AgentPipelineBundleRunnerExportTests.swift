import AnyLanguageModel
import Foundation
import ImageIO
import SwiftData
import Testing
@testable import Ironsmith

extension AgentPipelineTests {
    @MainActor
    @Test
    func toolRunnerLaunchesInternalAppBundle() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let capture = AppBundleCapture()
        let appBundleClient = ToolAppBundleClient(
            buildInternalApp: { request in
                await capture.recordBuild(request)
                return request.internalAppBundleURL
            },
            exportApp: { request, applicationsDirectoryURL in
                applicationsDirectoryURL.appendingPathComponent("\(request.displayName).app", isDirectory: true)
            },
            launchApp: { url in
                await capture.recordLaunch(url)
            },
            appExists: { _ in true }
        )
        let runner = ToolRunnerClient.live(appBundleClient: appBundleClient)
        let tool = StoredTool(
            name: "Runner",
            executableName: "Runner",
            bundleIdentifier: "com.ironsmith.tests.runner",
            packageRootPath: root.path
        )
        try Self.writePlistDictionary(
            [
                "CFBundleExecutable": "Runner",
                "IronsmithQuitOnLastWindowClose": true,
            ],
            to: tool.appBundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Info.plist")
        )

        try await runner.runTool(tool)

        #expect(await capture.builtRequests.isEmpty)
        #expect(await capture.launchedURL == tool.appBundleURL)
    }

    @MainActor
    @Test
    func toolRunnerRebuildsPartialAppBundleBeforeLaunching() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let tool = StoredTool(
            name: "Partial",
            executableName: "Partial",
            bundleIdentifier: "com.ironsmith.tests.partial",
            packageRootPath: root.path
        )
        try FileManager.default.createDirectory(
            at: tool.appBundleURL.appendingPathComponent("Contents/MacOS", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("binary".utf8).write(to: tool.appBundleURL.appendingPathComponent("Contents/MacOS/Partial"))

        let capture = AppBundleCapture()
        let appBundleClient = ToolAppBundleClient(
            buildInternalApp: { request in
                await capture.recordBuild(request)
                return request.internalAppBundleURL
            },
            exportApp: { request, applicationsDirectoryURL in
                applicationsDirectoryURL.appendingPathComponent("\(request.displayName).app", isDirectory: true)
            },
            launchApp: { url in
                await capture.recordLaunch(url)
            },
            appExists: { _ in false }
        )
        let runner = ToolRunnerClient.live(appBundleClient: appBundleClient)

        try await runner.runTool(tool)

        #expect(await capture.builtRequests.map(\.executableName) == ["Partial"])
        #expect(await capture.launchedURL == tool.appBundleURL)
    }

    @MainActor
    @Test
    func toolRunnerRebuildsOldInternalWindowBundleBeforeLaunching() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let tool = StoredTool(
            name: "Old Runner",
            executableName: "OldRunner",
            bundleIdentifier: "com.ironsmith.tests.old-runner",
            packageRootPath: root.path
        )
        try Self.writePlistDictionary(
            [
                "CFBundleExecutable": "OldRunner"
            ],
            to: tool.appBundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Info.plist")
        )

        let capture = AppBundleCapture()
        let appBundleClient = ToolAppBundleClient(
            buildInternalApp: { request in
                await capture.recordBuild(request)
                return request.internalAppBundleURL
            },
            exportApp: { request, applicationsDirectoryURL in
                applicationsDirectoryURL.appendingPathComponent("\(request.displayName).app", isDirectory: true)
            },
            launchApp: { url in
                await capture.recordLaunch(url)
            },
            appExists: { _ in true }
        )
        let runner = ToolRunnerClient.live(appBundleClient: appBundleClient)

        try await runner.runTool(tool)

        #expect(await capture.builtRequests.map(\.executableName) == ["OldRunner"])
        #expect(await capture.launchedURL == tool.appBundleURL)
    }

    @MainActor
    @Test
    func toolRunnerRebuildPreservesPermissionsFromExistingBundle() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let tool = StoredTool(
            name: "Partial",
            executableName: "Partial",
            bundleIdentifier: "com.ironsmith.tests.partial",
            packageRootPath: root.path
        )
        let plistURL = tool.appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        try Self.writePlistDictionary(
            [
                "CFBundleExecutable": "Partial",
                "NSCameraUsageDescription": "existing camera",
                "NSAppleEventsUsageDescription": "existing apple events",
            ],
            to: plistURL
        )

        let capture = AppBundleCapture()
        let appBundleClient = ToolAppBundleClient(
            buildInternalApp: { request in
                await capture.recordBuild(request)
                return request.internalAppBundleURL
            },
            exportApp: { request, applicationsDirectoryURL in
                await capture.recordExport(request)
                return applicationsDirectoryURL.appendingPathComponent("\(request.displayName).app", isDirectory: true)
            },
            launchApp: { url in
                await capture.recordLaunch(url)
            },
            appExists: { _ in false }
        )
        let runner = ToolRunnerClient.live(appBundleClient: appBundleClient)

        try await runner.runTool(tool)

        let request = try #require(await capture.builtRequests.first)
        #expect(request.resourcePermissions.contains(.camera))
        #expect(request.resourcePermissions.contains(.appleEvents))
        #expect(!(request.resourcePermissions.contains(.contacts)))
        #expect(await capture.launchedURL == tool.appBundleURL)
    }

    @MainActor
    @Test
    func toolExportPreservesPermissionsFromExistingInternalBundle() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let tool = StoredTool(
            name: "Exporter",
            executableName: "Exporter",
            bundleIdentifier: "com.ironsmith.tests.exporter",
            packageRootPath: root.path
        )
        let plistURL = tool.appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        try Self.writePlistDictionary(
            [
                "CFBundleExecutable": "Exporter",
                "NSContactsUsageDescription": "existing contacts",
                "NSPhotoLibraryUsageDescription": "existing photos",
            ],
            to: plistURL
        )

        let capture = AppBundleCapture()
        let appBundleClient = ToolAppBundleClient(
            buildInternalApp: { request in
                await capture.recordBuild(request)
                return request.internalAppBundleURL
            },
            exportApp: { request, applicationsDirectoryURL in
                await capture.recordExport(request)
                return applicationsDirectoryURL.appendingPathComponent("\(request.displayName).app", isDirectory: true)
            },
            launchApp: { _ in },
            appExists: { _ in true }
        )
        let exporter = ToolExportClient.live(
            appBundleClient: appBundleClient,
            applicationsDirectoryURL: root.appendingPathComponent("Applications", isDirectory: true)
        )

        _ = try await exporter.exportTool(tool)

        let request = try #require(await capture.exportedRequests.first)
        #expect(request.resourcePermissions.contains(.contacts))
        #expect(request.resourcePermissions.contains(.photoLibrary))
        #expect(!(request.resourcePermissions.contains(.calendar)))
    }
}
