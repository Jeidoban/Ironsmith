import AnyLanguageModel
import Foundation
import ImageIO
import SwiftData
import Testing
@testable import Ironsmith

extension AgentPipelineTests {
    @MainActor
    @Test
    func deterministicOnlyRepairStrategyRegeneratesInsteadOfCallingModelRepair() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let builds = BuildFailureThenSuccess(executableName: "BuildABrokenModifierTool")
        let processClient = SwiftPackageProcessClient(
            build: { packageRoot in
                await builds.next(packageRoot: packageRoot)
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
            import SwiftUI

            struct ContentView: View {
                var body: some View {
                    Text("broken").definitelyNotReal()
                }
            }
            """,
            """
            import SwiftUI

            struct ContentView: View {
                var body: some View {
                    Text("regenerated instead of model repair")
                }
            }
            """
        ])
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { _, _ in
                try await responses.next()
            },
            generationOptions: GenerationOptions(),
            repairStrategy: .deterministicOnly,
            toolsDirectoryURL: toolsDirectory,
            processClient: processClient,
            metadataClient: .fallback()
        )

        let result = try await runtime.generateTool(
            for: "Build a broken modifier tool",
            settings: .default
        )

        let contentView = try String(
            contentsOf: result.packageRootURL.appendingPathComponent("Sources/\(result.executableName)/ContentView.swift"),
            encoding: .utf8
        )
        #expect(contentView.contains(#"Text("regenerated instead of model repair")"#))
        #expect(await responses.count == 2)
        #expect(await builds.count == 2)
    }

    @MainActor
    @Test
    func regenerationThresholdScalesWithContentViewLineCount() {
        #expect(ToolGenerationRepairPolicy.regenerationThreshold(forSourceLineCount: 40) == 12)
        #expect(ToolGenerationRepairPolicy.regenerationThreshold(forSourceLineCount: 240) == 12)
        #expect(ToolGenerationRepairPolicy.regenerationThreshold(forSourceLineCount: 320) == 16)
        #expect(ToolGenerationRepairPolicy.regenerationThreshold(forSourceLineCount: 960) == 48)
        #expect(ToolGenerationRepairPolicy.regenerationThreshold(forSourceLineCount: 2_000) == 48)
    }

    @MainActor
    @Test
    func deterministicPreflightRunsBeforeRegenerationThreshold() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let executableName = "BuildASpacingTool"
        let builds = DeterministicSpacingBuilds(
            executableName: executableName,
            repeatedDiagnosticCount: ToolGenerationRepairPolicy.regenerationThreshold + 1
        )
        let processClient = SwiftPackageProcessClient(
            build: { packageRoot in
                await builds.next(packageRoot: packageRoot)
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
            import SwiftUI

            struct ContentView: View {
                @State private var tokens = ["one", "two"]
                @State private var newIdx = 0

                var body: some View {
                    Text(tokens[newIdx])
                        .onAppear {
                            if newIdx< tokens.count {
                                newIdx += 1
                            }
                        }
                }
            }
            """
        ])
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { _, _ in
                try await responses.next()
            },
            generationOptions: GenerationOptions(),
            repairStrategy: .modelDiff(maxHunksPerTurn: 1),
            toolsDirectoryURL: toolsDirectory,
            processClient: processClient,
            metadataClient: .fallback()
        )

        let result = try await runtime.generateTool(
            for: "Build a spacing tool",
            settings: .default
        )

        let contentView = try String(
            contentsOf: result.packageRootURL.appendingPathComponent("Sources/\(result.executableName)/ContentView.swift"),
            encoding: .utf8
        )
        #expect(contentView.contains("if newIdx < tokens.count"))
        #expect(await responses.count == 1)
        #expect(await builds.count == 2)
    }

    @MainActor
    @Test
    func deterministicRepairRepeatsUntilStable() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let executableName = "BuildARepeatedSpacingTool"
        let builds = SequentialDeterministicSpacingBuilds(executableName: executableName)
        let processClient = SwiftPackageProcessClient(
            build: { packageRoot in
                await builds.next(packageRoot: packageRoot)
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
            import SwiftUI

            struct ContentView: View {
                @State private var tokens = ["one", "two"]
                @State private var firstIdx = 0
                @State private var secondIdx = 1

                var body: some View {
                    VStack {
                        if firstIdx< tokens.count {
                            Text(tokens[firstIdx])
                        }
                        if secondIdx< tokens.count {
                            Text(tokens[secondIdx])
                        }
                    }
                }
            }
            """
        ])
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { _, _ in
                try await responses.next()
            },
            generationOptions: GenerationOptions(),
            repairStrategy: .modelDiff(maxHunksPerTurn: 1),
            toolsDirectoryURL: toolsDirectory,
            processClient: processClient,
            metadataClient: .fallback()
        )

        let result = try await runtime.generateTool(
            for: "Build a repeated spacing tool",
            settings: .default
        )

        let contentView = try String(
            contentsOf: result.packageRootURL.appendingPathComponent("Sources/\(result.executableName)/ContentView.swift"),
            encoding: .utf8
        )
        #expect(contentView.contains("if firstIdx < tokens.count"))
        #expect(contentView.contains("if secondIdx < tokens.count"))
        #expect(await responses.count == 1)
        #expect(await builds.count == 3)
    }

    @MainActor
    @Test
    func modelRepairStartsAfterDeterministicRepairStalls() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let executableName = "BuildAModelRepairTool"
        let builds = UnsupportedModifierBuilds(executableName: executableName)
        let processClient = SwiftPackageProcessClient(
            build: { packageRoot in
                await builds.next(packageRoot: packageRoot)
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
            import SwiftUI

            struct ContentView: View {
                var body: some View {
                    Text("broken").definitelyNotReal()
                }
            }
            """,
            """
            --- ContentView.swift
            +++ ContentView.swift
            @@ -2,7 +2,7 @@
             struct ContentView: View {
                 var body: some View {
            -        Text("broken").definitelyNotReal()
            +        Text("fixed by model repair")
                 }
             }
            """
        ])
        let invocationCapture = LanguageModelInvocationCapture()
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { _, _ in
                try await responses.next()
            },
            generationOptions: GenerationOptions(),
            repairStrategy: .modelDiff(maxHunksPerTurn: 1),
            toolsDirectoryURL: toolsDirectory,
            processClient: processClient,
            metadataClient: .fallback(),
            afterLanguageModelInvocation: {
                await invocationCapture.record()
            }
        )
        let result = try await runtime.generateTool(
            for: "Build a model repair tool",
            settings: .default
        )

        let contentView = try String(
            contentsOf: result.packageRootURL.appendingPathComponent("Sources/\(result.executableName)/ContentView.swift"),
            encoding: .utf8
        )
        #expect(contentView.contains(#"Text("fixed by model repair")"#))
        #expect(await responses.count == 2)
        #expect(await invocationCapture.count == 2)
        #expect(await builds.count == 2)
    }

    @MainActor
    @Test
    func largeGeneratedFilesCanEnterModelRepairAboveBaseRegenerationThreshold() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let executableName = "BuildALargeModelRepair"
        let brokenLineCount = ToolGenerationRepairPolicy.regenerationThreshold + 1
        let builds = MultipleUnsupportedModifierBuilds(executableName: executableName)
        let processClient = SwiftPackageProcessClient(
            build: { packageRoot in
                await builds.next(packageRoot: packageRoot)
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
        let rowLineCount = brokenLineCount * ToolGenerationRepairPolicy.regenerationThresholdSourceLinesPerError
        let rowLines = (1...rowLineCount)
            .map { "            Text(\"Row \($0)\")" }
            .joined(separator: "\n")
        let brokenLines = (1...brokenLineCount)
            .map { "            Text(\"Broken \($0)\").definitelyNotReal()" }
            .joined(separator: "\n")
        let removedBrokenLines = (1...brokenLineCount)
            .map { "-            Text(\"Broken \($0)\").definitelyNotReal()" }
            .joined(separator: "\n")
        let addedFixedLines = (1...brokenLineCount)
            .map { "+            Text(\"Fixed \($0)\")" }
            .joined(separator: "\n")
        let largeBrokenSource = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                VStack {
        \(rowLines)
        \(brokenLines)
                }
            }
        }
        """
        let responses = LanguageModelResponseQueue([
            largeBrokenSource,
            """
            --- ContentView.swift
            +++ ContentView.swift
            @@
            \(removedBrokenLines)
            \(addedFixedLines)
            """
        ])
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { _, _ in
                try await responses.next()
            },
            generationOptions: GenerationOptions(),
            repairStrategy: .modelDiff(maxHunksPerTurn: nil),
            toolsDirectoryURL: toolsDirectory,
            processClient: processClient,
            metadataClient: .fallback()
        )

        let result = try await runtime.generateTool(
            for: "Build a large model repair tool",
            settings: .default
        )

        let contentView = try String(
            contentsOf: result.packageRootURL.appendingPathComponent("Sources/\(result.executableName)/ContentView.swift"),
            encoding: .utf8
        )
        #expect(contentView.contains(#"Text("Fixed 13")"#))
        #expect(!(contentView.contains("definitelyNotReal")))
        #expect(await responses.count == 2)
        #expect(await builds.count == 2)
    }

    @MainActor
    @Test
    func exhaustedModelRepairBudgetRegeneratesInsteadOfFailingCandidate() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let executableName = "BuildBudgetExhaustionTool"
        let brokenLineCount = ToolGenerationRepairPolicy.modelMaximumRepairAttempts + 1
        let builds = DistinctUnsupportedModifierBuilds(executableName: executableName)
        let processClient = SwiftPackageProcessClient(
            build: { packageRoot in
                await builds.next(packageRoot: packageRoot)
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
        let brokenLines = (1...brokenLineCount)
            .map { "            Text(\"Broken \($0)\").missing\($0)()" }
            .joined(separator: "\n")
        let budgetRowLineCount = brokenLineCount * ToolGenerationRepairPolicy.regenerationThresholdSourceLinesPerError
        let rowLines = (1...budgetRowLineCount)
            .map { "            Text(\"Row \($0)\")" }
            .joined(separator: "\n")
        let brokenSource = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                VStack {
        \(rowLines)
        \(brokenLines)
                }
            }
        }
        """
        let regeneratedSource = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                Text("Regenerated after budget")
            }
        }
        """
        let responses = BudgetExhaustionResponses(
            brokenSource: brokenSource,
            regeneratedSource: regeneratedSource
        )
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { prompt, _ in
                try await responses.next(prompt)
            },
            generationOptions: GenerationOptions(),
            repairStrategy: .modelDiff(maxHunksPerTurn: nil),
            toolsDirectoryURL: toolsDirectory,
            processClient: processClient,
            metadataClient: .fallback()
        )

        let result = try await runtime.generateTool(
            for: "Build budget exhaustion tool",
            settings: .default
        )

        let contentView = try String(
            contentsOf: result.packageRootURL.appendingPathComponent("Sources/\(result.executableName)/ContentView.swift"),
            encoding: .utf8
        )
        #expect(contentView.contains(#"Text("Regenerated after budget")"#))
        #expect(await responses.generationCount == 2)
        #expect(await responses.repairCount == ToolGenerationRepairPolicy.modelMaximumRepairAttempts)
        #expect(await builds.count == ToolGenerationRepairPolicy.modelMaximumRepairAttempts + 2)
    }

    @MainActor
    @Test
    func modelDiffEditRequestsFreshDiffAfterRepairPatchStalls() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let executableName = "RepairStallEdit"
        let tool = try Self.makeExistingTool(
            toolsDirectory: toolsDirectory,
            executableName: executableName,
            source: Self.originalEditableSource
        )
        let builds = UnsupportedModifierBuilds(executableName: executableName)
        let responses = LanguageModelResponseQueue([
            Self.breakOldTextDiff,
            "not a diff",
            "still not a diff",
            Self.renameOldToNewDiff
        ])
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { _, _ in
                try await responses.next()
            },
            generationOptions: GenerationOptions(),
            repairStrategy: .modelDiff(maxHunksPerTurn: 1),
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

        let result = try await runtime.generateTool(
            for: "Change old to new",
            existingTool: tool,
            settings: .default
        )

        let contentView = try String(contentsOf: Self.contentViewURL(for: result), encoding: .utf8)
        #expect(contentView.contains(#"Text("new")"#))
        #expect(await responses.count == 4)
        #expect(await builds.count == 2)
    }
}
