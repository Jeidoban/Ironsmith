import AnyLanguageModel
import Foundation
import Testing
@testable import Ironsmith

extension AgentPipelineTests {
    @MainActor
    @Test
    func disabledDiagnosticWholeFileRewriteUsesScratchGeneration() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let executableName = "DisabledRewriteTool"
        let brokenSource = Self.sourceWithMissingMembers(["missing1"])
        let scratchSource = Self.simpleContentViewSource(text: "Scratch with rewrite disabled")
        let responses = LanguageModelResponseQueue([
            brokenSource,
            "not a diff",
            "still not a diff",
            scratchSource,
        ])
        let prompts = PromptCapture()
        let builds = DistinctUnsupportedModifierBuilds(executableName: executableName)
        let formats = FormatCapture()
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { prompt, _ in
                await prompts.record(prompt)
                return try await responses.next()
            },
            pipelineConfiguration: .ironsmithSpark(
                repairStrategy: .modelSearchReplace(maxPatchBlocksPerTurn: 1),
                diagnosticWholeFileRewriteEnabled: false
            ),
            toolsDirectoryURL: toolsDirectory,
            processClient: Self.diagnosticRewriteProcessClient(builds: builds, formats: formats),
            metadataClient: ToolMetadataClient { _ in
                ToolMetadataSuggestion(displayName: "Disabled Rewrite Tool", iconPrompt: "")
            }
        )

        let result = try await runtime.generateTool(
            for: "Build a disabled rewrite tool",
            settings: .default
        )

        let source = try String(contentsOf: Self.contentViewURL(for: result), encoding: .utf8)
        let capturedPrompts = await prompts.prompts
        #expect(source.contains("Scratch with rewrite disabled"))
        #expect(!capturedPrompts.contains {
            $0.contains("Narrow compiler repair stalled on this app.")
        })
        #expect(await responses.count == 4)
        #expect(await builds.count == 2)
        #expect(await formats.formattedURLs.count == 2)
    }

    @MainActor
    @Test
    func sparkDiagnosticRewriteReceivesCompleteActionableErrorSet() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let executableName = "DiagnosticRewriteTool"
        let brokenSource = Self.sourceWithMissingMembers(["missing1", "missing2"])
        let fixedSource = Self.simpleContentViewSource(text: "Fixed by diagnostic rewrite")
        let responses = LanguageModelResponseQueue([
            brokenSource,
            "not a diff",
            "still not a diff",
            fixedSource,
        ])
        let prompts = PromptCapture()
        let builds = DistinctUnsupportedModifierBuilds(executableName: executableName)
        let formats = FormatCapture()
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { prompt, _ in
                await prompts.record(prompt)
                return try await responses.next()
            },
            pipelineConfiguration: .ironsmithSpark(
                repairStrategy: .modelSearchReplace(maxPatchBlocksPerTurn: 1),
                diagnosticWholeFileRewriteEnabled: true
            ),
            toolsDirectoryURL: toolsDirectory,
            processClient: Self.diagnosticRewriteProcessClient(builds: builds, formats: formats),
            metadataClient: ToolMetadataClient { _ in
                ToolMetadataSuggestion(displayName: "Diagnostic Rewrite Tool", iconPrompt: "")
            }
        )

        let result = try await runtime.generateTool(
            for: "Build a diagnostic rewrite tool",
            settings: .default
        )

        let source = try String(contentsOf: Self.contentViewURL(for: result), encoding: .utf8)
        let capturedPrompts = await prompts.prompts
        let rewritePrompts = capturedPrompts.filter {
            $0.contains("Narrow compiler repair stalled on this app.")
        }
        let rewritePrompt = try #require(rewritePrompts.first)
        #expect(source.contains("Fixed by diagnostic rewrite"))
        #expect(rewritePrompts.count == 1)
        #expect(rewritePrompt.contains("Original create request: Build a diagnostic rewrite tool"))
        #expect(rewritePrompt.contains(brokenSource))
        #expect(rewritePrompt.contains("no member 'missing1'"))
        #expect(rewritePrompt.contains("no member 'missing2'"))
        #expect(await responses.count == 4)
        #expect(await builds.count == 2)
        #expect(await formats.formattedURLs.count == 2)
    }

    @MainActor
    @Test
    func sparkDiagnosticRewriteReceivesLatestRepairedCandidate() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let executableName = "ProgressiveDiagnosticRewriteTool"
        let brokenSource = Self.sourceWithMissingMembers(["missing1", "missing2"])
        let partiallyRepairedSourceLine = "            Text(\"Fixed first error\")"
        let firstRepair = """
        @@
        -            Text("Broken 1").missing1()
        +\(partiallyRepairedSourceLine)
        """
        let fixedSource = Self.simpleContentViewSource(text: "Fixed from latest candidate")
        let responses = LanguageModelResponseQueue([
            brokenSource,
            firstRepair,
            "not a patch",
            "still not a patch",
            fixedSource,
        ])
        let prompts = PromptCapture()
        let builds = DistinctUnsupportedModifierBuilds(executableName: executableName)
        let formats = FormatCapture()
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { prompt, _ in
                await prompts.record(prompt)
                return try await responses.next()
            },
            pipelineConfiguration: .ironsmithSpark(
                repairStrategy: .modelSearchReplace(maxPatchBlocksPerTurn: 1),
                diagnosticWholeFileRewriteEnabled: true
            ),
            toolsDirectoryURL: toolsDirectory,
            processClient: Self.diagnosticRewriteProcessClient(builds: builds, formats: formats),
            metadataClient: ToolMetadataClient { _ in
                ToolMetadataSuggestion(
                    displayName: "Progressive Diagnostic Rewrite Tool",
                    iconPrompt: ""
                )
            }
        )

        let result = try await runtime.generateTool(
            for: "Build a progressive diagnostic rewrite tool",
            settings: .default
        )

        let source = try String(contentsOf: Self.contentViewURL(for: result), encoding: .utf8)
        let rewritePrompt = try #require(await prompts.prompts.first {
            $0.contains("Narrow compiler repair stalled on this app.")
        })
        #expect(source.contains("Fixed from latest candidate"))
        #expect(rewritePrompt.contains(partiallyRepairedSourceLine))
        #expect(rewritePrompt.contains("no member 'missing2'"))
        #expect(!rewritePrompt.contains("no member 'missing1'"))
        #expect(await responses.count == 5)
        #expect(await builds.count == 3)
        #expect(await formats.formattedURLs.count == 2)
    }

    @MainActor
    @Test
    func sparkRepairStallRunsDeterministicRecoveryBeforeScratchRegeneration() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let executableName = "DeterministicStallRecoveryTool"
        let responses = LanguageModelResponseQueue([
            """
            import SwiftUI

            struct ContentView: View {
                @State private var tokens = ["one", "two"]
                @State private var newIdx = 0

                var body: some View {
                    Text(tokens[newIdx]).definitelyNotReal()
                }
            }
            """,
            """
            --- a/ContentView.swift
            +++ b/ContentView.swift
            @@ -8,1 +8,3 @@
            -        Text(tokens[newIdx]).definitelyNotReal()
            +        if newIdx< tokens.count {
            +            Text(tokens[newIdx])
            +        }
            """,
            "not a patch",
            "still not a patch",
            Self.simpleContentViewSource(text: "Scratch regeneration should not run"),
        ])
        let prompts = PromptCapture()
        let builds = ModelConversationBuilds(executableName: executableName)
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { prompt, _ in
                await prompts.record(prompt)
                return try await responses.next()
            },
            pipelineConfiguration: .ironsmithSpark(
                repairStrategy: .modelSearchReplace(maxPatchBlocksPerTurn: 1),
                diagnosticWholeFileRewriteEnabled: false
            ),
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
            metadataClient: ToolMetadataClient { _ in
                ToolMetadataSuggestion(
                    displayName: "Deterministic Stall Recovery Tool",
                    iconPrompt: ""
                )
            }
        )

        let result = try await runtime.generateTool(
            for: "Build a deterministic stall recovery tool",
            settings: .default
        )

        let source = try String(contentsOf: Self.contentViewURL(for: result), encoding: .utf8)
        let capturedPrompts = await prompts.prompts
        #expect(source.contains("if newIdx < tokens.count"))
        #expect(!capturedPrompts.contains {
            $0.contains("Narrow compiler repair stalled on this app.")
        })
        #expect(await responses.count == 4)
        #expect(await builds.count == 3)
    }

    @MainActor
    @Test
    func regressedDiagnosticRewriteGetsFreshDiffRepairConversation() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let executableName = "RegressedRewriteTool"
        let initialSource = Self.sourceWithMissingMembers(["missing1"])
        let regressedSource = Self.sourceWithMissingMembers(["missing1", "missing2"])
        let repairedDiff = """
        --- a/ContentView.swift
        +++ b/ContentView.swift
        @@ -4,6 +4,3 @@
             var body: some View {
        -        VStack {
        -            Text("Broken 1").missing1()
        -            Text("Broken 2").missing2()
        -        }
        +        Text("Fixed after rewrite repair")
             }
         }
        """
        let responses = LanguageModelResponseQueue([
            initialSource,
            "not a diff",
            "still not a diff",
            regressedSource,
            repairedDiff,
        ])
        let prompts = PromptCapture()
        let builds = DistinctUnsupportedModifierBuilds(executableName: executableName)
        let formats = FormatCapture()
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { prompt, _ in
                await prompts.record(prompt)
                return try await responses.next()
            },
            pipelineConfiguration: .ironsmithSpark(
                repairStrategy: .modelSearchReplace(maxPatchBlocksPerTurn: 1),
                diagnosticWholeFileRewriteEnabled: true
            ),
            toolsDirectoryURL: toolsDirectory,
            processClient: Self.diagnosticRewriteProcessClient(builds: builds, formats: formats),
            metadataClient: ToolMetadataClient { _ in
                ToolMetadataSuggestion(displayName: "Regressed Rewrite Tool", iconPrompt: "")
            }
        )

        let result = try await runtime.generateTool(
            for: "Build a regressed rewrite tool",
            settings: .default
        )

        let source = try String(contentsOf: Self.contentViewURL(for: result), encoding: .utf8)
        let capturedPrompts = await prompts.prompts
        let postRewriteRepairPrompt = try #require(capturedPrompts.last)
        #expect(source.contains("Fixed after rewrite repair"))
        #expect(postRewriteRepairPrompt.contains("Build failed for ContentView.swift."))
        #expect(postRewriteRepairPrompt.contains("Current authoritative ContentView.swift:"))
        #expect(postRewriteRepairPrompt.contains(regressedSource))
        #expect(await responses.count == 5)
        #expect(await builds.count == 3)
        #expect(await formats.formattedURLs.count == 2)
    }

    @MainActor
    @Test
    func secondRepairStallSkipsAnotherRewriteAndUsesScratchGeneration() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let executableName = "OneShotRewriteTool"
        let initialSource = Self.sourceWithMissingMembers(["missing1"])
        let rewrittenSource = Self.sourceWithMissingMembers(["missing2"])
        let scratchSource = Self.simpleContentViewSource(text: "Scratch regeneration")
        let responses = LanguageModelResponseQueue([
            initialSource,
            "not a diff",
            "still not a diff",
            rewrittenSource,
            "not a diff after rewrite",
            "still not a diff after rewrite",
            scratchSource,
        ])
        let prompts = PromptCapture()
        let builds = DistinctUnsupportedModifierBuilds(executableName: executableName)
        let formats = FormatCapture()
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { prompt, _ in
                await prompts.record(prompt)
                return try await responses.next()
            },
            pipelineConfiguration: .ironsmithSpark(
                repairStrategy: .modelSearchReplace(maxPatchBlocksPerTurn: 1),
                diagnosticWholeFileRewriteEnabled: true
            ),
            toolsDirectoryURL: toolsDirectory,
            processClient: Self.diagnosticRewriteProcessClient(builds: builds, formats: formats),
            metadataClient: ToolMetadataClient { _ in
                ToolMetadataSuggestion(displayName: "One Shot Rewrite Tool", iconPrompt: "")
            }
        )

        let result = try await runtime.generateTool(
            for: "Build a one-shot rewrite tool",
            settings: .default
        )

        let source = try String(contentsOf: Self.contentViewURL(for: result), encoding: .utf8)
        let capturedPrompts = await prompts.prompts
        #expect(source.contains("Scratch regeneration"))
        #expect(capturedPrompts.filter {
            $0.contains("Narrow compiler repair stalled on this app.")
        }.count == 1)
        #expect(await responses.count == 7)
        #expect(await builds.count == 3)
        #expect(await formats.formattedURLs.count == 3)
    }

    @MainActor
    @Test
    func repeatedRepairContextWindowFailureBypassesDiagnosticRewrite() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let executableName = "ContextWindowRewriteTool"
        let brokenSource = Self.sourceWithMissingMembers(["missing1"])
        let scratchSource = Self.simpleContentViewSource(text: "Scratch after context window")
        let responses = ContextWindowRepairResponses(
            brokenSource: brokenSource,
            scratchSource: scratchSource
        )
        let prompts = PromptCapture()
        let builds = DistinctUnsupportedModifierBuilds(executableName: executableName)
        let formats = FormatCapture()
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { prompt, _ in
                await prompts.record(prompt)
                return try await responses.next(prompt)
            },
            pipelineConfiguration: .ironsmithSpark(
                repairStrategy: .modelSearchReplace(maxPatchBlocksPerTurn: 1),
                diagnosticWholeFileRewriteEnabled: true
            ),
            toolsDirectoryURL: toolsDirectory,
            processClient: Self.diagnosticRewriteProcessClient(builds: builds, formats: formats),
            metadataClient: ToolMetadataClient { _ in
                ToolMetadataSuggestion(displayName: "Context Window Rewrite Tool", iconPrompt: "")
            }
        )

        let result = try await runtime.generateTool(
            for: "Build a context-window rewrite tool",
            settings: .default
        )

        let source = try String(contentsOf: Self.contentViewURL(for: result), encoding: .utf8)
        let capturedPrompts = await prompts.prompts
        #expect(source.contains("Scratch after context window"))
        #expect(!capturedPrompts.contains {
            $0.contains("Narrow compiler repair stalled on this app.")
        })
        #expect(await responses.generationCount == 2)
        #expect(await responses.repairCount == 2)
        #expect(await builds.count == 2)
        #expect(await formats.formattedURLs.count == 2)
    }

    @MainActor
    @Test
    func excessiveInitialErrorCountBypassesDiagnosticRewrite() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let executableName = "HighErrorRewriteTool"
        let brokenSource = Self.sourceWithMissingMembers(
            (1...(ToolGenerationRepairPolicy.regenerationThreshold + 1)).map { "missing\($0)" }
        )
        let scratchSource = Self.simpleContentViewSource(text: "Scratch after high error count")
        let responses = LanguageModelResponseQueue([brokenSource, scratchSource])
        let prompts = PromptCapture()
        let builds = DistinctUnsupportedModifierBuilds(executableName: executableName)
        let formats = FormatCapture()
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { prompt, _ in
                await prompts.record(prompt)
                return try await responses.next()
            },
            pipelineConfiguration: .ironsmithSpark(
                repairStrategy: .modelSearchReplace(maxPatchBlocksPerTurn: 1),
                diagnosticWholeFileRewriteEnabled: true
            ),
            toolsDirectoryURL: toolsDirectory,
            processClient: Self.diagnosticRewriteProcessClient(builds: builds, formats: formats),
            metadataClient: ToolMetadataClient { _ in
                ToolMetadataSuggestion(displayName: "High Error Rewrite Tool", iconPrompt: "")
            }
        )

        let result = try await runtime.generateTool(
            for: "Build a high-error rewrite tool",
            settings: .default
        )

        let source = try String(contentsOf: Self.contentViewURL(for: result), encoding: .utf8)
        let capturedPrompts = await prompts.prompts
        #expect(source.contains("Scratch after high error count"))
        #expect(!capturedPrompts.contains { $0.contains("Build failed for ContentView.swift.") })
        #expect(!capturedPrompts.contains {
            $0.contains("Narrow compiler repair stalled on this app.")
        })
        #expect(await responses.count == 2)
        #expect(await builds.count == 2)
        #expect(await formats.formattedURLs.count == 2)
    }

    @MainActor
    @Test
    func modelRepairRegenerationReasonsClassifyWholeFileRewriteEligibility() {
        let eligible: [ContentViewBuildRepairLoop.ModelRepairRegenerationReason] = [
            .repeatedSkippedRepair(.invalidRepairPatch),
            .repeatedSkippedRepair(.noDeterministicRepair),
            .repeatedNoProgressPatches,
            .repeatedRolledBackPatches,
            .budgetExhausted(6),
        ]
        #expect(eligible.allSatisfy { $0.allowsDiagnosticWholeFileRewrite })
        #expect(!ContentViewBuildRepairLoop.ModelRepairRegenerationReason
            .contextWindowExceeded
            .allowsDiagnosticWholeFileRewrite)
    }

    private static func sourceWithMissingMembers(_ members: [String]) -> String {
        let rows = members.enumerated().map { index, member in
            "            Text(\"Broken \(index + 1)\").\(member)()"
        }.joined(separator: "\n")
        return """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                VStack {
        \(rows)
                }
            }
        }
        """
    }

    private static func diagnosticRewriteProcessClient(
        builds: DistinctUnsupportedModifierBuilds,
        formats: FormatCapture
    ) -> SwiftPackageProcessClient {
        SwiftPackageProcessClient(
            build: { packageRoot in
                await builds.next(packageRoot: packageRoot)
            },
            showBinPath: { packageRoot in
                packageRoot.appendingPathComponent(".build/debug", isDirectory: true)
            },
            launch: { _ in },
            stripQuarantine: { _ in },
            formatSwiftSource: { url in
                await formats.record(url)
                return SwiftPackageBuildResult(
                    succeeded: true,
                    stdout: "",
                    stderr: "",
                    terminationStatus: 0
                )
            }
        )
    }
}

private actor ContextWindowRepairResponses {
    let brokenSource: String
    let scratchSource: String
    private(set) var generationCount = 0
    private(set) var repairCount = 0

    init(brokenSource: String, scratchSource: String) {
        self.brokenSource = brokenSource
        self.scratchSource = scratchSource
    }

    func next(_ prompt: Prompt) throws -> String {
        if prompt.description.contains("Build failed for ContentView.swift.") {
            repairCount += 1
            throw FakeAgentError.contextWindow
        }
        generationCount += 1
        return generationCount == 1 ? brokenSource : scratchSource
    }
}
