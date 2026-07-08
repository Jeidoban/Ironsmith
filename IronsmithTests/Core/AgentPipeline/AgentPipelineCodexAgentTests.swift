import AnyLanguageModel
import Foundation
import Testing
@testable import Ironsmith

extension AgentPipelineTests {
    @Test
    func codexAgentClientBuildsExecJSONCommandWritesTranscriptAndStreamsEvents() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageRoot = root.appendingPathComponent("Generated", isDirectory: true)
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        let swiftCache = root.appendingPathComponent("swift-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: swiftCache, withIntermediateDirectories: true)
        let missingCache = root.appendingPathComponent("missing-cache", isDirectory: true)

        let cliCapture = CodexAgentCLICapture()
        let cliClient = CodexCLIClient(
            run: { _ in
                Issue.record("Codex agent should use streaming exec.")
                return CodexCLIProcessResult(stdout: "", stderr: "", terminationStatus: 1)
            },
            runStreaming: { arguments, environment, onStdoutLine, _ in
                await cliCapture.record(arguments: arguments, environment: environment)
                await onStdoutLine(#"{"type":"thread.started","thread_id":"thread-1"}"#)
                await onStdoutLine(#"{"type":"item.completed","item":{"type":"agent_message","text":"I am editing ContentView."}}"#)
                await onStdoutLine(#"{"type":"item.started","item":{"type":"command_execution","command":"swift build","status":"in_progress","aggregated_output":"hidden"}}"#)
                await onStdoutLine(#"{"type":"turn.completed"}"#)
                return CodexCLIProcessResult(stdout: "jsonl", stderr: "", terminationStatus: 0)
            }
        )
        let client = CodexAgentClient.live(
            cliClient: cliClient,
            openAICodexAuthClient: .unconfigured,
            swiftCacheDirectoryCandidates: [swiftCache, missingCache]
        )
        let eventCapture = CodexAgentEventCapture()
        let request = CodexAgentRequest(
            packageRootURL: packageRoot,
            executableName: "MortgageMate",
            displayName: "Mortgage Mate",
            appKind: .window,
            sandboxEnabled: true,
            userPrompt: "Make a mortgage calculator",
            modelIdentifier: "codex:gpt-5.5",
            authentication: .apiKey("sk-test")
        ) { event in
            await eventCapture.record(event)
        }

        let result = try await client.run(request)

        let arguments = try #require(await cliCapture.arguments)
        let environment = try #require(await cliCapture.environment)
        #expect(result.terminationStatus == 0)
        #expect(arguments.prefix(7) == [
            "exec",
            "--json",
            "--sandbox",
            "workspace-write",
            "--cd",
            packageRoot.path,
            "--skip-git-repo-check",
        ])
        #expect(arguments.contains("--add-dir"))
        #expect(arguments.contains(swiftCache.path))
        #expect(!arguments.contains(missingCache.path))
        #expect(arguments.contains("--model"))
        #expect(arguments.contains("gpt-5.5"))
        #expect(arguments.last?.contains("Create or edit only Sources/MortgageMate/ContentView.swift") == true)
        #expect(arguments.last?.contains("normal swift build") == true)
        #expect(environment["OPENAI_API_KEY"] == "sk-test")
        #expect(FileManager.default.fileExists(atPath: result.transcriptURL.path))
        let transcript = try String(contentsOf: result.transcriptURL, encoding: .utf8)
        #expect(transcript.contains(#""thread_id":"thread-1""#))
        #expect(transcript.contains(#""aggregated_output":"hidden""#))
        #expect(await eventCapture.events == [
            .threadStarted("thread-1"),
            .agentMessage("I am editing ContentView."),
            .commandExecution(command: "swift build", status: "in_progress", exitCode: nil),
            .turnCompleted,
        ])
    }

