import AnyLanguageModel
import Foundation
import SwiftData
import Testing
@testable import Ironsmith

extension AgentPipelineTests {
    @MainActor
    @Test
    func createGenerationPersistsPlaceholderToolBeforeMetadataCompletes() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let metadataGate = MetadataGenerationGate()
        defer {
            Task {
                await metadataGate.release()
            }
        }

        let generationClient = ToolGenerationClient.live(dependencies: .live(
            toolsDirectoryURL: toolsDirectory,
            processClient: Self.successfulProcessClient(),
            appBundleClient: .noOp(),
            iconClient: .noOp,
            metadataClient: ToolMetadataClient { _ in
                await metadataGate.waitForRelease()
                return ToolMetadataSuggestion(displayName: "Named Later", iconPrompt: "")
            },
            promptRefinementClient: .disabled()
        ))
        let store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: generationClient,
                runnerClient: ToolRunnerClient { _ in }
            )
        )
        let inferenceStore = Self.inferenceStore(
            languageModel: StubAgentLanguageModel.fixed(Self.simpleContentViewSource(text: "ready"))
        )
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)

        let prompt = "Build a named later app"
        store.prompt = prompt
        store.startPromptSubmission(modelContext: context, inferenceStore: inferenceStore)

        let placeholderTool = try await waitForFirstTool(in: context) { tool in
            tool.name == "New App"
                && tool.generationState == .generating
                && tool.generationPhase == .planning
                && tool.generationMode == .create
        }

        #expect(placeholderTool.pendingPrompt == prompt)
        #expect(!(FileManager.default.fileExists(atPath: placeholderTool.packageManifestURL.path)))

        await metadataGate.release()
        let completedTool = try await waitForFirstTool(in: context) { tool in
            tool.id == placeholderTool.id && tool.generationState == .ready
        }

        #expect(completedTool.name == "Named Later")
        #expect(completedTool.executableName == "NamedLater")
        #expect(completedTool.packageRootURL.lastPathComponent == "named-later")
        #expect(FileManager.default.fileExists(atPath: completedTool.packageManifestURL.path))
        #expect(store.presentedErrorMessage == nil)
        #expect(!(store.isGenerating))
    }

    @MainActor
    @Test
    func createGenerationPersistsStoppedToolAndDraftWhenCancelledDuringSourceStream() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let partialSource = """
        import SwiftUI

        struct ContentView: View {
        """
        let probe = StreamingResponseProbe()
        let generationClient = ToolGenerationClient.live(dependencies: .live(
            toolsDirectoryURL: toolsDirectory,
            processClient: Self.successfulProcessClient(),
            appBundleClient: .noOp(),
            iconClient: .noOp,
            metadataClient: ToolMetadataClient { _ in
                ToolMetadataSuggestion(displayName: "Paused Tool", iconPrompt: "")
            },
            promptRefinementClient: .disabled()
        ))
        let store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: generationClient,
                runnerClient: ToolRunnerClient { _ in }
            )
        )
        let inferenceStore = Self.inferenceStore(
            languageModel: PartialThenSuspendingLanguageModel(
                partialResponse: partialSource,
                probe: probe
            )
        )
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)

        let prompt = "Build a tool that can pause"
        store.prompt = prompt
        store.startPromptSubmission(modelContext: context, inferenceStore: inferenceStore)

        let generatingTool = try await waitForFirstTool(in: context) { tool in
            let draftURL = ToolPackageLayout.pendingContentViewDraftURL(for: tool.packageRootURL)
            return tool.generationState == .generating
                && tool.generationPhase == .generatingSource
                && FileManager.default.fileExists(atPath: draftURL.path)
        }
        let draftURL = ToolPackageLayout.pendingContentViewDraftURL(for: generatingTool.packageRootURL)
        #expect(generatingTool.generationMode == .create)
        #expect(generatingTool.pendingPrompt == prompt)
        #expect(try String(contentsOf: draftURL, encoding: .utf8) == partialSource)
        #expect(await probe.didStart)

        store.cancelGeneration()
        let stoppedTool = try await waitForFirstTool(in: context) { tool in
            tool.generationState == .stopped
        }

        #expect(stoppedTool.id == generatingTool.id)
        #expect(stoppedTool.generationPhase == .generatingSource)
        #expect(stoppedTool.generationMode == .create)
        #expect(stoppedTool.pendingPrompt == prompt)
        #expect(FileManager.default.fileExists(atPath: draftURL.path))
        #expect(store.presentedErrorMessage == nil)
        #expect(!(store.isGenerating))
    }

    @MainActor
    @Test
    func resumePartialSourceContinuesDraftBeforeBuilding() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let executableName = "ResumeCreate"
        let tool = try Self.makeExistingTool(
            toolsDirectory: toolsDirectory,
            executableName: executableName,
            source: ""
        )
        let layout = ToolPackageLayout(packageRootURL: tool.packageRootURL, executableName: executableName)
        let partialSource = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                Text("res
        """
        let continuation = """
        umed")
            }
        }
        """
        try FileManager.default.createDirectory(at: layout.packageMetadataDirectoryURL, withIntermediateDirectories: true)
        try partialSource.write(to: layout.pendingContentViewDraftURL, atomically: true, encoding: .utf8)
        tool.generationState = .stopped
        tool.generationPhase = .generatingSource
        tool.generationMode = .create
        tool.pendingPrompt = "Build a focused resumable source app"

        let promptCapture = PromptCapture()
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { prompt, _ in
                await promptCapture.record(prompt)
                return continuation
            },
            pipelineConfiguration: .ironsmithSpark(repairStrategy: .deterministicOnly),
            toolsDirectoryURL: toolsDirectory,
            processClient: Self.successfulProcessClient(),
            appBundleClient: .noOp(),
            metadataClient: .fallback()
        )

        let result = try await runtime.generateTool(
            for: "ignored because pending prompt is stored",
            existingTool: tool,
            settings: .default
        )

        let contentView = try String(contentsOf: Self.contentViewURL(for: result), encoding: .utf8)
        #expect(contentView.contains(#"Text("resumed")"#))
        #expect(!(FileManager.default.fileExists(atPath: layout.pendingContentViewDraftURL.path)))
        let prompts = await promptCapture.prompts
        #expect(prompts.count == 1)
        #expect(prompts.first?.contains("Continue the exact Swift source response") == true)
        #expect(prompts.first?.contains(partialSource) == true)
    }

    @MainActor
    @Test
    func resumePartialEditPatchAppliesCompletedDraftBlocksThenRequestsFreshPatch() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let executableName = "ResumeEdit"
        let source = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                VStack {
                    Text("old")
                    Text("later")
                }
            }
        }
        """
        let tool = try Self.makeExistingTool(
            toolsDirectory: toolsDirectory,
            executableName: executableName,
            source: source
        )
        let layout = ToolPackageLayout(packageRootURL: tool.packageRootURL, executableName: executableName)
        let contentViewURL = layout.sourceDirectoryURL.appendingPathComponent(layout.defaultContentViewFileName)
        let partialPatch = """
        --- a/ContentView.swift
        +++ b/ContentView.swift
        @@ -6,1 +6,1 @@
        -            Text("old")
        +            Text("partial")
        @@ -7,1 +7,1 @@
        -            Text("later")
        +            Text("
        """
        let freshPatch = """
        --- a/ContentView.swift
        +++ b/ContentView.swift
        @@ -7,1 +7,1 @@
        -            Text("later")
        +            Text("fresh")
        """
        try FileManager.default.createDirectory(at: layout.packageMetadataDirectoryURL, withIntermediateDirectories: true)
        try partialPatch.write(to: layout.pendingContentViewDraftURL, atomically: true, encoding: .utf8)
        tool.generationState = .stopped
        tool.generationPhase = .generatingEditDiff
        tool.generationMode = .edit
        tool.pendingPrompt = "Change old to new"

        let sourceBeforeResume = try String(contentsOf: contentViewURL, encoding: .utf8)
        #expect(sourceBeforeResume.contains(#"Text("old")"#))

        let promptCapture = PromptCapture()
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { prompt, _ in
                await promptCapture.record(prompt)
                return freshPatch
            },
            pipelineConfiguration: .ironsmithSpark(repairStrategy: .modelSearchReplace(maxPatchBlocksPerTurn: 1)),
            toolsDirectoryURL: toolsDirectory,
            processClient: Self.successfulProcessClient(),
            appBundleClient: .noOp(),
            metadataClient: .fallback()
        )

        let result = try await runtime.generateTool(
            for: "ignored because pending prompt is stored",
            existingTool: tool,
            settings: .default
        )

        let contentView = try String(contentsOf: Self.contentViewURL(for: result), encoding: .utf8)
        let previousSource = try String(
            contentsOf: layout.previousContentViewVersionURL,
            encoding: .utf8
        )
        #expect(contentView.contains(#"Text("partial")"#))
        #expect(contentView.contains(#"Text("fresh")"#))
        #expect(!(contentView.contains(#"Text("old")"#)))
        #expect(previousSource.contains(#"Text("old")"#))
        #expect(!(FileManager.default.fileExists(atPath: layout.pendingContentViewDraftURL.path)))
        let prompts = await promptCapture.prompts
        #expect(prompts.count == 1)
        #expect(prompts.first?.contains("Edit ContentView.swift by returning a unified diff only.") == true)
        #expect(prompts.first?.contains(#"Text("partial")"#) == true)
    }

    @MainActor
    @Test
    func resumePartialRepairPatchAppliesCompletedDraftBlocksBeforeBuilding() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let executableName = "ResumeRepair"
        let source = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                VStack {
                    Text("old")
                    Text("later")
                }
            }
        }
        """
        let tool = try Self.makeExistingTool(
            toolsDirectory: toolsDirectory,
            executableName: executableName,
            source: source
        )
        let layout = ToolPackageLayout(packageRootURL: tool.packageRootURL, executableName: executableName)
        let partialPatch = """
        <<<<<<< SEARCH
                    Text("old")
        =======
                    Text("partial")
        >>>>>>> REPLACE
        <<<<<<< SEARCH
                    Text("later")
        =======
                    Text("
        """
        try FileManager.default.createDirectory(at: layout.packageMetadataDirectoryURL, withIntermediateDirectories: true)
        try partialPatch.write(to: layout.pendingContentViewDraftURL, atomically: true, encoding: .utf8)
        tool.generationState = .stopped
        tool.generationPhase = .generatingRepairDiff
        tool.generationMode = .edit
        tool.pendingPrompt = "Repair the edit"

        let promptCapture = PromptCapture()
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { prompt, _ in
                await promptCapture.record(prompt)
                Issue.record("Resume from repair should build the salvaged source before asking for a model patch.")
                return ""
            },
            pipelineConfiguration: .ironsmithFlame(repairStrategy: .modelSearchReplace(maxPatchBlocksPerTurn: 2)),
            toolsDirectoryURL: toolsDirectory,
            processClient: Self.successfulProcessClient(),
            appBundleClient: .noOp(),
            metadataClient: .fallback(),
            versionBackupClient: .live
        )

        let result = try await runtime.generateTool(
            for: "ignored because pending prompt is stored",
            existingTool: tool,
            settings: .default
        )

        let contentView = try String(contentsOf: Self.contentViewURL(for: result), encoding: .utf8)
        #expect(contentView.contains(#"Text("partial")"#))
        #expect(contentView.contains(#"Text("later")"#))
        #expect(!(contentView.contains(#"Text("old")"#)))
        #expect(!(FileManager.default.fileExists(atPath: layout.pendingContentViewDraftURL.path)))
        #expect(await promptCapture.prompts.isEmpty)
    }

    @MainActor
    @Test
    func cancelledEditPatchKeepsDraftForResume() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let executableName = "CancelEdit"
        let source = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                VStack {
                    Text("old")
                    Text("later")
                }
            }
        }
        """
        let tool = try Self.makeExistingTool(
            toolsDirectory: toolsDirectory,
            executableName: executableName,
            source: source
        )
        let layout = ToolPackageLayout(packageRootURL: tool.packageRootURL, executableName: executableName)
        let partialPatch = """
        <<<<<<< SEARCH
                    Text("old")
        =======
                    Text("partial")
        >>>>>>> REPLACE
        <<<<<<< SEARCH
                    Text("later")
        =======
                    Text("
        """
        let probe = StreamingResponseProbe()
        let runtime = Self.makeRuntime(
            languageModel: PartialThenSuspendingLanguageModel(
                partialResponse: partialPatch,
                probe: probe
            ),
            pipelineConfiguration: .ironsmithFlame(repairStrategy: .modelSearchReplace(maxPatchBlocksPerTurn: 2)),
            toolsDirectoryURL: toolsDirectory,
            processClient: Self.successfulProcessClient(),
            appBundleClient: .noOp(),
            metadataClient: .fallback()
        )

        let task = Task {
            try await runtime.generateTool(
                for: "Change old to partial and later to fresh",
                existingTool: tool,
                settings: .default
            )
        }
        await Self.eventually {
            (try? String(contentsOf: layout.pendingContentViewDraftURL, encoding: .utf8)) == partialPatch
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected edit cancellation to throw.")
        } catch is CancellationError {
            // Expected.
        }

        let contentView = try String(contentsOf: layout.sourceDirectoryURL.appendingPathComponent(layout.defaultContentViewFileName), encoding: .utf8)
        #expect(contentView.contains(#"Text("old")"#))
        #expect(contentView.contains(#"Text("later")"#))
        #expect(!(contentView.contains(#"Text("partial")"#)))
        #expect(try String(contentsOf: layout.pendingContentViewDraftURL, encoding: .utf8) == partialPatch)
    }

    @MainActor
    private func waitForFirstTool(
        in context: ModelContext,
        matching predicate: (StoredTool) -> Bool
    ) async throws -> StoredTool {
        let deadline = DispatchTime.now().uptimeNanoseconds + 15_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let tools = try context.fetch(FetchDescriptor<StoredTool>())
            if let tool = tools.first(where: predicate) {
                return tool
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let tools = try context.fetch(FetchDescriptor<StoredTool>())
        let matchingTool = tools.first(where: predicate)
        return try #require(matchingTool)
    }
}

private actor MetadataGenerationGate {
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    func waitForRelease() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}
