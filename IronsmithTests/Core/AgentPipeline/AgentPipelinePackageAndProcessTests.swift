import AnyLanguageModel
import Foundation
import ImageIO
import SwiftData
import Testing
@testable import Ironsmith

extension AgentPipelineTests {
    @MainActor
    @Test
    func toolPathHelpersSeparatePackageAndAgentManifests() {
        let tool = StoredTool(name: "Demo", packageRootPath: "/tmp/DemoTool")

        #expect(tool.packageRootURL.path == "/tmp/DemoTool")
        #expect(tool.packageManifestURL.path == "/tmp/DemoTool/Package.swift")
        #expect(tool.agentManifestURL.path == "/tmp/DemoTool/ironsmith-manifest.json")
        #expect(tool.manifestURL == tool.agentManifestURL)

        let layout = ToolPackageLayout(
            packageRootURL: URL(fileURLWithPath: "/tmp/DemoTool", isDirectory: true),
            executableName: "DemoTool"
        )
        #expect(layout.appEntrySourcePath == "Sources/DemoTool/DemoTool.swift")
        #expect(layout.sourcePath(for: "ContentView.swift") == "Sources/DemoTool/ContentView.swift")
        #expect(layout.packageManifestContent().contains("swiftLanguageModes: [.v6]"))
        #expect(layout.fixedAppEntrySource().contains("ContentView()"))
    }

    @MainActor
    @Test
    func toolBuildSettingsRoundTripThroughStoredTool() {
        let tool = StoredTool(
            name: "Timer",
            sandboxEnabled: false,
            appKind: .menuBar,
            menuBarSystemImage: "timer",
            sandboxPermissions: GeneratedAppSandboxPermissions([.internet]),
            resourcePermissions: GeneratedAppResourcePermissions([.camera, .microphone]),
            packageRootPath: "/tmp/timer"
        )

        #expect(tool.appKind == .menuBar)
        #expect(tool.validatedMenuBarSystemImage == "timer")
        #expect(tool.storedSandboxPermissions?.enabled == [.internet])
        #expect(tool.storedResourcePermissions?.enabled == [.camera, .microphone])

        tool.storedSandboxPermissions = GeneratedAppSandboxPermissions.none
        tool.storedResourcePermissions = GeneratedAppResourcePermissions.none

        #expect(tool.sandboxPermissionRawValues == "")
        #expect(tool.resourcePermissionRawValues == "")
        #expect(tool.storedSandboxPermissions?.enabled.isEmpty == true)
        #expect(tool.storedResourcePermissions?.enabled.isEmpty == true)
    }

    @MainActor
    @Test
    func legacyToolSettingsUseProvidedPermissionDefaults() {
        let tool = StoredTool(
            name: "Legacy",
            sandboxEnabled: true,
            packageRootPath: "/tmp/legacy"
        )
        let settings = tool.generationSettings(
            defaults: ToolGenerationSettings(
                sandboxPermissions: GeneratedAppSandboxPermissions([.userSelectedFiles]),
                resourcePermissions: GeneratedAppResourcePermissions([.location])
            )
        )

        #expect(settings.appKind == .window)
        #expect(settings.menuBarSystemImage == ToolMenuBarSymbol.fallback)
        #expect(settings.sandboxPermissions.enabled == [.userSelectedFiles])
        #expect(settings.resourcePermissions.enabled == [.location])
    }

    @MainActor
    @Test
    func fixedAppEntrySourceCanUseMenuBarExtra() {
        let layout = ToolPackageLayout(
            packageRootURL: URL(fileURLWithPath: "/tmp/MenuTimer", isDirectory: true),
            executableName: "MenuTimer"
        )
        let source = layout.fixedAppEntrySource(
            displayName: "Menu Timer",
            settings: ToolGenerationSettings(appKind: .menuBar, menuBarSystemImage: "timer")
        )

        #expect(source.contains("import AppKit"))
        #expect(source.contains("MenuBarExtra(\"Menu Timer\", systemImage: \"timer\")"))
        #expect(source.contains("Text(\"Menu Timer\")"))
        #expect(source.contains(".truncationMode(.tail)"))
        #expect(source.contains("NSApplication.shared.terminate(nil)"))
        #expect(source.contains(".accessibilityLabel(\"Quit\")"))
        #expect(source.contains("ContentView()"))
        #expect(source.contains(".padding(.bottom, 12)"))
        #expect(source.contains(".padding(.horizontal, 12)"))
        #expect(source.contains(".menuBarExtraStyle(.window)"))
        #expect(!(source.contains("WindowGroup")))
    }