    @Test
    func codexAgentClientValidatesChatGPTCredentialBeforeRunning() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageRoot = root.appendingPathComponent("Generated", isDirectory: true)
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)

        let authCapture = CodexAuthCapture()
        let authClient = OpenAICodexAuthClient(
            credential: { nil },
            signIn: { throw OpenAICodexAuthClientError.missingCredential },
            signOut: {},
            validCredential: {
                await authCapture.recordValidCredentialCall()
                return OpenAICodexCredential(accessToken: "access-token")
            },
            discoverModels: { [] }
        )
        let cliCapture = CodexAgentCLICapture()
        let cliClient = CodexCLIClient(
            run: { _ in CodexCLIProcessResult(stdout: "", stderr: "", terminationStatus: 0) },
            runStreaming: { arguments, environment, _, _ in
                await cliCapture.record(arguments: arguments, environment: environment)
                return CodexCLIProcessResult(stdout: "", stderr: "", terminationStatus: 0)
            }
        )
        let client = CodexAgentClient.live(
            cliClient: cliClient,
            openAICodexAuthClient: authClient,
            swiftCacheDirectoryCandidates: []
        )

        _ = try await client.run(
            CodexAgentRequest(
                packageRootURL: packageRoot,
                executableName: "Demo",
                displayName: "Demo",
                appKind: .window,
                sandboxEnabled: true,
                userPrompt: "Make a demo",
                modelIdentifier: "codex:gpt-5.5",
                authentication: .chatGPTLogin
            )
        )

        #expect(await authCapture.validCredentialCallCount == 1)
        #expect(try #require(await cliCapture.environment)["OPENAI_API_KEY"] == nil)
    }

    @MainActor
    @Test
    func codexRuntimeCreateFlowLetsCodexCreateContentView() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let requestCapture = CodexAgentRequestCapture()
        let codexAgentClient = CodexAgentClient(run: { request in
            await requestCapture.record(request)
            let layout = ToolPackageLayout(
                packageRootURL: request.packageRootURL,
                executableName: request.executableName
            )
            #expect(!FileManager.default.fileExists(atPath: try layout.packageFileURL(for: layout.contentViewSourcePath).path))
            let source = """
            import SwiftUI

            struct ContentView: View {
                var body: some View {
                    Text("codex generated")
                }
            }
            """
            try source.write(
                to: try layout.packageFileURL(for: layout.contentViewSourcePath),
                atomically: true,
                encoding: .utf8
            )
            await request.onEvent(.commandExecution(command: "swift build", status: "completed", exitCode: 0))
            return CodexAgentResult(
                stdout: "",
                stderr: "",
                terminationStatus: 0,
                transcriptURL: request.packageRootURL.appendingPathComponent(".codex/agent-test.jsonl")
            )
        })
        let runtime = Self.makeRuntime(
            languageModel: EmptyLanguageModel(),
            pipelineConfiguration: .codex(),
            toolsDirectoryURL: toolsDirectory,
            processClient: Self.successfulProcessClient(),
            metadataClient: ToolMetadataClient { _ in
                ToolMetadataSuggestion(displayName: "Codex Demo", iconPrompt: "")
            },
            promptRefinementClient: ToolPromptRefinementClient { _ in
                "Refined codex prompt"
            },
            codexAgentClient: codexAgentClient,
            codingAgentModelIdentifier: "gpt-5.5",
            codexAgentAuthentication: .apiKey("sk-test")
        )

        let result = try await runtime.generateTool(
            for: "Make a Codex demo",
            settings: ToolGenerationSettings(appKind: .window)
        )

        let request = try #require(await requestCapture.request)
        let contentView = try String(contentsOf: Self.contentViewURL(for: result), encoding: .utf8)
        #expect(request.userPrompt == "Refined codex prompt")
        #expect(request.modelIdentifier == "gpt-5.5")
        #expect(request.authentication == .apiKey("sk-test"))
        #expect(contentView.contains(#"Text("codex generated")"#))
    }

    @MainActor
    @Test
    func codexRuntimeRejectsProtectedPackageFileChanges() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let codexAgentClient = CodexAgentClient(run: { request in
            let layout = ToolPackageLayout(
                packageRootURL: request.packageRootURL,
                executableName: request.executableName
            )
            try "changed".write(to: layout.packageManifestURL, atomically: true, encoding: .utf8)
            try """
            import SwiftUI
            struct ContentView: View { var body: some View { Text("bad") } }
            """.write(
                to: try layout.packageFileURL(for: layout.contentViewSourcePath),
                atomically: true,
                encoding: .utf8
            )
            return CodexAgentResult(
                stdout: "",
                stderr: "",
                terminationStatus: 0,
                transcriptURL: request.packageRootURL.appendingPathComponent(".codex/agent-test.jsonl")
            )
        })
        let runtime = Self.makeRuntime(
            languageModel: EmptyLanguageModel(),
            pipelineConfiguration: .codex(),
            toolsDirectoryURL: toolsDirectory,
            processClient: Self.successfulProcessClient(),
            metadataClient: ToolMetadataClient { _ in
                ToolMetadataSuggestion(displayName: "Codex Demo", iconPrompt: "")
            },
            codexAgentClient: codexAgentClient,
            codingAgentModelIdentifier: "gpt-5.5",
            codexAgentAuthentication: .apiKey("sk-test")
        )

        await #expect(throws: CodexAgentError.protectedFileChanged("Package.swift")) {
            _ = try await runtime.generateTool(for: "Make a Codex demo", settings: .default)
        }
    }
}

private actor CodexAgentCLICapture {
    private(set) var arguments: [String]?
    private(set) var environment: [String: String]?

    func record(arguments: [String], environment: [String: String]) {
        self.arguments = arguments
        self.environment = environment
    }
}

private actor CodexAgentEventCapture {
    private(set) var events: [CodexAgentEvent] = []

    func record(_ event: CodexAgentEvent) {
        events.append(event)
    }
}

private actor CodexAgentRequestCapture {
    private(set) var request: CodexAgentRequest?

    func record(_ request: CodexAgentRequest) {
        self.request = request
    }
}

private actor CodexAuthCapture {
    private(set) var validCredentialCallCount = 0

    func recordValidCredentialCall() {
        validCredentialCallCount += 1
    }
}
