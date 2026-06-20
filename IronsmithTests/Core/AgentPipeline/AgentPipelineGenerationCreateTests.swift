import AnyLanguageModel
import Foundation
import ImageIO
import SwiftData
import Testing
@testable import Ironsmith

extension AgentPipelineTests {
    @MainActor
    @Test
    func cancelledNewToolGenerationRemovesPartialPackage() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let probe = StreamingResponseProbe()
        let model = PartialThenSuspendingLanguageModel(
            partialResponse: """
            import SwiftUI

            struct ContentView: View {
            """,
            probe: probe
        )
        let runtime = Self.makeRuntime(
            languageModel: model,
            generationOptions: GenerationOptions(),
            repairStrategy: .deterministicOnly,
            toolsDirectoryURL: toolsDirectory,
            processClient: .live,
            appBundleClient: .noOp(),
            metadataClient: ToolMetadataClient { _ in
                ToolMetadataSuggestion(displayName: "Cancel Tool", iconPrompt: "")
            }
        )

        let task = Task {
            try await runtime.generateTool(for: "Build a cancellable tool", status: { _ in })
        }
        await Self.eventually {
            await probe.didStart
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected generation cancellation to throw.")
        } catch is CancellationError {
            // Expected.
        }

        let packageRoot = toolsDirectory.appendingPathComponent("cancel-tool", isDirectory: true)
        #expect(!(FileManager.default.fileExists(atPath: packageRoot.path)))
    }

    @MainActor
    @Test
    func liveGenerationClientCreatesPackageAndPersistsToolWithFakeModel() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let formatCapture = FormatCapture()
        let processClient = SwiftPackageProcessClient(
            build: { _ in
                SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
            },
            showBinPath: { packageRoot in
                packageRoot.appendingPathComponent(".build/debug", isDirectory: true)
            },
            launch: { _ in },
            stripQuarantine: { _ in },
            formatSwiftSource: { url in
                await formatCapture.record(url)
                return SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
            }
        )
        let generationClient = ToolGenerationClient.live(
            toolsDirectoryURL: toolsDirectory,
            processClient: processClient,
            appBundleClient: .noOp(),
            iconClient: .noOp,
            metadataClient: .fallback()
        )
        let store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: generationClient,
                runnerClient: ToolRunnerClient { _ in }
            )
        )
        let contentViewSource = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                Text("hello from generated tool")
                    .padding()
            }
        }
        """
        let inferenceStore = Self.inferenceStore(
            languageModel: StubAgentLanguageModel.fixed(contentViewSource)
        )
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)

        store.prompt = "Build a hello command"
        await store.submitPrompt(modelContext: context, inferenceStore: inferenceStore)

        let tool = try #require(try context.fetch(FetchDescriptor<StoredTool>()).first)
        #expect(tool.name == "Build A Hello Command")
        #expect(FileManager.default.fileExists(atPath: tool.packageManifestURL.path))
        #expect(FileManager.default.fileExists(atPath: tool.agentManifestURL.path))
        #expect(FileManager.default.fileExists(atPath: tool.packageRootURL.appendingPathComponent("Sources/BuildAHelloCommand/BuildAHelloCommand.swift").path))
        #expect(FileManager.default.fileExists(atPath: tool.packageRootURL.appendingPathComponent("Sources/BuildAHelloCommand/ContentView.swift").path))

        let contentView = try String(
            contentsOf: tool.packageRootURL.appendingPathComponent("Sources/BuildAHelloCommand/ContentView.swift"),
            encoding: .utf8
        )
        #expect(contentView.contains(#"Text("hello from generated tool")"#))
        #expect(await formatCapture.formattedURLs.contains(tool.packageRootURL.appendingPathComponent("Sources/BuildAHelloCommand/ContentView.swift")))
    }

    @MainActor
    @Test
    func liveGenerationClientUsesGeneratedMetadataForNameAndIconPrompt() async throws {
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
            stripQuarantine: { _ in },
            formatSwiftSource: { _ in
                SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
            }
        )
        let appBundleCapture = AppBundleCapture()
        let appBundleClient = ToolAppBundleClient(
            buildInternalApp: { request in
                await appBundleCapture.recordBuild(request)
                return request.internalAppBundleURL
            },
            exportApp: { request, applicationsDirectoryURL in
                applicationsDirectoryURL.appendingPathComponent("\(request.displayName).app", isDirectory: true)
            },
            launchApp: { _ in },
            appExists: { _ in true }
        )
        let iconPrompt = "Notebook and compass"
        let refinedPrompt = "Build a polished focus notes helper with tags, search, pinned notes, and a calm compact layout."
        let generationClient = ToolGenerationClient.live(
            toolsDirectoryURL: toolsDirectory,
            processClient: processClient,
            appBundleClient: appBundleClient,
            iconClient: .noOp,
            metadataClient: ToolMetadataClient { _ in
                ToolMetadataSuggestion(
                    displayName: "Focus Pad",
                    iconPrompt: iconPrompt,
                    menuBarSystemImage: "note.text"
                )
            },
            promptRefinementClient: ToolPromptRefinementClient { _ in
                refinedPrompt
            }
        )
        let store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: generationClient,
                runnerClient: ToolRunnerClient { _ in }
            )
        )
        let contentViewSource = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                Text("metadata named tool")
            }
        }
        """
        let inferenceStore = Self.inferenceStore(
            languageModel: StubAgentLanguageModel.fixed(contentViewSource)
        )
        inferenceStore.generationPreferences.generatedAppCameraAccessEnabled = true
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)

        store.appKind = .menuBar
        store.prompt = "Build a focused notes helper with quick tags"
        await store.submitPrompt(modelContext: context, inferenceStore: inferenceStore)

        let tool = try #require(try context.fetch(FetchDescriptor<StoredTool>()).first)
        #expect(tool.name == "Focus Pad")
        #expect(tool.executableName == "FocusPad")
        #expect(tool.appKind == .menuBar)
        #expect(tool.validatedMenuBarSystemImage == "note.text")
        #expect(tool.storedResourcePermissions?.enabled == [.camera])
        #expect(tool.pendingPrompt == nil)
        #expect(tool.packageRootURL.lastPathComponent == "focus-pad")
        let appEntryURL = tool.packageRootURL.appendingPathComponent("Sources/FocusPad/FocusPad.swift")
        #expect(FileManager.default.fileExists(atPath: appEntryURL.path))
        let appEntrySource = try String(contentsOf: appEntryURL, encoding: .utf8)
        #expect(appEntrySource.contains("MenuBarExtra(\"Focus Pad\", systemImage: \"note.text\")"))
        #expect(await appBundleCapture.builtRequests.first?.iconPrompt == iconPrompt)
        #expect(await appBundleCapture.builtRequests.first?.displayName == "Focus Pad")
        #expect(await appBundleCapture.builtRequests.first?.appKind == .menuBar)
        #expect(await appBundleCapture.builtRequests.first?.menuBarSystemImage == "note.text")
    }

    @MainActor
    @Test
    func liveGenerationClientRegeneratesCompiledPlaceholderScaffold() async throws {
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
            stripQuarantine: { _ in },
            formatSwiftSource: { _ in
                SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
            }
        )
        let responses = LanguageModelResponseQueue([
            """
            @State private var count = 0
            """,
            """
            import SwiftUI

            struct ContentView: View {
                var body: some View {
                    Text("real regenerated tool")
                }
            }
            """
        ])
        let generationClient = ToolGenerationClient.live(
            toolsDirectoryURL: toolsDirectory,
            processClient: processClient,
            appBundleClient: .noOp(),
            iconClient: .noOp,
            metadataClient: .fallback()
        )
        let store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: generationClient,
                runnerClient: ToolRunnerClient { _ in }
            )
        )
        let inferenceStore = Self.inferenceStore(
            languageModel: StubAgentLanguageModel { _, _ in
                try await responses.next()
            }
        )
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)

        store.prompt = "Build a tool that should not stay placeholder"
        await store.submitPrompt(modelContext: context, inferenceStore: inferenceStore)

        let tool = try #require(try context.fetch(FetchDescriptor<StoredTool>()).first)
        let manifestData = try Data(contentsOf: tool.agentManifestURL)
        let manifest = try JSONDecoder().decode(ToolManifest.self, from: manifestData)
        let contentView = try String(
            contentsOf: tool.packageRootURL.appendingPathComponent("Sources/\(manifest.executableName)/ContentView.swift"),
            encoding: .utf8
        )
        #expect(contentView.contains(#"Text("real regenerated tool")"#))
        #expect(!(contentView.contains(#"Text("Generated Tool")"#)))
        #expect(await responses.count == 2)
    }

    @MainActor
    @Test
    func liveGenerationClientRetriesInitialContextWindowFailure() async throws {
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
            stripQuarantine: { _ in },
            formatSwiftSource: { _ in
                SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
            }
        )
        let responses = ContextWindowThenSuccess(
            success: """
            import SwiftUI

            struct ContentView: View {
                var body: some View {
                    Text("retried after context window")
                }
            }
            """
        )
        let generationClient = ToolGenerationClient.live(
            toolsDirectoryURL: toolsDirectory,
            processClient: processClient,
            appBundleClient: .noOp(),
            iconClient: .noOp,
            metadataClient: .fallback()
        )
        let store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: generationClient,
                runnerClient: ToolRunnerClient { _ in }
            )
        )
        let inferenceStore = Self.inferenceStore(
            languageModel: StubAgentLanguageModel { _, _ in
                try await responses.next()
            }
        )
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)

        store.prompt = "Build a tool after context retry"
        await store.submitPrompt(modelContext: context, inferenceStore: inferenceStore)

        let tool = try #require(try context.fetch(FetchDescriptor<StoredTool>()).first)
        let manifestData = try Data(contentsOf: tool.agentManifestURL)
        let manifest = try JSONDecoder().decode(ToolManifest.self, from: manifestData)
        let contentView = try String(
            contentsOf: tool.packageRootURL.appendingPathComponent("Sources/\(manifest.executableName)/ContentView.swift"),
            encoding: .utf8
        )
        #expect(contentView.contains(#"Text("retried after context window")"#))
        #expect(await responses.count == 2)
    }
}
