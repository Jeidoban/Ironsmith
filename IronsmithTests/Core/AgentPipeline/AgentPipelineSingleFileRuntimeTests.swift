import AnyLanguageModel
import Foundation
import ImageIO
import SwiftData
import Testing
@testable import Ironsmith

extension AgentPipelineTests {
    @MainActor
    @Test
    func singleFileRuntimeWritesFixedScaffoldAndSingleEditableFile() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let processClient = SwiftPackageProcessClient(
            build: { _ in
                SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
            },
            showBinPath: { packageRoot in
                packageRoot.appendingPathComponent(".build/debug", isDirectory: true)
            },
            launch: { _ in },
            stripQuarantine: { _ in }
        )
        let contentViewSource = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                Text("single file")
            }
        }
        """
        let appBundleCapture = AppBundleCapture()
        let appBundleClient = ToolAppBundleClient(
            buildInternalApp: { request in
                await appBundleCapture.recordBuild(request)
                return request.internalAppBundleURL
            },
            exportApp: { request, applicationsDirectoryURL in
                await appBundleCapture.recordExport(request)
                return applicationsDirectoryURL.appendingPathComponent("\(request.displayName).app", isDirectory: true)
            },
            launchApp: { _ in },
            appExists: { _ in true }
        )
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel.fixed(contentViewSource),
            generationOptions: GenerationOptions(),
            repairStrategy: .modelDiff(maxHunksPerTurn: 3),
            toolsDirectoryURL: toolsDirectory,
            processClient: processClient,
            appBundleClient: appBundleClient,
            metadataClient: ToolMetadataClient { _ in
                ToolMetadataSuggestion(
                    displayName: "Tiny Tool",
                    iconPrompt: "",
                    menuBarSystemImage: "timer"
                )
            }
        )

        let resourcePermissions = GeneratedAppResourcePermissions([.location, .calendar])
        let sandboxPermissions = GeneratedAppSandboxPermissions([.internet])
        let settings = ToolGenerationSettings(
            appKind: .menuBar,
            sandboxPermissions: sandboxPermissions,
            resourcePermissions: resourcePermissions
        )
        let result = try await runtime.generateTool(
            for: "Build a tiny tool",
            settings: settings
        )

        let contentViewURL = result.packageRootURL
            .appendingPathComponent("Sources/\(result.executableName)/ContentView.swift")
        let appEntryURL = result.packageRootURL
            .appendingPathComponent("Sources/\(result.executableName)/\(result.executableName).swift")
        let layout = ToolPackageLayout(packageRootURL: result.packageRootURL, executableName: result.executableName)
        #expect(FileManager.default.fileExists(atPath: contentViewURL.path))
        #expect(FileManager.default.fileExists(atPath: appEntryURL.path))
        #expect(layout.contentViewSourcePath == "Sources/\(result.executableName)/ContentView.swift")
        #expect(result.settings.appKind == .menuBar)
        #expect(result.settings.menuBarSystemImage == "timer")
        let appEntrySource = try String(contentsOf: appEntryURL, encoding: .utf8)
        #expect(appEntrySource.contains("MenuBarExtra(\"Tiny Tool\", systemImage: \"timer\")"))
        #expect(appEntrySource.contains(".menuBarExtraStyle(.window)"))
        #expect(!(appEntrySource.contains("WindowGroup")))
        #expect(await appBundleCapture.builtRequests.first?.sandboxPermissions == sandboxPermissions)
        #expect(await appBundleCapture.builtRequests.first?.resourcePermissions == resourcePermissions)
        #expect(await appBundleCapture.builtRequests.first?.appKind == .menuBar)
    }
}
