import AnyLanguageModel
import Foundation
import ImageIO
import SwiftData
import Testing
@testable import Ironsmith

extension AgentPipelineTests {
    @MainActor
    @Test
    func toolLibraryStoreAllowsSingleFileEditingAndDoesNotCreateNewTool() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let existingTool = StoredTool(name: "Calculator", packageRootPath: "/tmp/calculator")
        context.insert(existingTool)
        try context.save()

        let capture = GenerationCapture()
        let generationClient = ToolGenerationClient { request in
            await capture.record(request)
            return ToolGenerationResult(
                toolName: "Calculator",
                executableName: "Calculator",
                settings: request.settings,
                packageRootURL: URL(fileURLWithPath: "/tmp/calculator", isDirectory: true)
            )
        }
        let runCapture = ToolRunCapture()
        let store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: generationClient,
                runnerClient: ToolRunnerClient { tool in
                    await runCapture.record(tool)
                }
            )
        )
        let inferenceStore = Self.inferenceStore()
        inferenceStore.generationPreferences.generatedAppLocationAccessEnabled = true
        inferenceStore.generationPreferences.generatedAppCalendarAccessEnabled = true

        store.selectForEditing(
            existingTool,
            defaultSettings: ToolLibraryStore.defaultGenerationSettings(from: inferenceStore.generationPreferences)
        )
        store.sandboxEnabled = false
        store.prompt = "Add down payment support"

        await store.submitPrompt(modelContext: context, inferenceStore: inferenceStore)

        let tools = try context.fetch(FetchDescriptor<StoredTool>())
        #expect(tools.count == 1)
        #expect(tools.first?.id == existingTool.id)
        #expect(tools.first?.pendingPrompt == nil)
        #expect(!(tools.first?.sandboxEnabled ?? false))
        #expect(await capture.existingToolID == existingTool.id)
        #expect(await capture.settings?.sandboxEnabled == false)
        #expect(await capture.settings?.sandboxPermissions.enabled == [.internet, .userSelectedFiles])
        #expect(await capture.settings?.resourcePermissions.enabled == [.location, .calendar])
        #expect(await capture.repairStrategy == .deterministicOnly)
        #expect(await runCapture.ranToolIDs.isEmpty)
        #expect(!(store.isSelected(existingTool)))
        #expect(store.promptPlaceholder == "Describe a new app to build…")
        #expect(store.sandboxEnabled == true)
    }

    @MainActor
    @Test
    func modelPatchEditAppliesSearchReplacePatchAndStoresPreviousVersion() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let tool = try Self.makeExistingTool(
            toolsDirectory: toolsDirectory,
            executableName: "Calculator",
            source: Self.originalEditableSource
        )
        let responses = LanguageModelResponseQueue([Self.renameOldToNewPatch])
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { _, _ in
                try await responses.next()
            },
            generationOptions: GenerationOptions(),
            pipelineConfiguration: .small(repairStrategy: .modelSearchReplace(maxPatchBlocksPerTurn: 1)),
            toolsDirectoryURL: toolsDirectory,
            processClient: Self.successfulProcessClient(),
            metadataClient: .fallback()
        )
        let result = try await runtime.generateTool(
            for: "Change old to new",
            existingTool: tool,
            settings: .default
        )

        let contentView = try String(contentsOf: Self.contentViewURL(for: result), encoding: .utf8)
        let previousSource = try String(
            contentsOf: ToolPackageLayout.previousContentViewVersionURL(for: result.packageRootURL),
            encoding: .utf8
        )
        #expect(contentView.contains(#"Text("new")"#))
        #expect(!(contentView.contains(#"Text("old")"#)))
        #expect(previousSource.contains(#"Text("old")"#))
        #expect(await responses.count == 1)
    }

    @MainActor
    @Test
    func modelPatchEditRetriesInvalidInitialPatchCandidate() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let tool = try Self.makeExistingTool(
            toolsDirectory: toolsDirectory,
            executableName: "RetryEdit",
            source: Self.originalEditableSource
        )
        let responses = LanguageModelResponseQueue([
            "not a patch",
            Self.renameOldToNewPatch
        ])
        let promptCapture = PromptCapture()
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { prompt, _ in
                await promptCapture.record(prompt)
                return try await responses.next()
            },
            generationOptions: GenerationOptions(),
            pipelineConfiguration: .small(repairStrategy: .modelSearchReplace(maxPatchBlocksPerTurn: 1)),
            toolsDirectoryURL: toolsDirectory,
            processClient: Self.successfulProcessClient(),
            metadataClient: .fallback()
        )

        let result = try await runtime.generateTool(
            for: "Change old to new",
            existingTool: tool,
            settings: .default
        )

        let contentView = try String(contentsOf: Self.contentViewURL(for: result), encoding: .utf8)
        #expect(contentView.contains(#"Text("new")"#))
        let prompts = await promptCapture.prompts
        #expect(prompts.count == 2)
        #expect(prompts.allSatisfy { $0.contains("Edit ContentView.swift by returning search/replace patch blocks only.") })
        #expect(!(prompts.contains { $0.contains("Rewrite ContentView.swift only.") }))
        #expect(await responses.count == 2)
    }

    @MainActor
    @Test
    func largeModelPatchEditRetriesOneUnappliablePatchCandidate() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let tool = try Self.makeExistingTool(
            toolsDirectory: toolsDirectory,
            executableName: "LargeRetryEdit",
            source: Self.originalEditableSource
        )
        let missingSearchPatch = """
        <<<<<<< SEARCH
                Text("missing")
        =======
                Text("new")
        >>>>>>> REPLACE
        """
        let responses = LanguageModelResponseQueue([
            missingSearchPatch,
            Self.renameOldToNewPatch
        ])
        let promptCapture = PromptCapture()
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { prompt, _ in
                await promptCapture.record(prompt)
                return try await responses.next()
            },
            generationOptions: GenerationOptions(),
            pipelineConfiguration: .large(repairStrategy: .modelSearchReplace(maxPatchBlocksPerTurn: ToolGenerationRepairPolicy.largeModelPatchBlocksPerTurn)),
            toolsDirectoryURL: toolsDirectory,
            processClient: Self.successfulProcessClient(),
            metadataClient: .fallback()
        )

        let result = try await runtime.generateTool(
            for: "Change old to new",
            existingTool: tool,
            settings: .default
        )

        let contentView = try String(contentsOf: Self.contentViewURL(for: result), encoding: .utf8)
        #expect(contentView.contains(#"Text("new")"#))
        let prompts = await promptCapture.prompts
        #expect(prompts.count == 2)
        #expect(prompts.allSatisfy { $0.contains("Edit ContentView.swift by returning search/replace patch blocks only.") })
        #expect(prompts[1].contains("Previous patch attempt failed:"))
        #expect(prompts[1].contains("Only patch the current authoritative source below."))
        #expect(await responses.count == 2)
    }

    @MainActor
    @Test
    func largeModelPatchEditAppliesValidBlocksFromPartiallyInvalidPatch() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let tool = try Self.makeExistingTool(
            toolsDirectory: toolsDirectory,
            executableName: "LargePartialEdit",
            source: Self.originalEditableSource
        )
        let partialPatch = """
        <<<<<<< SEARCH
                Text("old")
        =======
                Text("new")
        >>>>>>> REPLACE
        <<<<<<< SEARCH
                Text("missing")
        =======
                Text("unused")
        >>>>>>> REPLACE
        """
        let responses = LanguageModelResponseQueue([partialPatch])
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { _, _ in
                try await responses.next()
            },
            generationOptions: GenerationOptions(),
            pipelineConfiguration: .large(repairStrategy: .modelSearchReplace(maxPatchBlocksPerTurn: ToolGenerationRepairPolicy.largeModelPatchBlocksPerTurn)),
            toolsDirectoryURL: toolsDirectory,
            processClient: Self.successfulProcessClient(),
            metadataClient: .fallback()
        )

        let result = try await runtime.generateTool(
            for: "Change old to new",
            existingTool: tool,
            settings: .default
        )

        let contentView = try String(contentsOf: Self.contentViewURL(for: result), encoding: .utf8)
        #expect(contentView.contains(#"Text("new")"#))
        #expect(!(contentView.contains(#"Text("old")"#)))
        #expect(!(contentView.contains(#"Text("unused")"#)))
        #expect(await responses.count == 1)
    }

    @MainActor
    @Test
    func smallModelPatchEditFallsBackToWholeFileEditAfterRepeatedInvalidInitialPatches() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let tool = try Self.makeExistingTool(
            toolsDirectory: toolsDirectory,
            executableName: "FallbackEdit",
            source: Self.originalEditableSource
        )
        let wholeFileEditedSource = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                Text("whole file fallback")
            }
        }
        """
        let responses = LanguageModelResponseQueue([
            "",
            "not a patch",
            wholeFileEditedSource
        ])
        let promptCapture = PromptCapture()
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { prompt, _ in
                await promptCapture.record(prompt)
                return try await responses.next()
            },
            generationOptions: GenerationOptions(),
            pipelineConfiguration: .small(repairStrategy: .modelSearchReplace(maxPatchBlocksPerTurn: 1)),
            toolsDirectoryURL: toolsDirectory,
            processClient: Self.successfulProcessClient(),
            metadataClient: .fallback()
        )

        let result = try await runtime.generateTool(
            for: "Use full file fallback",
            existingTool: tool,
            settings: .default
        )

        let contentView = try String(contentsOf: Self.contentViewURL(for: result), encoding: .utf8)
        let prompts = await promptCapture.prompts
        #expect(contentView.contains(#"Text("whole file fallback")"#))
        #expect(prompts.count == 3)
        #expect(prompts[0].contains("Edit ContentView.swift by returning search/replace patch blocks only."))
        #expect(prompts[1].contains("Edit ContentView.swift by returning search/replace patch blocks only."))
        #expect(prompts[2].contains("Rewrite ContentView.swift only."))
        #expect(!(prompts[2].contains("Edit ContentView.swift by returning search/replace patch blocks only.")))
        #expect(await responses.count == 3)
    }

    @MainActor
    @Test
    func createModeDoesNotUseEditPatchFallback() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let promptCapture = PromptCapture()
        let responses = LanguageModelResponseQueue([
            Self.simpleContentViewSource(text: "created normally")
        ])
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { prompt, _ in
                await promptCapture.record(prompt)
                return try await responses.next()
            },
            generationOptions: GenerationOptions(),
            pipelineConfiguration: .small(repairStrategy: .modelSearchReplace(maxPatchBlocksPerTurn: 1)),
            toolsDirectoryURL: toolsDirectory,
            processClient: Self.successfulProcessClient(),
            metadataClient: .fallback()
        )

        let result = try await runtime.generateTool(
            for: "Build a create mode tool",
            settings: .default
        )

        let contentView = try String(contentsOf: Self.contentViewURL(for: result), encoding: .utf8)
        let prompts = await promptCapture.prompts
        #expect(contentView.contains(#"Text("created normally")"#))
        #expect(prompts.count == 1)
        #expect(prompts[0].contains("Generate ContentView.swift only."))
        #expect(!(prompts[0].contains("Edit ContentView.swift by returning search/replace patch blocks only.")))
        #expect(!(prompts[0].contains("Rewrite ContentView.swift only.")))
        #expect(await responses.count == 1)
    }

    @MainActor
    @Test
    func modelPatchEditUsesProfilePatchBlockCaps() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let localTool = try Self.makeExistingTool(
            toolsDirectory: toolsDirectory,
            executableName: "LocalEditCap",
            source: Self.originalEditableSource
        )
        let remoteTool = try Self.makeExistingTool(
            toolsDirectory: toolsDirectory,
            executableName: "RemoteEditCap",
            source: Self.originalEditableSource
        )
        let promptCapture = PromptCapture()
        let responses = LanguageModelResponseQueue([
            Self.renameOldToNewPatch,
            Self.renameOldToNewPatch
        ])
        let model = StubAgentLanguageModel { prompt, _ in
            await promptCapture.record(prompt)
            return try await responses.next()
        }
        let localRuntime = Self.makeRuntime(
            languageModel: model,
            generationOptions: GenerationOptions(),
            pipelineConfiguration: .small(repairStrategy: .modelSearchReplace(maxPatchBlocksPerTurn: 1)),
            toolsDirectoryURL: toolsDirectory,
            processClient: Self.successfulProcessClient(),
            metadataClient: .fallback()
        )
        let remoteRuntime = Self.makeRuntime(
            languageModel: model,
            generationOptions: GenerationOptions(),
            pipelineConfiguration: .large(repairStrategy: .modelSearchReplace(maxPatchBlocksPerTurn: ToolGenerationRepairPolicy.largeModelPatchBlocksPerTurn)),
            toolsDirectoryURL: toolsDirectory,
            processClient: Self.successfulProcessClient(),
            metadataClient: .fallback()
        )

        _ = try await localRuntime.generateTool(
            for: "Change old to new",
            existingTool: localTool,
            settings: .default
        )
        _ = try await remoteRuntime.generateTool(
            for: "Change old to new",
            existingTool: remoteTool,
            settings: .default
        )

        let prompts = await promptCapture.prompts
        #expect(prompts.count == 2)
        #expect(prompts[0].contains("Return at most 1 search/replace patch block(s)."))
        #expect(prompts[1].contains("Return at most \(ToolGenerationRepairPolicy.largeModelPatchBlocksPerTurn) search/replace patch block(s)."))
        #expect(await responses.count == 2)
    }

    @MainActor
    @Test
    func deterministicOnlyEditRestoresOriginalAfterExhaustingCandidates() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let executableName = "RestoreOriginalEdit"
        let tool = try Self.makeExistingTool(
            toolsDirectory: toolsDirectory,
            executableName: executableName,
            source: Self.originalEditableSource
        )
        let builds = UnsupportedModifierBuilds(executableName: executableName)
        let brokenSource = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                Text("broken").definitelyNotReal()
            }
        }
        """
        let responses = LanguageModelResponseQueue(
            Array(repeating: brokenSource, count: ToolGenerationRepairPolicy.maximumGenerationAttempts)
        )
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { _, _ in
                try await responses.next()
            },
            generationOptions: GenerationOptions(),
            pipelineConfiguration: .small(repairStrategy: .deterministicOnly),
            toolsDirectoryURL: toolsDirectory,
            processClient: SwiftPackageProcessClient(
                build: { packageRoot in
                    await builds.next(packageRoot: packageRoot)
                },
                showBinPath: { packageRoot in
                    packageRoot.appendingPathComponent(".build/debug", isDirectory: true)
                },
                launch: { _ in },
                stripQuarantine: { _ in }
            ),
            metadataClient: .fallback()
        )

        do {
            _ = try await runtime.generateTool(
                for: "Make it broken",
                existingTool: tool,
                settings: .default
            )
            Issue.record("Expected deterministic-only edit to fail after exhausting candidates.")
        } catch let error as ToolGenerationError {
            #expect(error.localizedDescription.contains("ContentView.swift still has 1 compiler errors"))
        }

        let contentView = try String(
            contentsOf: tool.packageRootURL.appendingPathComponent("Sources/\(executableName)/ContentView.swift"),
            encoding: .utf8
        )
        let previousURL = ToolPackageLayout.previousContentViewVersionURL(for: tool.packageRootURL)
        #expect(contentView == Self.originalEditableSource)
        #expect(!(FileManager.default.fileExists(atPath: previousURL.path)))
        #expect(await responses.count == ToolGenerationRepairPolicy.maximumGenerationAttempts)
        #expect(await builds.count == ToolGenerationRepairPolicy.maximumGenerationAttempts)
    }
}
