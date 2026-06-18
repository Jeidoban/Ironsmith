import AnyLanguageModel
import Foundation
import SwiftData
import Testing
@testable import Ironsmith

extension AgentPipelineTests {
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
        let generationClient = ToolGenerationClient.live(
            toolsDirectoryURL: toolsDirectory,
            processClient: Self.successfulProcessClient(),
            appBundleClient: .noOp(),
            iconClient: .noOp,
            metadataClient: ToolMetadataClient { _ in
                ToolMetadataSuggestion(displayName: "Paused Tool", iconPrompt: "")
            },
            promptRefinementClient: .disabled()
        )
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
        #expect(store.generationStatus == nil)
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
            repairStrategy: .deterministicOnly,
            toolsDirectoryURL: toolsDirectory,
            processClient: Self.successfulProcessClient(),
            appBundleClient: .noOp(),
            metadataClient: .fallback()
        )

        let result = try await runtime.generateTool(
            for: "ignored because pending prompt is stored",
            existingTool: tool,
            status: { _ in }
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
    func resumePartialEditDiffContinuesDraftAndAppliesCombinedDiff() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let executableName = "ResumeEdit"
        let tool = try Self.makeExistingTool(
            toolsDirectory: toolsDirectory,
            executableName: executableName,
            source: Self.originalEditableSource
        )
        let layout = ToolPackageLayout(packageRootURL: tool.packageRootURL, executableName: executableName)
        let contentViewURL = layout.sourceDirectoryURL.appendingPathComponent(layout.defaultContentViewFileName)
        let partialDiff = """
        --- ContentView.swift
        +++ ContentView.swift
        @@
         struct ContentView: View {
             var body: some View {
        -        Text("old")
        +        Text("
        """
        let continuation = """
        new")
             }
         }
        """
        try FileManager.default.createDirectory(at: layout.packageMetadataDirectoryURL, withIntermediateDirectories: true)
        try partialDiff.write(to: layout.pendingContentViewDraftURL, atomically: true, encoding: .utf8)
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
                return continuation
            },
            repairStrategy: .modelDiff(maxHunksPerTurn: 1),
            toolsDirectoryURL: toolsDirectory,
            processClient: Self.successfulProcessClient(),
            appBundleClient: .noOp(),
            metadataClient: .fallback()
        )

        let result = try await runtime.generateTool(
            for: "ignored because pending prompt is stored",
            existingTool: tool,
            status: { _ in }
        )

        let contentView = try String(contentsOf: Self.contentViewURL(for: result), encoding: .utf8)
        let previousSource = try String(
            contentsOf: layout.previousContentViewVersionURL,
            encoding: .utf8
        )
        #expect(contentView.contains(#"Text("new")"#))
        #expect(!(contentView.contains(#"Text("old")"#)))
        #expect(previousSource.contains(#"Text("old")"#))
        #expect(!(FileManager.default.fileExists(atPath: layout.pendingContentViewDraftURL.path)))
        let prompts = await promptCapture.prompts
        #expect(prompts.count == 1)
        #expect(prompts.first?.contains("Continue the exact unified diff response") == true)
        #expect(prompts.first?.contains(partialDiff) == true)
    }

    @MainActor
    private func waitForFirstTool(
        in context: ModelContext,
        matching predicate: (StoredTool) -> Bool
    ) async throws -> StoredTool {
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let tools = try context.fetch(FetchDescriptor<StoredTool>())
            if let tool = tools.first(where: predicate) {
                return tool
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return try #require(try context.fetch(FetchDescriptor<StoredTool>()).first)
    }
}
