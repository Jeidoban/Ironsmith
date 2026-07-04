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
            pipelineConfiguration: .small(repairStrategy: .deterministicOnly),
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
            pipelineConfiguration: .small(repairStrategy: .modelSearchReplace(maxPatchBlocksPerTurn: 1)),
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
            pipelineConfiguration: .small(repairStrategy: .modelSearchReplace(maxPatchBlocksPerTurn: 1)),
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
            <<<<<<< SEARCH
                    Text("broken").definitelyNotReal()
            =======
                    Text("fixed by model repair")
            >>>>>>> REPLACE
            """
        ])
        let invocationCapture = LanguageModelInvocationCapture()
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { _, _ in
                try await responses.next()
            },
            generationOptions: GenerationOptions(),
            pipelineConfiguration: .small(repairStrategy: .modelSearchReplace(maxPatchBlocksPerTurn: 1)),
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
        let fixedLines = (1...brokenLineCount)
            .map { "            Text(\"Fixed \($0)\")" }
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
            <<<<<<< SEARCH
            \(brokenLines)
            =======
            \(fixedLines)
            >>>>>>> REPLACE
            """
        ])
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { _, _ in
                try await responses.next()
            },
            generationOptions: GenerationOptions(),
            pipelineConfiguration: .large(repairStrategy: .modelSearchReplace(maxPatchBlocksPerTurn: ToolGenerationRepairPolicy.largeModelPatchBlocksPerTurn)),
            toolsDirectoryURL: toolsDirectory,
            processClient: processClient,
            metadataClient: ToolMetadataClient { _ in
                ToolMetadataSuggestion(displayName: "Build A Large Model Repair", iconPrompt: "")
            }
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
    func largeModelRepairPromptIncludesAllContentViewDiagnostics() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let source = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                VStack {
                    Text("Broken 1").missingOne()
                    Text("Broken 2").missingTwo()
                }
            }
        }
        """
        let diagnostics = [
            SwiftCompilerDiagnostic(
                relativePath: "Sources/GeneratedTool/ContentView.swift",
                line: 6,
                column: 37,
                severity: .error,
                message: "value of type 'Text' has no member 'missingOne'",
                supportingLines: []
            ),
            SwiftCompilerDiagnostic(
                relativePath: "Sources/GeneratedTool/ContentView.swift",
                line: 7,
                column: 37,
                severity: .error,
                message: "value of type 'Text' has no member 'missingTwo'",
                supportingLines: []
            ),
        ]
        let languageModelContext = AgentLanguageModelContext(
            languageModel: EmptyLanguageModel(),
            options: GenerationOptions(),
            pipelineConfiguration: .large(repairStrategy: .modelSearchReplace(maxPatchBlocksPerTurn: ToolGenerationRepairPolicy.largeModelPatchBlocksPerTurn))
        )
        let dependencies = ToolGenerationRuntimeDependencies(
            toolsDirectoryURL: toolsDirectory,
            fileClient: .live,
            processClient: .live,
            appBundleClient: .noOp(),
            versionBackupClient: .live
        )
        let runtimeContext = ToolGenerationRuntimeContext(
            languageModelContext: languageModelContext,
            dependencies: dependencies
        )
        let packageRoot = toolsDirectory.appendingPathComponent("PromptPlan", isDirectory: true)
        let layout = ToolPackageLayout(packageRootURL: packageRoot, executableName: "PromptPlan")
        let loop = ContentViewBuildRepairLoop(
            context: runtimeContext,
            layout: layout,
            displayName: "Prompt Plan",
            contentViewPath: layout.contentViewSourcePath,
            regenerationThreshold: ToolGenerationRepairPolicy.regenerationThreshold,
            maximumGenerationAttempts: 1,
            lifecycle: .noop
        )

        let plan = loop.makeRepairPromptPlan(source: source, diagnostics: diagnostics)

        #expect(plan.maximumPatchBlocks == ToolGenerationRepairPolicy.largeModelPatchBlocksPerTurn)
        #expect(plan.targetDiagnostics == diagnostics)
    }

    @MainActor
    @Test
    func largeModelRepairPromptCapsCatastrophicDiagnosticStorms() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let brokenLines = (1...250)
            .map { #"                    Text("Broken \#($0)").missing\#($0)()"# }
            .joined(separator: "\n")
        let source = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                VStack {
        \(brokenLines)
                }
            }
        }
        """
        let diagnostics = (1...250).map { index in
            SwiftCompilerDiagnostic(
                relativePath: "Sources/GeneratedTool/ContentView.swift",
                line: index + 5,
                column: 43,
                severity: .error,
                message: "value of type 'Text' has no member 'missing\(index)'",
                supportingLines: []
            )
        }
        let languageModelContext = AgentLanguageModelContext(
            languageModel: EmptyLanguageModel(),
            options: GenerationOptions(),
            pipelineConfiguration: .large(repairStrategy: .modelSearchReplace(maxPatchBlocksPerTurn: ToolGenerationRepairPolicy.largeModelPatchBlocksPerTurn))
        )
        let dependencies = ToolGenerationRuntimeDependencies(
            toolsDirectoryURL: toolsDirectory,
            fileClient: .live,
            processClient: .live,
            appBundleClient: .noOp(),
            versionBackupClient: .live
        )
        let runtimeContext = ToolGenerationRuntimeContext(
            languageModelContext: languageModelContext,
            dependencies: dependencies
        )
        let packageRoot = toolsDirectory.appendingPathComponent("PromptCap", isDirectory: true)
        let layout = ToolPackageLayout(packageRootURL: packageRoot, executableName: "PromptCap")
        let loop = ContentViewBuildRepairLoop(
            context: runtimeContext,
            layout: layout,
            displayName: "Prompt Cap",
            contentViewPath: layout.contentViewSourcePath,
            regenerationThreshold: ToolGenerationRepairPolicy.regenerationThreshold,
            maximumGenerationAttempts: 1,
            lifecycle: .noop
        )

        let plan = loop.makeRepairPromptPlan(source: source, diagnostics: diagnostics)

        #expect(plan.targetDiagnostics.count == ToolGenerationRepairPolicy.largeModelMaximumRepairDiagnostics)
        #expect(plan.snippets.count == ToolGenerationRepairPolicy.largeModelMaximumRepairDiagnostics)
        #expect(plan.targetDiagnostics.first?.line == 6)
        #expect(plan.targetDiagnostics.last?.line == 205)
    }

    @MainActor
    @Test
    func largeModelSafetyLimitPreservesLatestAcceptedSource() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let initialSource = Self.sourceWithMissingMember("missing1")
        let responses = LanguageModelResponseQueue(
            [initialSource] + (1...ToolGenerationRepairPolicy.largeModelMaximumRepairAttempts).map { attempt in
                """
                <<<<<<< SEARCH
                        Text("Broken").missing\(attempt)()
                =======
                        Text("Broken").missing\(attempt + 1)()
                >>>>>>> REPLACE
                """
            }
        )
        let processClient = SwiftPackageProcessClient(
            build: { packageRoot in
                guard let contentViewURL = Self.generatedContentViewURL(in: packageRoot) else {
                    return SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
                }
                let source = (try? String(contentsOf: contentViewURL, encoding: .utf8)) ?? ""
                guard let line = source.lineNumber(containing: ".missing") else {
                    return SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
                }
                let relativePath = "Sources/\(contentViewURL.deletingLastPathComponent().lastPathComponent)/ContentView.swift"
                let output = "\(relativePath):\(line):25: error: value of type 'Text' has no member 'missing'"
                return SwiftPackageBuildResult(succeeded: false, stdout: output, stderr: "", terminationStatus: 1)
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
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { _, _ in
                try await responses.next()
            },
            generationOptions: GenerationOptions(),
            pipelineConfiguration: .large(repairStrategy: .modelSearchReplace(maxPatchBlocksPerTurn: ToolGenerationRepairPolicy.largeModelPatchBlocksPerTurn)),
            toolsDirectoryURL: toolsDirectory,
            processClient: processClient,
            metadataClient: ToolMetadataClient { _ in
                ToolMetadataSuggestion(displayName: "Build Safety Limit Repair", iconPrompt: "")
            }
        )

        do {
            _ = try await runtime.generateTool(
                for: "Build a safety limit repair tool",
                settings: .default
            )
            Issue.record("Expected large-model repair to stop at the safety limit.")
        } catch let error as ToolGenerationError {
            #expect(error == .stoppedToSaveTokens("Stopped after \(ToolGenerationRepairPolicy.largeModelMaximumRepairAttempts) repair attempts preserve tokens. Continue to keep repairing from current source."))
            #expect(error.localizedDescription.contains("Stopped after \(ToolGenerationRepairPolicy.largeModelMaximumRepairAttempts) repair attempts"))
        }

        let packageRoot = toolsDirectory.appendingPathComponent("build-safety-limit-repair", isDirectory: true)
        let contentViewURL = try #require(Self.generatedContentViewURL(in: packageRoot))
        let contentView = try String(contentsOf: contentViewURL, encoding: .utf8)
        #expect(contentView.contains("missing\(ToolGenerationRepairPolicy.largeModelMaximumRepairAttempts + 1)"))
        #expect(await responses.count == ToolGenerationRepairPolicy.largeModelMaximumRepairAttempts + 1)
    }

    @MainActor
    @Test
    func largeModelRepairAcceptsTemporaryDiagnosticIncrease() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let initialSource = Self.sourceWithMissingMember("missingOne")
        let twoErrorSource = """
                VStack {
                    Text("Broken").missingOne()
                    Text("Also Broken").missingTwo()
                }
        """
        let fixedSource = """
                VStack {
                    Text("Fixed")
                    Text("Also Fixed")
                }
        """
        let responses = LanguageModelResponseQueue([
            initialSource,
            """
            <<<<<<< SEARCH
                    Text("Broken").missingOne()
            =======
            \(twoErrorSource)
            >>>>>>> REPLACE
            """,
            """
            <<<<<<< SEARCH
            \(twoErrorSource)
            =======
            \(fixedSource)
            >>>>>>> REPLACE
            """,
        ])
        let processClient = SwiftPackageProcessClient(
            build: { packageRoot in
                guard let contentViewURL = Self.generatedContentViewURL(in: packageRoot) else {
                    return SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
                }
                let source = (try? String(contentsOf: contentViewURL, encoding: .utf8)) ?? ""
                let relativePath = "Sources/\(contentViewURL.deletingLastPathComponent().lastPathComponent)/ContentView.swift"
                var diagnostics: [String] = []
                if let line = source.lineNumber(containing: "missingOne") {
                    diagnostics.append("\(relativePath):\(line):25: error: value of type 'Text' has no member 'missingOne'")
                }
                if let line = source.lineNumber(containing: "missingTwo") {
                    diagnostics.append("\(relativePath):\(line):25: error: value of type 'Text' has no member 'missingTwo'")
                }
                guard !diagnostics.isEmpty else {
                    return SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
                }
                return SwiftPackageBuildResult(
                    succeeded: false,
                    stdout: diagnostics.joined(separator: "\n"),
                    stderr: "",
                    terminationStatus: 1
                )
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
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { _, _ in
                try await responses.next()
            },
            generationOptions: GenerationOptions(),
            pipelineConfiguration: .large(repairStrategy: .modelSearchReplace(maxPatchBlocksPerTurn: ToolGenerationRepairPolicy.largeModelPatchBlocksPerTurn)),
            toolsDirectoryURL: toolsDirectory,
            processClient: processClient,
            metadataClient: ToolMetadataClient { _ in
                ToolMetadataSuggestion(displayName: "Temporary Increase Repair", iconPrompt: "")
            }
        )

        let result = try await runtime.generateTool(
            for: "Build a temporary increase repair tool",
            settings: .default
        )

        let contentView = try String(contentsOf: Self.contentViewURL(for: result), encoding: .utf8)
        #expect(contentView.contains(#"Text("Fixed")"#))
        #expect(contentView.contains(#"Text("Also Fixed")"#))
        #expect(await responses.count == 3)
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
            pipelineConfiguration: .small(repairStrategy: .modelSearchReplace(maxPatchBlocksPerTurn: ToolGenerationRepairPolicy.smallModelPatchBlocksPerTurn)),
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
    func smallModelPatchEditRequestsFreshPatchAfterRepairPatchStalls() async throws {
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
            Self.breakOldTextPatch,
            "not a patch",
            "still not a patch",
            Self.renameOldToNewPatch
        ])
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { _, _ in
                try await responses.next()
            },
            generationOptions: GenerationOptions(),
            pipelineConfiguration: .small(repairStrategy: .modelSearchReplace(maxPatchBlocksPerTurn: 1)),
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
