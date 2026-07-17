import AnyLanguageModel
import Foundation
import ImageIO
import SwiftData
import Testing
@testable import Ironsmith

extension AgentPipelineTests {
    @MainActor
    @Test
    func codexIconGenerationStaggersOnlyWhenCodexPromptRefinementCanOverlap() {
        let base = OpenAILanguageModel(
            baseURL: OpenAICodexBackend.backendBaseURL,
            apiKey: "token",
            model: "gpt-5.6-luna",
            apiVariant: .responses
        )
        let codexModel = OpenAICodexLanguageModel(base: base, usesResponsesLite: true)
        let regularModel = StubAgentLanguageModel { _, _ in "" }

        #expect(
            SingleFileToolGenerationRuntime.shouldStaggerIconGeneration(
                imageGenerationProvider: .openAI,
                promptRefinementEnabled: true,
                promptRefinementModel: codexModel
            )
        )
        #expect(
            !SingleFileToolGenerationRuntime.shouldStaggerIconGeneration(
                imageGenerationProvider: .gemini,
                promptRefinementEnabled: true,
                promptRefinementModel: codexModel
            )
        )
        #expect(
            !SingleFileToolGenerationRuntime.shouldStaggerIconGeneration(
                imageGenerationProvider: .openAI,
                promptRefinementEnabled: false,
                promptRefinementModel: codexModel
            )
        )
        #expect(
            !SingleFileToolGenerationRuntime.shouldStaggerIconGeneration(
                imageGenerationProvider: .openAI,
                promptRefinementEnabled: true,
                promptRefinementModel: regularModel
            )
        )
        #expect(SingleFileToolGenerationRuntime.codexIconGenerationStagger == .seconds(1))
    }

    @MainActor
    @Test
    func newToolSourceGenerationRunsWhileIconGenerationIsWaiting() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let modelProbe = StreamingResponseProbe()
        let iconProbe = StreamingResponseProbe()
        let model = PartialThenSuspendingLanguageModel(
            partialResponse: "import SwiftUI\nstruct ContentView: View {",
            probe: modelProbe
        )
        let iconClient = ToolIconClient { request in
            await iconProbe.recordStart(promptDescription: request.displayName)
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return request.layout.cachedAppIconICNSURL
        }
        let runtime = Self.makeRuntime(
            languageModel: model,
            toolsDirectoryURL: toolsDirectory,
            iconClient: iconClient,
            metadataClient: ToolMetadataClient { _ in
                ToolMetadataSuggestion(displayName: "Parallel Icon", iconPrompt: "An anvil")
            }
        )

        let task = Task {
            try await runtime.generateTool(
                for: "Build a tool while its icon is chosen",
                settings: .default,
                imageGenerationProvider: .imagePlayground
            )
        }
        await Self.eventually {
            let iconStarted = await iconProbe.didStart
            let modelStarted = await modelProbe.didStart
            return iconStarted && modelStarted
        }

        #expect(await iconProbe.didStart)
        #expect(await modelProbe.didStart)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation to stop the in-progress generation.")
        } catch is CancellationError {
            // Expected.
        }
    }

    @Test
    func cancellingAnIconWaitDoesNotCancelTheParallelIconGeneration() async throws {
        let coordinator = ToolIconGenerationCoordinator()
        let probe = StreamingResponseProbe()
        let packageRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("icon-wait-\(UUID().uuidString)", isDirectory: true)
        let iconGeneration = await coordinator.generation(for: packageRootURL) {
            await probe.recordStart(promptDescription: "icon")
            do {
                try await Task.sleep(for: .seconds(10))
                await probe.recordFinish()
            } catch {
                await probe.recordCancel()
                throw error
            }
        }
        await Self.eventually { await probe.didStart }

        let waitingTask = Task {
            try await iconGeneration.wait()
        }

        waitingTask.cancel()

        do {
            try await waitingTask.value
            Issue.record("Expected cancellation while waiting for the icon task.")
        } catch is CancellationError {
            // Expected.
        }
        #expect(!(await probe.didCancel))

        await coordinator.cancelGeneration(for: packageRootURL)
        await Self.eventually { await probe.didCancel }
        #expect(await probe.didCancel)
    }

    @Test
    func repeatedIconRequestReusesGenerationAlreadyRunningForPackage() async throws {
        let coordinator = ToolIconGenerationCoordinator()
        let probe = StreamingResponseProbe()
        let gate = AsyncTestGate()
        let packageRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("icon-reuse-\(UUID().uuidString)", isDirectory: true)
        let firstGeneration = await coordinator.generation(for: packageRootURL) {
            await probe.recordStart(promptDescription: "first")
            await gate.wait()
            await probe.recordFinish()
        }
        await Self.eventually { await probe.didStart }

        let resumedGeneration = await coordinator.generation(for: packageRootURL) {
            await probe.recordStart(promptDescription: "duplicate")
        }

        #expect(await probe.prompts == ["first"])
        await gate.open()
        try await firstGeneration.wait()
        try await resumedGeneration.wait()
        #expect(await probe.prompts == ["first"])
        #expect(await probe.didFinish)
    }

    @MainActor
    @Test(arguments: [
        ToolImageGenerationProvider.ironsmith,
        ToolImageGenerationProvider.openAI,
        ToolImageGenerationProvider.gemini,
    ])
    func pausingGenerationAllowsHostedIconGenerationToFinish(
        provider: ToolImageGenerationProvider
    ) async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let modelProbe = StreamingResponseProbe()
        let iconProbe = StreamingResponseProbe()
        let model = PartialThenSuspendingLanguageModel(
            partialResponse: "import SwiftUI\nstruct ContentView: View {",
            probe: modelProbe
        )
        let iconClient = ToolIconClient { request in
            await iconProbe.recordStart(promptDescription: request.imageProvider.rawValue)
            do {
                try await Task.sleep(for: .milliseconds(250))
                await iconProbe.recordFinish()
                return request.layout.cachedAppIconICNSURL
            } catch {
                await iconProbe.recordCancel()
                throw error
            }
        }
        let runtime = Self.makeRuntime(
            languageModel: model,
            toolsDirectoryURL: toolsDirectory,
            iconClient: iconClient,
            metadataClient: ToolMetadataClient { _ in
                ToolMetadataSuggestion(displayName: "Paused Icon", iconPrompt: "An anvil")
            }
        )

        let generationTask = Task {
            try await runtime.generateTool(
                for: "Build a tool while its hosted icon is generated",
                settings: .default,
                imageGenerationProvider: provider,
                lifecycle: ToolGenerationLifecycle(preservesCreatedPackageOnCancellation: true)
            )
        }
        await Self.eventually {
            let modelStarted = await modelProbe.didStart
            let iconStarted = await iconProbe.didStart
            return modelStarted && iconStarted
        }

        generationTask.cancel()
        do {
            _ = try await generationTask.value
            Issue.record("Expected the source generation to stop.")
        } catch is CancellationError {
            // Expected.
        }

        await Self.eventually { await iconProbe.didFinish }
        #expect(await iconProbe.didFinish)
        #expect(!(await iconProbe.didCancel))
        #expect(await iconProbe.prompts == [provider.rawValue])
    }

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
            pipelineConfiguration: .ironsmithSpark(repairStrategy: .deterministicOnly),
            toolsDirectoryURL: toolsDirectory,
            processClient: .live,
            appBundleClient: .noOp(),
            metadataClient: ToolMetadataClient { _ in
                ToolMetadataSuggestion(displayName: "Cancel Tool", iconPrompt: "")
            }
        )

        let task = Task {
            try await runtime.generateTool(for: "Build a cancellable tool", settings: .default)
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
    func flameOnlyExtractsTheModelEnvelopeBeforeItsInitialBuild() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let generatedSource = """
        import SwiftUI

        private struct AppFeedback {}

        struct ContentView: View {
            @State private var feedback: AppFeedback?

            var body: some View {
                Text("Flame source")
            }
        }
        """
        let response = """
        <thinking>This explanation should not be written into ContentView.swift.</thinking>
        Here is the completed ContentView.swift:
        ```swift
        \(generatedSource)
        ```
        The implementation is complete.
        """
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
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel.fixed(response),
            generationOptions: GenerationOptions(),
            pipelineConfiguration: .ironsmithFlame(
                repairStrategy: .modelSearchReplace(
                    maxPatchBlocksPerTurn: ToolGenerationRepairPolicy.largeModelPatchBlocksPerTurn
                )
            ),
            toolsDirectoryURL: toolsDirectory,
            processClient: processClient,
            appBundleClient: .noOp(),
            metadataClient: ToolMetadataClient { _ in
                ToolMetadataSuggestion(displayName: "Flame Envelope", iconPrompt: "")
            }
        )

        let result = try await runtime.generateTool(
            for: "Build a Flame envelope test",
            settings: .default
        )

        let contentView = try String(contentsOf: Self.contentViewURL(for: result), encoding: .utf8)
        #expect(contentView == generatedSource)
        #expect(await formatCapture.formattedURLs.isEmpty)
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
        let generationClient = ToolGenerationClient.live(dependencies: .live(
            toolsDirectoryURL: toolsDirectory,
            processClient: processClient,
            appBundleClient: .noOp(),
            iconClient: .noOp,
            metadataClient: .fallback()
        ))
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
        #expect(!FileManager.default.fileExists(atPath: tool.packageRootURL.appendingPathComponent("ironsmith-manifest.json").path))
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
        let generationClient = ToolGenerationClient.live(dependencies: .live(
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
        ))
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
        let generationClient = ToolGenerationClient.live(dependencies: .live(
            toolsDirectoryURL: toolsDirectory,
            processClient: processClient,
            appBundleClient: .noOp(),
            iconClient: .noOp,
            metadataClient: .fallback()
        ))
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
        let layout = ToolPackageLayout(packageRootURL: tool.packageRootURL, executableName: tool.executableName)
        let contentView = try String(
            contentsOf: tool.packageRootURL.appendingPathComponent(layout.contentViewSourcePath),
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
        let generationClient = ToolGenerationClient.live(dependencies: .live(
            toolsDirectoryURL: toolsDirectory,
            processClient: processClient,
            appBundleClient: .noOp(),
            iconClient: .noOp,
            metadataClient: .fallback()
        ))
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
        let layout = ToolPackageLayout(packageRootURL: tool.packageRootURL, executableName: tool.executableName)
        let contentView = try String(
            contentsOf: tool.packageRootURL.appendingPathComponent(layout.contentViewSourcePath),
            encoding: .utf8
        )
        #expect(contentView.contains(#"Text("retried after context window")"#))
        #expect(await responses.count == 2)
    }
}