    @MainActor
    @Test
    func fixedWindowAppEntrySourceQuitsInternalBuildsAfterLastWindowCloses() {
        let layout = ToolPackageLayout(
            packageRootURL: URL(fileURLWithPath: "/tmp/WindowTimer", isDirectory: true),
            executableName: "WindowTimer"
        )
        let source = layout.fixedAppEntrySource(settings: ToolGenerationSettings(appKind: .window))

        #expect(source.contains("import AppKit"))
        #expect(source.contains("IronsmithGeneratedAppDelegate"))
        #expect(source.contains("applicationShouldTerminateAfterLastWindowClosed"))
        #expect(source.contains("IronsmithQuitOnLastWindowClose"))
        #expect(source.contains("WindowGroup"))
        #expect(source.contains("ContentView()"))
        #expect(!(source.contains("MenuBarExtra")))
    }

    @MainActor
    @Test
    func agentArtifactsRoundTripThroughJSON() throws {
        let manifest = ToolManifest(
            displayName: "Clipboard Cleaner",
            executableName: "ClipboardCleaner",
            files: [
                ToolManifestFile(
                    path: "Sources/ClipboardCleaner/main.swift",
                    description: "Entry point."
                )
            ]
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        #expect(try decoder.decode(ToolManifest.self, from: encoder.encode(manifest)) == manifest)
    }

    @MainActor
    @Test
    func runtimeContextPackageFileURLsDenyEscapes() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let context = ToolGenerationRuntimeContext(
            languageModel: EmptyLanguageModel(),
            generationOptions: GenerationOptions(),
            repairStrategy: .modelDiff(maxHunksPerTurn: 1),
            toolsDirectoryURL: root,
            fileClient: .live,
            processClient: .live,
            appBundleClient: .noOp(),
            versionBackupClient: .live
        )
        let resolved = try context.packageFileURL(
            for: "Sources/Demo/main.swift",
            packageRootURL: root
        )
        #expect(resolved.path == root.appendingPathComponent("Sources/Demo/main.swift").standardizedFileURL.path)

        #expect(throws: AgentFileError.self) {
            try context.packageFileURL(for: "../outside.swift", packageRootURL: root)
        }
    }

    @Test
    func processHelpersFindCompilerFilesAndTrimOutput() {
        let root = URL(fileURLWithPath: "/tmp/GeneratedTool", isDirectory: true)
        let output = """
        /tmp/GeneratedTool/Sources/GeneratedTool/main.swift:4:12: error: cannot find 'x' in scope
        lots of detail
        """

        #expect(
            SwiftPackageProcessClient.firstActionableSwiftFile(in: output, packageRootURL: root)
            == "Sources/GeneratedTool/main.swift"
        )
        #expect(SwiftPackageProcessClient.compilerExcerpt(from: String(repeating: "a", count: 20), limit: 8) == "aaaaaaaa")
    }

    @Test
    func processHelpersFilterDiagnosticsToOneFile() {
        let root = URL(fileURLWithPath: "/tmp/GeneratedTool", isDirectory: true)
        let output = """
        [4/9] Compiling GeneratedTool main.swift
        /tmp/GeneratedTool/Sources/GeneratedTool/ContentView.swift:16:27: error: extra argument 'onDecrement' in call
        14 | Stepper(...)
        15 | ...
        16 | ...

        /tmp/GeneratedTool/Sources/GeneratedTool/OtherView.swift:8:10: error: cannot find 'x' in scope
        6 | ...
        7 | ...
        8 | ...

        [5/9] Emitting module GeneratedTool
        """

        let diagnostics = SwiftPackageProcessClient.diagnostics(
            for: "Sources/GeneratedTool/ContentView.swift",
            in: output,
            packageRootURL: root
        )

        #expect(diagnostics.contains("16:27: error: extra argument 'onDecrement' in call"))
        #expect(!(diagnostics.contains("OtherView.swift")))
        #expect(!(diagnostics.contains("[4/9]")))
    }

    @Test
    func adHocGeneratedAppSigningUsesHardenedRuntime() {
        let appURL = URL(fileURLWithPath: "/tmp/GeneratedTool/Generated Tool.app", isDirectory: true)
        let entitlementsURL = URL(fileURLWithPath: "/tmp/GeneratedTool/sandbox.entitlements")

        #expect(
            SwiftPackageProcessClient.adHocCodeSignArguments(
                appBundleURL: appURL,
                entitlementsURL: nil
            ) == [
                "--force",
                "--sign",
                "-",
                "--options",
                "runtime",
                appURL.path,
            ]
        )
        #expect(
            SwiftPackageProcessClient.adHocCodeSignArguments(
                appBundleURL: appURL,
                entitlementsURL: entitlementsURL
            ) == [
                "--force",
                "--sign",
                "-",
                "--options",
                "runtime",
                "--entitlements",
                entitlementsURL.path,
                appURL.path,
            ]
        )
    }

    @MainActor
    @Test
    func appBundlerCreatesInternalBundleWithSandboxEntitlements() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let packageRoot = root.appendingPathComponent("SandboxedTool", isDirectory: true)
        let releaseBinDirectory = packageRoot.appendingPathComponent(".build/release", isDirectory: true)
        let cachedIconURL = packageRoot
            .appendingPathComponent(".ironsmith", isDirectory: true)
            .appendingPathComponent("AppIcon.icns")
        try FileManager.default.createDirectory(at: cachedIconURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("icon".utf8).write(to: cachedIconURL)

        let capture = BundleProcessCapture()
        let processClient = SwiftPackageProcessClient(
            build: { _ in
                SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
            },
            buildRelease: { packageRoot in
                await capture.recordReleaseBuild(packageRoot)
                try FileManager.default.createDirectory(at: releaseBinDirectory, withIntermediateDirectories: true)
                try Data("binary".utf8).write(to: releaseBinDirectory.appendingPathComponent("SandboxedTool"))
                return SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
            },
            showBinPath: { _ in releaseBinDirectory },
            showReleaseBinPath: { _ in releaseBinDirectory },
            launch: { _ in },
            launchApp: { _ in },
            stripQuarantine: { url in
                await capture.recordStripped(url)
            },
            signAdHoc: { appURL, entitlementsURL in
                await capture.recordSign(appURL: appURL, entitlementsURL: entitlementsURL)
                return SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
            },
            verifyCodeSignature: { appURL in
                await capture.recordVerify(appURL)
                return SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
            }
        )
        let client = ToolAppBundleClient.live(
            processClient: processClient,
            iconClient: ToolIconClient { _ in cachedIconURL }
        )
        let request = ToolAppBundleRequest(
            displayName: "Sandboxed Tool",
            executableName: "SandboxedTool",
            bundleIdentifier: "com.ironsmith.tests.sandboxed-tool",
            packageRootURL: packageRoot,
            sandboxEnabled: true,
            resourcePermissions: GeneratedAppResourcePermissions(GeneratedAppResourcePermission.allCases)
        )

        let appURL = try await client.buildInternalApp(request)

        let plist = try Self.plistDictionary(at: appURL.appendingPathComponent("Contents/Info.plist"))
        let entitlements = try Self.plistDictionary(at: request.layout.sandboxEntitlementsURL)
        #expect(appURL == request.internalAppBundleURL)
        #expect(appURL.lastPathComponent == "Sandboxed Tool.app")
        #expect(plist["CFBundleIdentifier"] as? String == request.bundleIdentifier)
        #expect(plist["CFBundleExecutable"] as? String == request.executableName)
        #expect(plist["LSUIElement"] as? Bool == true)
        #expect(plist["IronsmithQuitOnLastWindowClose"] as? Bool == true)
        #expect(entitlements["com.apple.security.app-sandbox"] as? Bool == true)
        #expect(entitlements["com.apple.security.files.user-selected.read-write"] as? Bool == true)
        #expect(entitlements["com.apple.security.network.client"] as? Bool == true)
        for permission in GeneratedAppResourcePermission.allCases {
            for usageDescriptionKey in permission.usageDescriptionKeys {
                #expect(plist[usageDescriptionKey] as? String == permission.usageDescription)
            }
            for entitlementKey in permission.sandboxEntitlementKeys {
                #expect(entitlements[entitlementKey] as? Bool == true)
            }
        }
        #expect(await capture.signedEntitlementsURL == request.layout.sandboxEntitlementsURL)
        #expect(await capture.verifiedAppURL == appURL)
        #expect(await capture.strippedURL == appURL)
    }

    @MainActor
    @Test
    func appBundlerDoesNotRewritePackageAppEntryWhenBuildingBundle() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let packageRoot = root.appendingPathComponent("ExistingWindowTool", isDirectory: true)
        let layout = ToolPackageLayout(packageRootURL: packageRoot, executableName: "ExistingWindowTool")
        let appEntryURL = packageRoot.appendingPathComponent(layout.appEntrySourcePath)
        let releaseBinDirectory = packageRoot.appendingPathComponent(".build/release", isDirectory: true)
        let originalAppEntrySource = """
        import SwiftUI

        @main
        struct ExistingWindowTool: App {
            var body: some Scene {
                WindowGroup {
                    ContentView()
                }
            }
        }
        """
        try FileManager.default.createDirectory(
            at: appEntryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try originalAppEntrySource.write(to: appEntryURL, atomically: true, encoding: .utf8)

        let processClient = SwiftPackageProcessClient(
            build: { _ in
                SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
            },
            buildRelease: { _ in
                try FileManager.default.createDirectory(at: releaseBinDirectory, withIntermediateDirectories: true)
                try Data("binary".utf8).write(to: releaseBinDirectory.appendingPathComponent("ExistingWindowTool"))
                return SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
            },
            showBinPath: { _ in releaseBinDirectory },
            showReleaseBinPath: { _ in releaseBinDirectory },
            launch: { _ in },
            launchApp: { _ in },
            stripQuarantine: { _ in },
            signAdHoc: { _, _ in
                SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
            },
            verifyCodeSignature: { _ in
                SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
            }
        )
        let client = ToolAppBundleClient.live(
            processClient: processClient,
            iconClient: ToolIconClient { _ in
                throw ToolAppBundleError.iconEncodingFailed
            }
        )
        let request = ToolAppBundleRequest(
            displayName: "Existing Window Tool",
            executableName: "ExistingWindowTool",
            bundleIdentifier: "com.ironsmith.tests.existing-window-tool",
            packageRootURL: packageRoot,
            sandboxEnabled: false,
            settings: ToolGenerationSettings(appKind: .menuBar)
        )

        _ = try await client.buildInternalApp(request)

        let currentAppEntrySource = try String(contentsOf: appEntryURL, encoding: .utf8)
        #expect(currentAppEntrySource == originalAppEntrySource)
    }

    @MainActor
    @Test
    func appBundlerHonorsSandboxPermissionToggles() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        func buildEntitlements(
            executableName: String,
            sandboxPermissions: GeneratedAppSandboxPermissions
        ) async throws -> [String: Any] {
            let packageRoot = root.appendingPathComponent(executableName, isDirectory: true)
            let releaseBinDirectory = packageRoot.appendingPathComponent(".build/release", isDirectory: true)
            let processClient = SwiftPackageProcessClient(
                build: { _ in
                    SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
                },
                buildRelease: { _ in
                    try FileManager.default.createDirectory(at: releaseBinDirectory, withIntermediateDirectories: true)
                    try Data("binary".utf8).write(to: releaseBinDirectory.appendingPathComponent(executableName))
                    return SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
                },
                showBinPath: { _ in releaseBinDirectory },
                showReleaseBinPath: { _ in releaseBinDirectory },
                launch: { _ in },
                launchApp: { _ in },
                stripQuarantine: { _ in },
                signAdHoc: { _, _ in
                    SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
                },
                verifyCodeSignature: { _ in
                    SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
                }
            )
            let request = ToolAppBundleRequest(
                displayName: executableName,
                executableName: executableName,
                bundleIdentifier: "com.ironsmith.tests.\(executableName.lowercased())",
                packageRootURL: packageRoot,
                sandboxEnabled: true,
                sandboxPermissions: sandboxPermissions
            )
            let client = ToolAppBundleClient.live(
                processClient: processClient,
                iconClient: ToolIconClient { _ in
                    throw ToolAppBundleError.iconEncodingFailed
                }
            )

            _ = try await client.buildInternalApp(request)
            return try Self.plistDictionary(at: request.layout.sandboxEntitlementsURL)
        }

        let withoutInternet = try await buildEntitlements(
            executableName: "NoInternetTool",
            sandboxPermissions: GeneratedAppSandboxPermissions([.userSelectedFiles])
        )
        #expect(withoutInternet["com.apple.security.app-sandbox"] as? Bool == true)
        #expect(withoutInternet["com.apple.security.network.client"] == nil)
        #expect(withoutInternet["com.apple.security.files.user-selected.read-write"] as? Bool == true)

        let withoutUserSelectedFiles = try await buildEntitlements(
            executableName: "NoFilesTool",
            sandboxPermissions: GeneratedAppSandboxPermissions([.internet])
        )
        #expect(withoutUserSelectedFiles["com.apple.security.app-sandbox"] as? Bool == true)
        #expect(withoutUserSelectedFiles["com.apple.security.network.client"] as? Bool == true)
        #expect(withoutUserSelectedFiles["com.apple.security.files.user-selected.read-write"] == nil)
    }

    @MainActor
    @Test
    func appBundlerInfersSandboxPermissionsForPreservedRebuilds() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let packageRoot = root.appendingPathComponent("ExistingTool", isDirectory: true)
        let tool = StoredTool(
            name: "Existing",
            executableName: "ExistingTool",
            bundleIdentifier: "com.ironsmith.tests.existing",
            sandboxEnabled: true,
            packageRootPath: packageRoot.path
        )
        try Self.writePlistDictionary(
            [
                "com.apple.security.app-sandbox": true,
                "com.apple.security.network.client": true,
            ],
            to: ToolPackageLayout.sandboxEntitlementsURL(for: packageRoot)
        )

        let request = ToolAppBundleRequest.forToolPreservingExistingBundlePermissions(tool)

        #expect(request.sandboxPermissions.contains(.internet))
        #expect(!(request.sandboxPermissions.contains(.userSelectedFiles)))

        let storedPackageRoot = root.appendingPathComponent("StoredSettingsTool", isDirectory: true)
        let storedTool = StoredTool(
            name: "Stored Settings",
            executableName: "StoredSettingsTool",
            bundleIdentifier: "com.ironsmith.tests.stored-settings",
            sandboxEnabled: true,
            sandboxPermissions: GeneratedAppSandboxPermissions([.userSelectedFiles]),
            resourcePermissions: GeneratedAppResourcePermissions([.camera]),
            packageRootPath: storedPackageRoot.path
        )
        try Self.writePlistDictionary(
            [
                "com.apple.security.app-sandbox": true,
                "com.apple.security.network.client": true,
            ],
            to: ToolPackageLayout.sandboxEntitlementsURL(for: storedPackageRoot)
        )
        try Self.writePlistDictionary(
            [
                "NSContactsUsageDescription": "artifact contacts access"
            ],
            to: storedTool.appBundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Info.plist")
        )

        let storedRequest = ToolAppBundleRequest.forToolPreservingExistingBundlePermissions(storedTool)

        #expect(storedRequest.sandboxPermissions.enabled == [.userSelectedFiles])
        #expect(storedRequest.resourcePermissions.enabled == [.camera])

        let legacyPackageRoot = root.appendingPathComponent("LegacyTool", isDirectory: true)
        let legacyTool = StoredTool(
            name: "Legacy",
            executableName: "LegacyTool",
            bundleIdentifier: "com.ironsmith.tests.legacy",
            sandboxEnabled: true,
            packageRootPath: legacyPackageRoot.path
        )

        #expect(ToolAppBundleRequest.forToolPreservingExistingBundlePermissions(legacyTool).sandboxPermissions == .default)

        let unsandboxedTool = StoredTool(
            name: "Unsandboxed",
            executableName: "UnsandboxedTool",
            bundleIdentifier: "com.ironsmith.tests.unsandboxed",
            sandboxEnabled: false,
            packageRootPath: root.appendingPathComponent("UnsandboxedTool", isDirectory: true).path
        )

        #expect(ToolAppBundleRequest.forToolPreservingExistingBundlePermissions(unsandboxedTool).sandboxPermissions == .none)
    }

    @MainActor
    @Test
    func appBundlerExportsDockVisibleBundleWithoutSandboxEntitlementsWhenDisabled() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let packageRoot = root.appendingPathComponent("ExportedTool", isDirectory: true)
        let releaseBinDirectory = packageRoot.appendingPathComponent(".build/release", isDirectory: true)
        let applicationsDirectory = root.appendingPathComponent("Applications", isDirectory: true)
        let cachedIconURL = packageRoot
            .appendingPathComponent(".ironsmith", isDirectory: true)
            .appendingPathComponent("AppIcon.icns")
        try FileManager.default.createDirectory(at: cachedIconURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("icon".utf8).write(to: cachedIconURL)

        let capture = BundleProcessCapture()
        let processClient = SwiftPackageProcessClient(
            build: { _ in
                SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
            },
            buildRelease: { _ in
                try FileManager.default.createDirectory(at: releaseBinDirectory, withIntermediateDirectories: true)
                try Data("binary".utf8).write(to: releaseBinDirectory.appendingPathComponent("ExportedTool"))
                return SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
            },
            showBinPath: { _ in releaseBinDirectory },
            showReleaseBinPath: { _ in releaseBinDirectory },
            launch: { _ in },
            launchApp: { _ in },
            stripQuarantine: { _ in },
            signAdHoc: { appURL, entitlementsURL in
                await capture.recordSign(appURL: appURL, entitlementsURL: entitlementsURL)
                return SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
            },
            verifyCodeSignature: { _ in
                SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
            }
        )
        let client = ToolAppBundleClient.live(
            processClient: processClient,
            iconClient: ToolIconClient { _ in cachedIconURL }
        )
        let request = ToolAppBundleRequest(
            displayName: "Exported Tool",
            executableName: "ExportedTool",
            bundleIdentifier: "com.ironsmith.tests.exported-tool",
            packageRootURL: packageRoot,
            sandboxEnabled: false,
            resourcePermissions: GeneratedAppResourcePermissions([.contacts, .photoLibrary, .appleEvents])
        )

        let appURL = try await client.exportApp(request, applicationsDirectory)

        let plist = try Self.plistDictionary(at: appURL.appendingPathComponent("Contents/Info.plist"))
        #expect(appURL == applicationsDirectory.appendingPathComponent("Exported Tool.app", isDirectory: true))
        #expect(plist["CFBundleIdentifier"] as? String == request.bundleIdentifier)
        #expect(plist["LSUIElement"] == nil)
        #expect(plist["IronsmithQuitOnLastWindowClose"] == nil)
        #expect(plist["NSContactsUsageDescription"] as? String == GeneratedAppResourcePermission.contacts.usageDescription)
        #expect(plist["NSPhotoLibraryUsageDescription"] as? String == GeneratedAppResourcePermission.photoLibrary.usageDescription)
        #expect(plist["NSPhotoLibraryAddUsageDescription"] as? String == GeneratedAppResourcePermission.photoLibrary.usageDescription)
        #expect(plist["NSAppleEventsUsageDescription"] as? String == GeneratedAppResourcePermission.appleEvents.usageDescription)
        let recordedSignedAppURL = await capture.signedAppURL
        let signedAppURL = try #require(recordedSignedAppURL)
        #expect(signedAppURL != appURL)
        #expect(signedAppURL.deletingLastPathComponent() == appURL.deletingLastPathComponent())
        #expect(await capture.signedEntitlementsURL == nil)
    }

    @MainActor
    @Test
    func appBundlerExportsMenuBarBundleHiddenFromDock() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let packageRoot = root.appendingPathComponent("MenuBarTool", isDirectory: true)
        let releaseBinDirectory = packageRoot.appendingPathComponent(".build/release", isDirectory: true)
        let applicationsDirectory = root.appendingPathComponent("Applications", isDirectory: true)
        let processClient = SwiftPackageProcessClient(
            build: { _ in
                SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
            },
            buildRelease: { _ in
                try FileManager.default.createDirectory(at: releaseBinDirectory, withIntermediateDirectories: true)
                try Data("binary".utf8).write(to: releaseBinDirectory.appendingPathComponent("MenuBarTool"))
                return SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
            },
            showBinPath: { _ in releaseBinDirectory },
            showReleaseBinPath: { _ in releaseBinDirectory },
            launch: { _ in },
            launchApp: { _ in },
            stripQuarantine: { _ in },
            signAdHoc: { _, _ in
                SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
            },
            verifyCodeSignature: { _ in
                SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
            }
        )
        let client = ToolAppBundleClient.live(
            processClient: processClient,
            iconClient: ToolIconClient { _ in
                throw ToolAppBundleError.iconEncodingFailed
            }
        )
        let request = ToolAppBundleRequest(
            displayName: "Menu Bar Tool",
            executableName: "MenuBarTool",
            bundleIdentifier: "com.ironsmith.tests.menu-bar-tool",
            packageRootURL: packageRoot,
            sandboxEnabled: true,
            settings: ToolGenerationSettings(appKind: .menuBar)
        )

        let appURL = try await client.exportApp(request, applicationsDirectory)

        let plist = try Self.plistDictionary(at: appURL.appendingPathComponent("Contents/Info.plist"))
        #expect(plist["LSUIElement"] as? Bool == true)
        #expect(plist["IronsmithQuitOnLastWindowClose"] == nil)
    }

    @MainActor
    @Test
    func appBundlerRestoresExistingBundleWhenFinalVerificationFails() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let packageRoot = root.appendingPathComponent("RestoredTool", isDirectory: true)
        let releaseBinDirectory = packageRoot.appendingPathComponent(".build/release", isDirectory: true)
        let existingAppURL = packageRoot.appendingPathComponent("Restored Tool.app", isDirectory: true)
        let existingMarkerURL = existingAppURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("old-marker.txt")
        try FileManager.default.createDirectory(
            at: existingMarkerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("previous bundle".utf8).write(to: existingMarkerURL)

        let processClient = SwiftPackageProcessClient(
            build: { _ in
                SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
            },
            buildRelease: { _ in
                try FileManager.default.createDirectory(at: releaseBinDirectory, withIntermediateDirectories: true)
                try Data("binary".utf8).write(to: releaseBinDirectory.appendingPathComponent("RestoredTool"))
                return SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
            },
            showBinPath: { _ in releaseBinDirectory },
            showReleaseBinPath: { _ in releaseBinDirectory },
            launch: { _ in },
            launchApp: { _ in },
            stripQuarantine: { _ in },
            signAdHoc: { _, _ in
                SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
            },
            verifyCodeSignature: { appURL in
                if appURL == existingAppURL {
                    return SwiftPackageBuildResult(
                        succeeded: false,
                        stdout: "",
                        stderr: "final verification failed",
                        terminationStatus: 1
                    )
                }
                return SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
            }
        )
        let client = ToolAppBundleClient.live(
            processClient: processClient,
            iconClient: ToolIconClient { _ in
                throw ToolAppBundleError.iconEncodingFailed
            }
        )
        let request = ToolAppBundleRequest(
            displayName: "Restored Tool",
            executableName: "RestoredTool",
            bundleIdentifier: "com.ironsmith.tests.restored-tool",
            packageRootURL: packageRoot,
            sandboxEnabled: false
        )

        do {
            _ = try await client.buildInternalApp(request)
            Issue.record("Expected final code signature verification to fail.")
        } catch {
            guard case ToolAppBundleError.signatureVerificationFailed(let output) = error else {
                throw error
            }
            #expect(output == "final verification failed")
        }

        #expect(try String(contentsOf: existingMarkerURL, encoding: .utf8) == "previous bundle")
        #expect(!(FileManager.default.fileExists(atPath: existingAppURL.appendingPathComponent("Contents/MacOS/RestoredTool").path)))
    }

    @MainActor
    @Test
    func appBundlerCompletesBundleWhenIconGenerationFails() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let packageRoot = root.appendingPathComponent("NoIconTool", isDirectory: true)
        let releaseBinDirectory = packageRoot.appendingPathComponent(".build/release", isDirectory: true)

        let capture = BundleProcessCapture()
        let processClient = SwiftPackageProcessClient(
            build: { _ in
                SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
            },
            buildRelease: { _ in
                try FileManager.default.createDirectory(at: releaseBinDirectory, withIntermediateDirectories: true)
                try Data("binary".utf8).write(to: releaseBinDirectory.appendingPathComponent("NoIconTool"))
                return SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
            },
            showBinPath: { _ in releaseBinDirectory },
            showReleaseBinPath: { _ in releaseBinDirectory },
            launch: { _ in },
            launchApp: { _ in },
            stripQuarantine: { _ in },
            signAdHoc: { appURL, entitlementsURL in
                await capture.recordSign(appURL: appURL, entitlementsURL: entitlementsURL)
                return SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
            },
            verifyCodeSignature: { appURL in
                await capture.recordVerify(appURL)
                return SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
            }
        )
        let client = ToolAppBundleClient.live(
            processClient: processClient,
            iconClient: ToolIconClient { _ in
                throw ToolAppBundleError.iconEncodingFailed
            }
        )
        let request = ToolAppBundleRequest(
            displayName: "No Icon Tool",
            executableName: "NoIconTool",
            bundleIdentifier: "com.ironsmith.tests.no-icon-tool",
            packageRootURL: packageRoot,
            sandboxEnabled: true
        )

        let appURL = try await client.buildInternalApp(request)

        let plist = try Self.plistDictionary(at: appURL.appendingPathComponent("Contents/Info.plist"))
        let entitlements = try Self.plistDictionary(at: request.layout.sandboxEntitlementsURL)
        #expect(FileManager.default.fileExists(atPath: appURL.appendingPathComponent("Contents/MacOS/NoIconTool").path))
        #expect(FileManager.default.fileExists(atPath: appURL.appendingPathComponent("Contents/Resources").path))
        #expect(plist["CFBundleIdentifier"] as? String == request.bundleIdentifier)
        #expect(plist["CFBundleIconFile"] == nil)
        #expect(plist["LSUIElement"] as? Bool == true)
        for permission in GeneratedAppResourcePermission.allCases {
            for usageDescriptionKey in permission.usageDescriptionKeys {
                #expect(plist[usageDescriptionKey] == nil)
            }
            for entitlementKey in permission.sandboxEntitlementKeys {
                #expect(entitlements[entitlementKey] == nil)
            }
        }
        let recordedSignedAppURL = await capture.signedAppURL
        let signedAppURL = try #require(recordedSignedAppURL)
        #expect(signedAppURL != appURL)
        #expect(signedAppURL.deletingLastPathComponent() == appURL.deletingLastPathComponent())
        #expect(await capture.signedEntitlementsURL == request.layout.sandboxEntitlementsURL)
        #expect(await capture.verifiedAppURL == appURL)
    }

    @MainActor
    @Test
    func iconClientCreatesFallbackICNSWhenImagePlaygroundFails() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let packageRoot = root.appendingPathComponent("FallbackIconTool", isDirectory: true)
        let layout = ToolPackageLayout(packageRootURL: packageRoot, executableName: "FallbackIconTool")
        let iconPrompt = "Silver hammer"
        let client = ToolIconClient.live(
            foregroundClient: .noop,
            imageGenerator: { _ in
                throw ToolAppBundleError.iconGenerationProducedNoImage
            }
        )

        let iconURL = try await client.ensureIconAssets(
            ToolIconRequest(
                displayName: "Fallback Icon",
                iconPrompt: iconPrompt,
                layout: layout
            )
        )

        let icnsData = try Data(contentsOf: layout.cachedAppIconICNSURL)
        let pngData = try Data(contentsOf: layout.cachedAppIconPNGURL)
        #expect(iconURL == layout.cachedAppIconICNSURL)
        #expect(!(icnsData.isEmpty))
        #expect(!(pngData.isEmpty))
        let pngSize = try Self.imagePixelSize(at: layout.cachedAppIconPNGURL)
        #expect(max(pngSize.width, pngSize.height) <= 256)
    }

    @MainActor
    @Test
    func iconClientFallbackPaletteVariesByToolName() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let client = ToolIconClient.live(
            foregroundClient: .noop,
            imageGenerator: { _ in
                throw ToolAppBundleError.iconGenerationProducedNoImage
            }
        )
        let amberLayout = ToolPackageLayout(
            packageRootURL: root.appendingPathComponent("AmberOak", isDirectory: true),
            executableName: "AmberOak"
        )
        let azureLayout = ToolPackageLayout(
            packageRootURL: root.appendingPathComponent("AzureOpal", isDirectory: true),
            executableName: "AzureOpal"
        )

        _ = try await client.ensureIconAssets(
            ToolIconRequest(
                displayName: "Amber Oak",
                layout: amberLayout
            )
        )
        _ = try await client.ensureIconAssets(
            ToolIconRequest(
                displayName: "Azure Opal",
                layout: azureLayout
            )
        )

        let amberPNG = try Data(contentsOf: amberLayout.cachedAppIconPNGURL)
        let azurePNG = try Data(contentsOf: azureLayout.cachedAppIconPNGURL)
        #expect(amberPNG != azurePNG)
    }

    @Test
    func processHelpersParseStructuredDiagnostics() {
        let root = URL(fileURLWithPath: "/tmp/GeneratedTool", isDirectory: true)
        let output = """
        /tmp/GeneratedTool/Sources/GeneratedTool/ContentView.swift:16:27: error: extra argument 'onDecrement' in call
        14 | Stepper(...)
        15 | ...
        16 | ...
        """

        let diagnostics = SwiftPackageProcessClient.parseDiagnostics(
            in: output,
            packageRootURL: root
        )

        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.relativePath == "Sources/GeneratedTool/ContentView.swift")
        #expect(diagnostics.first?.line == 16)
        #expect(diagnostics.first?.column == 27)
        #expect(diagnostics.first?.severity == .error)
        #expect(diagnostics.first?.message == "extra argument 'onDecrement' in call")
    }

    @Test
    func diagnosticsLogRendersCompactDiagnosticsByDefault() {
        let diagnostics = [
            SwiftCompilerDiagnostic(
                relativePath: "Sources/GeneratedTool/ContentView.swift",
                line: 16,
                column: 27,
                severity: .error,
                message: "extra argument 'onDecrement' in call",
                supportingLines: [
                    "14 | Stepper(...)",
                    "   | `- error: extra argument 'onDecrement' in call"
                ]
            ),
            SwiftCompilerDiagnostic(
                relativePath: "Sources/GeneratedTool/ContentView.swift",
                line: 20,
                column: 12,
                severity: .error,
                message: "cannot find 'payment' in scope",
                supportingLines: []
            ),
            SwiftCompilerDiagnostic(
                relativePath: "Sources/GeneratedTool/ContentView.swift",
                line: 20,
                column: 12,
                severity: .error,
                message: "cannot find 'payment' in scope",
                supportingLines: []
            )
        ]

        let rendered = AgentDiagnosticsLog.renderDiagnostics(diagnostics, limit: 1)

        #expect(rendered.contains("Sources/GeneratedTool/ContentView.swift:16:27: error: extra argument 'onDecrement' in call"))
        #expect(!(rendered.contains("14 | Stepper")))
        #expect(rendered.contains("... 1 more diagnostics omitted"))
        #expect(rendered.contains("... 1 duplicate diagnostics omitted"))
    }

    @Test
    func diagnosticsLogCompactsRepeatedRepairSnippets() {
        let snippets = [
            ContentViewRepairSnippet(startLine: 1, endLine: 3, text: "Text(\"A\")\nText(\"B\")"),
            ContentViewRepairSnippet(startLine: 1, endLine: 3, text: "Text(\"A\")\nText(\"B\")"),
            ContentViewRepairSnippet(startLine: 10, endLine: 12, text: "Text(\"C\")"),
            ContentViewRepairSnippet(startLine: 20, endLine: 22, text: "Text(\"D\")")
        ]

        let rendered = AgentDiagnosticsLog.renderRepairSnippets(snippets, limit: 500)

        #expect(rendered.contains("Lines 1-3"))
        #expect(rendered.contains("Lines 10-12"))
        #expect(!(rendered.contains("Lines 20-22")))
        #expect(rendered.contains("... 1 more relevant excerpts omitted"))
        #expect(rendered.contains("... 1 duplicate excerpts omitted"))
    }

    @Test
    func diagnosticsLogTruncatesPatchFields() {
        let patch = ContentViewDeterministicEdit(
            operation: .replaceSection,
            target: String(repeating: "target\n", count: 80),
            replacement: String(repeating: "replacement\n", count: 80),
            section: "Body"
        )

        let rendered = AgentDiagnosticsLog.renderDeterministicEdit(patch, fieldLimit: 40)

        #expect(rendered.contains("operation: replaceSection"))
        #expect(rendered.contains("["))
        #expect(rendered.contains("chars omitted"))
        #expect(rendered.count < 400)
    }

    @Test
    func toolGenerationErrorDetectsContextWindowFailures() {
        #expect(ToolGenerationError.isContextWindowExceeded(FakeAgentError.contextWindow))
        #expect(!(ToolGenerationError.isContextWindowExceeded(FakeAgentError.expected)))
    }
}
