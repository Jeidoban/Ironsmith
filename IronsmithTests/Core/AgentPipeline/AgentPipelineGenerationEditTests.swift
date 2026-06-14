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
        let generationClient = ToolGenerationClient {
            prompt,
            existingTool,
            sandboxEnabled,
            sandboxPermissions,
            resourcePermissions,
            context,
            status in
            await capture.record(
                prompt: prompt,
                existingToolID: existingTool?.id,
                sandboxEnabled: sandboxEnabled,
                sandboxPermissions: sandboxPermissions,
                resourcePermissions: resourcePermissions,
                repairStrategy: context.repairStrategy
            )
            status("Fake edit")
            return ToolGenerationResult(
                toolName: "Calculator",
                executableName: "Calculator",
                sandboxEnabled: sandboxEnabled,
                packageRootURL: URL(fileURLWithPath: "/tmp/calculator", isDirectory: true),
                manifest: ToolManifest(
                    displayName: "Calculator",
                    executableName: "Calculator",
                    files: [
                        ToolManifestFile(
                            path: "Sources/Calculator/ContentView.swift",
                            description: "Primary SwiftUI screen and supporting app logic."
                        )
                    ]
                )
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

        store.selectForEditing(existingTool)
        store.sandboxEnabled = false
        store.prompt = "Add down payment support"

        await store.submitPrompt(modelContext: context, inferenceStore: inferenceStore)

        let tools = try context.fetch(FetchDescriptor<StoredTool>())
        #expect(tools.count == 1)
        #expect(tools.first?.id == existingTool.id)
        #expect(tools.first?.lastPromptSummary == "Add down payment support")
        #expect(!(tools.first?.sandboxEnabled ?? false))
        #expect(await capture.existingToolID == existingTool.id)
        #expect(!((await capture.sandboxEnabled) ?? false))
        #expect(await capture.sandboxPermissions?.enabled == [.internet, .userSelectedFiles])
        #expect(await capture.resourcePermissions?.enabled == [.location, .calendar])
        #expect(await capture.repairStrategy == .deterministicOnly)
        #expect(await runCapture.ranToolIDs.isEmpty)
        #expect(!(store.isSelected(existingTool)))
        #expect(store.promptPlaceholder == "Describe a new app to build…")
        #expect(store.sandboxEnabled == true)
    }

    @MainActor
    @Test
    func modelDiffEditAppliesUnifiedDiffAndStoresPreviousVersion() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let tool = try Self.makeExistingTool(
            toolsDirectory: toolsDirectory,
            executableName: "Calculator",
            source: Self.originalEditableSource
        )
        let responses = LanguageModelResponseQueue([Self.renameOldToNewDiff])
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { _, _ in
                try await responses.next()
            },
            generationOptions: GenerationOptions(),
            repairStrategy: .modelDiff(maxHunksPerTurn: 1),
            toolsDirectoryURL: toolsDirectory,
            processClient: Self.successfulProcessClient(),
            metadataClient: .fallback()
        )
        var statuses: [String] = []

        let result = try await runtime.generateTool(
            for: "Change old to new",
            existingTool: tool,
            status: { statuses.append($0) }
        )

        let contentView = try String(contentsOf: Self.contentViewURL(for: result), encoding: .utf8)
        let previousSource = try String(
            contentsOf: ToolPackageLayout.previousContentViewVersionURL(for: result.packageRootURL),
            encoding: .utf8
        )
        #expect(contentView.contains(#"Text("new")"#))
        #expect(!(contentView.contains(#"Text("old")"#)))
        #expect(previousSource.contains(#"Text("old")"#))
        #expect(statuses.contains("Editing Calculator"))
        #expect(!(statuses.contains { $0.hasPrefix("Generating Calculator") }))
        #expect(await responses.count == 1)
    }

    @MainActor
    @Test
    func modelDiffEditRetriesInvalidInitialDiffCandidate() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let tool = try Self.makeExistingTool(
            toolsDirectory: toolsDirectory,
            executableName: "RetryEdit",
            source: Self.originalEditableSource
        )
        let responses = LanguageModelResponseQueue([
            "not a diff",
            Self.renameOldToNewDiff
        ])
        let promptCapture = PromptCapture()
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { prompt, _ in
                await promptCapture.record(prompt)
                return try await responses.next()
            },
            generationOptions: GenerationOptions(),
            repairStrategy: .modelDiff(maxHunksPerTurn: 1),
            toolsDirectoryURL: toolsDirectory,
            processClient: Self.successfulProcessClient(),
            metadataClient: .fallback()
        )

        let result = try await runtime.generateTool(
            for: "Change old to new",
            existingTool: tool,
            status: { _ in }
        )

        let contentView = try String(contentsOf: Self.contentViewURL(for: result), encoding: .utf8)
        #expect(contentView.contains(#"Text("new")"#))
        let prompts = await promptCapture.prompts
        #expect(prompts.count == 2)
        #expect(prompts.allSatisfy { $0.contains("Edit ContentView.swift by returning a unified diff only.") })
        #expect(!(prompts.contains { $0.contains("Rewrite ContentView.swift only.") }))
        #expect(await responses.count == 2)
    }

    @MainActor
    @Test
    func modelDiffEditFallsBackToWholeFileEditAfterRepeatedInvalidInitialDiffs() async throws {
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
            "not a diff",
            wholeFileEditedSource
        ])
        let promptCapture = PromptCapture()
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { prompt, _ in
                await promptCapture.record(prompt)
                return try await responses.next()
            },
            generationOptions: GenerationOptions(),
            repairStrategy: .modelDiff(maxHunksPerTurn: 1),
            toolsDirectoryURL: toolsDirectory,
            processClient: Self.successfulProcessClient(),
            metadataClient: .fallback()
        )

        let result = try await runtime.generateTool(
            for: "Use full file fallback",
            existingTool: tool,
            status: { _ in }
        )

        let contentView = try String(contentsOf: Self.contentViewURL(for: result), encoding: .utf8)
        let prompts = await promptCapture.prompts
        #expect(contentView.contains(#"Text("whole file fallback")"#))
        #expect(prompts.count == 3)
        #expect(prompts[0].contains("Edit ContentView.swift by returning a unified diff only."))
        #expect(prompts[1].contains("Edit ContentView.swift by returning a unified diff only."))
        #expect(prompts[2].contains("Rewrite ContentView.swift only."))
        #expect(!(prompts[2].contains("Edit ContentView.swift by returning a unified diff only.")))
        #expect(await responses.count == 3)
    }

    @MainActor
    @Test
    func createModeDoesNotUseEditDiffFallback() async throws {
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
            repairStrategy: .modelDiff(maxHunksPerTurn: 1),
            toolsDirectoryURL: toolsDirectory,
            processClient: Self.successfulProcessClient(),
            metadataClient: .fallback()
        )

        let result = try await runtime.generateTool(
            for: "Build a create mode tool",
            status: { _ in }
        )

        let contentView = try String(contentsOf: Self.contentViewURL(for: result), encoding: .utf8)
        let prompts = await promptCapture.prompts
        #expect(contentView.contains(#"Text("created normally")"#))
        #expect(prompts.count == 1)
        #expect(prompts[0].contains("Generate ContentView.swift only."))
        #expect(!(prompts[0].contains("Edit ContentView.swift by returning a unified diff only.")))
        #expect(!(prompts[0].contains("Rewrite ContentView.swift only.")))
        #expect(await responses.count == 1)
    }

    @MainActor
    @Test
    func modelDiffEditUsesUnboundedRemoteInitialEditPolicy() async throws {
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
            Self.renameOldToNewDiff,
            Self.renameOldToNewDiff
        ])
        let model = StubAgentLanguageModel { prompt, _ in
            await promptCapture.record(prompt)
            return try await responses.next()
        }
        let localRuntime = Self.makeRuntime(
            languageModel: model,
            generationOptions: GenerationOptions(),
            repairStrategy: .modelDiff(maxHunksPerTurn: 1),
            toolsDirectoryURL: toolsDirectory,
            processClient: Self.successfulProcessClient(),
            metadataClient: .fallback()
        )
        let remoteRuntime = Self.makeRuntime(
            languageModel: model,
            generationOptions: GenerationOptions(),
            repairStrategy: .modelDiff(maxHunksPerTurn: nil),
            toolsDirectoryURL: toolsDirectory,
            processClient: Self.successfulProcessClient(),
            metadataClient: .fallback()
        )

        _ = try await localRuntime.generateTool(
            for: "Change old to new",
            existingTool: localTool,
            status: { _ in }
        )
        _ = try await remoteRuntime.generateTool(
            for: "Change old to new",
            existingTool: remoteTool,
            status: { _ in }
        )

        let prompts = await promptCapture.prompts
        #expect(prompts.count == 2)
        #expect(prompts[0].contains("Return at most 3 unified diff hunk(s)."))
        #expect(prompts[1].contains("Use as many unified diff hunks as needed."))
        #expect(!(prompts[1].contains("Return at most")))
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
            repairStrategy: .deterministicOnly,
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
                status: { _ in }
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
