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
        let temporaryDirectory = root.appendingPathComponent("Temporary", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        let cliCapture = CodexAgentCLICapture()
        let cliClient = CodexCLIClient(
            run: { _ in
                Issue.record("Codex agent should use streaming exec.")
                return CodexCLIProcessResult(stdout: "", stderr: "", terminationStatus: 1)
            },
            runStreaming: { arguments, environment, onStdoutLine, onStderrLine in
                await cliCapture.record(arguments: arguments, environment: environment)
                await onStderrLine("2026-07-07 codex[1:2] dev 0 () : purging events up to event id 123")
                await onStderrLine("useful stderr")
                await onStdoutLine(#"{"type":"thread.started","thread_id":"thread-1"}"#)
                await onStdoutLine(#"{"type":"item.completed","item":{"type":"agent_message","text":"I am editing ContentView."}}"#)
                await onStdoutLine(#"{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"swift build","status":"in_progress","aggregated_output":"hidden"}}"#)
                await onStdoutLine(#"{"type":"item.completed","item":{"id":"item_2","type":"file_change","changes":[{"path":"/tmp/Generated/Sources/MortgageMate/ContentView.swift","kind":"add"}],"status":"completed"}}"#)
                await onStdoutLine(#"{"type":"item.completed","item":{"id":"item_3","type":"web_search","query":"lofi hip hop radio direct mp3 stream URL","action":{"type":"search","query":"lofi hip hop radio direct mp3 stream URL","queries":["lofi hip hop radio direct mp3 stream URL","SomaFM direct stream URLs"]}}}"#)
                await onStdoutLine(#"{"type":"item.started","item":{"id":"item_4","type":"todo_list","items":[{"text":"Create ContentView.swift","completed":false},{"text":"Build and verify","completed":false}]}}"#)
                await onStdoutLine(#"{"type":"item.updated","item":{"id":"item_4","type":"todo_list","items":[{"text":"Create ContentView.swift","completed":true},{"text":"Build and verify","completed":false}]}}"#)
                await onStdoutLine(#"{"type":"item.completed","item":{"id":"item_4","type":"todo_list","items":[{"text":"Create ContentView.swift","completed":true},{"text":"Build and verify","completed":true}]}}"#)
                await onStdoutLine(#"{"type":"turn.completed"}"#)
                return CodexCLIProcessResult(stdout: "jsonl", stderr: "", terminationStatus: 0)
            }
        )
        let client = CodexAgentClient.live(
            cliClient: cliClient,
            openAICodexAuthClient: .unconfigured,
            temporaryDirectory: temporaryDirectory
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
            reasoningEffort: .xhigh,
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
        #expect(!arguments.contains("--add-dir"))
        #expect(arguments.contains("--model"))
        #expect(arguments.contains("gpt-5.5"))
        #expect(arguments.contains(#"model_reasoning_effort="xhigh""#))
        let prompt = try #require(arguments.last)
        #expect(prompt.contains("Create or edit only Sources/MortgageMate/ContentView.swift"))
        #expect(prompt.contains("Run `swift build --disable-sandbox`"))
        #expect(!prompt.contains("HOME="))
        #expect(!prompt.contains("XDG_CACHE_HOME="))
        #expect(!prompt.contains("CLANG_MODULE_CACHE_PATH="))
        #expect(!prompt.contains("SWIFTPM_MODULECACHE_OVERRIDE="))
        #expect(!prompt.contains("SWIFT_MODULE_CACHE_PATH="))
        #expect(!prompt.contains("TMPDIR="))
        #expect(!prompt.contains("mktemp"))
        #expect(!prompt.contains("trap "))
        #expect(prompt.contains("Use \(temporaryDirectory.path)/ironsmith-codex-swift-"))
        #expect(prompt.contains("for any temporary scratch files you deliberately create."))
        #expect(prompt.contains("Do not write deliberate scratch files directly in the top-level system temp directory."))
        #expect(prompt.contains("Ironsmith will clean up the temporary workspace after Codex exits."))
        #expect(prompt.contains("Internet searches are encouraged"))
        #expect(!arguments.contains("--disable"))
        #expect(environment["CODEX_API_KEY"] == "sk-test")
        #expect(environment["OPENAI_API_KEY"] == nil)
        let codexHomeDirectory = try #require(environment["HOME"])
        #expect(codexHomeDirectory.hasPrefix("\(temporaryDirectory.path)/ironsmith-codex-swift-"))
        #expect(codexHomeDirectory.hasSuffix("/home"))
        let codexTemporaryWorkspace = String(codexHomeDirectory.dropLast("/home".count))
        #expect(environment["TMPDIR"] == nil)
        #expect(environment["XDG_CACHE_HOME"] == "\(codexTemporaryWorkspace)/cache")
        #expect(environment["CLANG_MODULE_CACHE_PATH"] == "\(codexTemporaryWorkspace)/clang-module-cache")
        #expect(environment["SWIFTPM_MODULECACHE_OVERRIDE"] == "\(codexTemporaryWorkspace)/swift-module-cache")
        #expect(environment["SWIFT_MODULE_CACHE_PATH"] == "\(codexTemporaryWorkspace)/swift-module-cache")
        let remainingTemporaryItems = try FileManager.default.contentsOfDirectory(
            atPath: temporaryDirectory.path
        )
        #expect(remainingTemporaryItems.isEmpty)
        #expect(FileManager.default.fileExists(atPath: result.transcriptURL.path))
        let metadata = try CodexAgentTranscriptReader.metadata(for: result.transcriptURL)
        #expect(
            metadata == CodexAgentSessionMetadata(
                providerIdentifier: "openai-api",
                toolCompatibility: .openAINative,
                transcriptFileName: result.transcriptURL.lastPathComponent
            )
        )
        let transcript = try String(contentsOf: result.transcriptURL, encoding: .utf8)
        #expect(transcript.contains(#""thread_id":"thread-1""#))
        #expect(transcript.contains(#""aggregated_output":"hidden""#))
        let events = await eventCapture.events
        #expect(events.contains(.threadStarted("thread-1")))
        #expect(events.contains(.error("useful stderr")))
        #expect(events.contains(.agentMessage("I am editing ContentView.")))
        #expect(events.contains(.commandExecution(id: "item_1", command: "swift build", status: "in_progress", exitCode: nil)))
        #expect(events.contains(.fileChange(
            id: "item_2",
            changes: [CodexAgentFileChange(path: "/tmp/Generated/Sources/MortgageMate/ContentView.swift", kind: "add")],
            status: "completed"
        )))
        #expect(events.contains(.webSearch(
            id: "item_3",
            search: CodexAgentWebSearch(
                query: "lofi hip hop radio direct mp3 stream URL",
                actionType: "search",
                actionQuery: "lofi hip hop radio direct mp3 stream URL",
                queries: [
                    "lofi hip hop radio direct mp3 stream URL",
                    "SomaFM direct stream URLs",
                ]
            ),
            status: "completed"
        )))
        #expect(events.contains(.todoList(
            id: "item_4",
            items: [
                CodexAgentTodoItem(text: "Create ContentView.swift", completed: true),
                CodexAgentTodoItem(text: "Build and verify", completed: true),
            ],
            status: "completed"
        )))
        #expect(events.contains(.turnCompleted))
        #expect(!events.contains { event in
            if case .error(let message) = event {
                return message.contains("purging events up to event id")
            }
            return false
        })
    }

    @Test
    func codexAgentClientConfiguresCustomResponsesProvider() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageRoot = root.appendingPathComponent("Generated", isDirectory: true)
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        let temporaryDirectory = root.appendingPathComponent("Temporary", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        let cliCapture = CodexAgentCLICapture()
        let cliClient = CodexCLIClient(
            run: { _ in
                Issue.record("Codex agent should use streaming exec.")
                return CodexCLIProcessResult(stdout: "", stderr: "", terminationStatus: 1)
            },
            runStreaming: { arguments, environment, _, _ in
                await cliCapture.record(arguments: arguments, environment: environment)
                return CodexCLIProcessResult(stdout: "", stderr: "", terminationStatus: 0)
            }
        )
        let client = CodexAgentClient.live(
            cliClient: cliClient,
            openAICodexAuthClient: .unconfigured,
            temporaryDirectory: temporaryDirectory
        )
        let provider = CodexAgentCustomResponsesProvider(
            configurationIdentifier: "ironsmith",
            sessionProviderIdentifier: "ironsmith",
            displayName: "Ironsmith",
            baseURL: URL(string: "https://api.ironsmith.test/api/v1")!,
            authenticationEnvironmentVariable: "IRONSMITH_CODEX_ACCESS_TOKEN",
            authenticationToken: "ironsmith-access-token"
        )

        _ = try await client.run(
            CodexAgentRequest(
                packageRootURL: packageRoot,
                executableName: "Demo",
                displayName: "Demo",
                appKind: .window,
                sandboxEnabled: true,
                userPrompt: "Make a demo",
                modelIdentifier: "deepseek/deepseek-v4-flash",
                authentication: .customResponsesProvider(provider)
            )
        )

        let arguments = try #require(await cliCapture.arguments)
        let environment = try #require(await cliCapture.environment)
        #expect(arguments.contains(#"model_provider="ironsmith""#))
        #expect(arguments.contains(#"model_providers.ironsmith.name="Ironsmith""#))
        #expect(
            arguments.contains(
                #"model_providers.ironsmith.base_url="https://api.ironsmith.test/api/v1""#
            )
        )
        #expect(arguments.contains(#"model_providers.ironsmith.wire_api="responses""#))
        #expect(arguments.contains("model_providers.ironsmith.requires_openai_auth=false"))
        #expect(
            arguments.contains(
                #"model_providers.ironsmith.env_key="IRONSMITH_CODEX_ACCESS_TOKEN""#
            )
        )
        #expect(arguments.contains("deepseek/deepseek-v4-flash"))
        #expect(!arguments.contains("ironsmith-access-token"))
        #expect(environment["IRONSMITH_CODEX_ACCESS_TOKEN"] == "ironsmith-access-token")

        let unauthenticatedProvider = CodexAgentCustomResponsesProvider(
            configurationIdentifier: "ironsmith_ollama",
            sessionProviderIdentifier: "ollama",
            displayName: "Ollama",
            baseURL: URL(string: "http://localhost:11434/v1")!,
            authenticationEnvironmentVariable: nil,
            authenticationToken: nil
        )
        _ = try await client.run(
            CodexAgentRequest(
                packageRootURL: packageRoot,
                executableName: "Demo",
                displayName: "Demo",
                appKind: .window,
                sandboxEnabled: true,
                userPrompt: "Make a demo",
                modelIdentifier: "gpt-oss:20b",
                authentication: .customResponsesProvider(unauthenticatedProvider)
            )
        )

        let unauthenticatedArguments = try #require(await cliCapture.arguments)
        let unauthenticatedEnvironment = try #require(await cliCapture.environment)
        #expect(unauthenticatedArguments.contains(#"model_provider="ironsmith_ollama""#))
        #expect(!unauthenticatedArguments.contains { $0.contains(".env_key=") })
        #expect(unauthenticatedEnvironment["IRONSMITH_CODEX_ACCESS_TOKEN"] == nil)
        #expect(unauthenticatedEnvironment["IRONSMITH_CODEX_PROVIDER_API_KEY"] == nil)
        #expect(environment["OPENAI_API_KEY"] == nil)
        #expect(arguments.contains(#"web_search="disabled""#))
        #expect(arguments.contains("apps._default.enabled=false"))
        for feature in [
            "apps",
            "tool_suggest",
            "multi_agent",
            "image_generation",
            "computer_use",
            "browser_use",
            "browser_use_external",
            "in_app_browser",
        ] {
            let featureIndex = try #require(arguments.firstIndex(of: feature))
            #expect(arguments[featureIndex - 1] == "--disable")
        }
        #expect(!arguments.contains("plugins"))
        #expect(!arguments.contains("--ignore-user-config"))
        #expect(arguments.last?.contains("Internet searches are encouraged") == false)
    }

    @Test
    func codexAgentClientKeepsNativeToolsForManagedOpenAIModel() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageRoot = root.appendingPathComponent("Generated", isDirectory: true)
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)

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
            openAICodexAuthClient: .unconfigured
        )
        let provider = CodexAgentCustomResponsesProvider(
            configurationIdentifier: "ironsmith",
            sessionProviderIdentifier: "ironsmith",
            displayName: "Ironsmith",
            baseURL: URL(string: "https://api.ironsmith.test/api/v1")!,
            authenticationEnvironmentVariable: "IRONSMITH_CODEX_ACCESS_TOKEN",
            authenticationToken: "ironsmith-access-token"
        )

        _ = try await client.run(
            CodexAgentRequest(
                packageRootURL: packageRoot,
                executableName: "Demo",
                displayName: "Demo",
                appKind: .window,
                sandboxEnabled: true,
                userPrompt: "Make a demo",
                modelIdentifier: "openai/gpt-5.4",
                authentication: .customResponsesProvider(provider)
            )
        )

        let arguments = try #require(await cliCapture.arguments)
        #expect(!arguments.contains(#"web_search="disabled""#))
        #expect(!arguments.contains("--disable"))
        #expect(arguments.last?.contains("Internet searches are encouraged") == true)
    }

    @Test
    func codexAgentToolCompatibilityDefaultsUnknownManagedModelsToPortable() {
        let provider = CodexAgentCustomResponsesProvider(
            configurationIdentifier: "ironsmith",
            sessionProviderIdentifier: "ironsmith",
            displayName: "Ironsmith",
            baseURL: URL(string: "https://api.ironsmith.test/api/v1")!,
            authenticationEnvironmentVariable: "IRONSMITH_CODEX_ACCESS_TOKEN",
            authenticationToken: "token"
        )

        for identifier in [
            "google/gemini-3.1-flash-lite",
            "anthropic/claude-sonnet",
            "deepseek/deepseek-v4-flash",
            "future-model",
        ] {
            #expect(
                CodexAgentToolCompatibility.resolved(
                    modelIdentifier: identifier,
                    authentication: .customResponsesProvider(provider)
                ) == .portable
            )
        }
        #expect(
            CodexAgentToolCompatibility.resolved(
                modelIdentifier: "openai.gpt-5",
                authentication: .customResponsesProvider(provider)
            ) == .openAINative
        )
        #expect(
            CodexAgentToolCompatibility.resolved(
                modelIdentifier: "gpt-5.5",
                authentication: .apiKey("key")
            ) == .openAINative
        )
        #expect(
            CodexAgentToolCompatibility.resolved(
                modelIdentifier: "codex:gpt-5.5",
                authentication: .chatGPTLogin
            ) == .openAINative
        )
    }

    @Test
    func codexAgentClientResumesLatestToolTranscriptThreadWhenAvailable() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageRoot = root.appendingPathComponent("Generated", isDirectory: true)
        let transcriptDirectory = CodexAgentTranscriptReader.transcriptDirectoryURL(
            for: packageRoot
        )
        try FileManager.default.createDirectory(at: transcriptDirectory, withIntermediateDirectories: true)
        let previousTranscriptURL = transcriptDirectory.appendingPathComponent("agent-previous.jsonl")
        try """
        {"type":"thread.started","thread_id":"019f4340-9398-71b2-928f-b6e5164d5da6"}
        {"type":"turn.completed"}
        """
        .write(to: previousTranscriptURL, atomically: true, encoding: .utf8)
        try CodexAgentTranscriptReader.writeMetadata(
            CodexAgentSessionMetadata(
                providerIdentifier: "openai-api",
                toolCompatibility: .openAINative,
                transcriptFileName: previousTranscriptURL.lastPathComponent
            ),
            for: previousTranscriptURL
        )
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        let temporaryDirectory = root.appendingPathComponent("Temporary", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        let cliCapture = CodexAgentCLICapture()
        let cliClient = CodexCLIClient(
            run: { _ in
                Issue.record("Codex agent should use streaming exec.")
                return CodexCLIProcessResult(stdout: "", stderr: "", terminationStatus: 1)
            },
            runStreaming: { arguments, environment, onStdoutLine, _ in
                await cliCapture.record(arguments: arguments, environment: environment)
                await onStdoutLine(#"{"type":"thread.started","thread_id":"019f4340-9398-71b2-928f-b6e5164d5da6"}"#)
                await onStdoutLine(#"{"type":"turn.completed"}"#)
                return CodexCLIProcessResult(stdout: "jsonl", stderr: "", terminationStatus: 0)
            }
        )
        let client = CodexAgentClient.live(
            cliClient: cliClient,
            openAICodexAuthClient: .unconfigured,
            temporaryDirectory: temporaryDirectory
        )

        let result = try await client.run(
            CodexAgentRequest(
                packageRootURL: packageRoot,
                executableName: "MortgageMate",
                displayName: "Mortgage Mate",
                appKind: .window,
                sandboxEnabled: true,
                userPrompt: "Improve the mortgage calculator",
                modelIdentifier: "codex:gpt-5.5",
                authentication: .apiKey("sk-test")
            )
        )

        let arguments = try #require(await cliCapture.arguments)
        let resumeIndex = try #require(arguments.firstIndex(of: "resume"))
        #expect(arguments[resumeIndex + 1] == "019f4340-9398-71b2-928f-b6e5164d5da6")
        #expect(arguments.last?.contains("Improve the mortgage calculator") == true)
        #expect(result.transcriptURL != previousTranscriptURL)
        #expect(FileManager.default.fileExists(atPath: result.transcriptURL.path))
    }

    @Test
    func codexAgentTranscriptReaderPicksNewestTranscriptAndParsesTimeline() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageRoot = root.appendingPathComponent("Generated", isDirectory: true)
        let transcriptDirectory = CodexAgentTranscriptReader.transcriptDirectoryURL(for: packageRoot)
        try FileManager.default.createDirectory(at: transcriptDirectory, withIntermediateDirectories: true)

        let olderURL = transcriptDirectory.appendingPathComponent("agent-older.jsonl")
        let newerURL = transcriptDirectory.appendingPathComponent("agent-newer.jsonl")
        try #"{"type":"thread.started","thread_id":"old-thread"}"#
            .write(to: olderURL, atomically: true, encoding: .utf8)
        try """
        {"type":"thread.started","thread_id":"thread-1"}
        {"type":"turn.started"}
        {"type":"item.completed","item":{"type":"agent_message","text":"I am editing ContentView.","aggregated_output":"hidden"}}
        {"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"swift build","status":"in_progress","aggregated_output":"hidden"}}
        {"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"swift build","status":"completed","exit_code":0,"aggregated_output":"hidden"}}
        {"type":"item.started","item":{"id":"item_2","type":"file_change","changes":[{"path":"/tmp/Generated/Sources/Demo/ContentView.swift","kind":"add"}],"status":"in_progress"}}
        {"type":"item.completed","item":{"id":"item_2","type":"file_change","changes":[{"path":"/tmp/Generated/Sources/Demo/ContentView.swift","kind":"add"}],"status":"completed"}}
        {"type":"item.started","item":{"id":"item_3","type":"web_search","query":"","action":{"type":"other"}}}
        {"type":"item.completed","item":{"id":"item_3","type":"web_search","query":"lofi hip hop radio direct mp3 stream URL","action":{"type":"search","query":"lofi hip hop radio direct mp3 stream URL","queries":["lofi hip hop radio direct mp3 stream URL","SomaFM direct stream URLs"]}}}
        {"type":"item.started","item":{"id":"item_4","type":"todo_list","items":[{"text":"Create ContentView.swift","completed":false},{"text":"Build and verify","completed":false}]}}
        {"type":"item.updated","item":{"id":"item_4","type":"todo_list","items":[{"text":"Create ContentView.swift","completed":true},{"text":"Build and verify","completed":false}]}}
        {"type":"item.completed","item":{"id":"item_4","type":"todo_list","items":[{"text":"Create ContentView.swift","completed":true},{"text":"Build and verify","completed":true}]}}
        {"type":"error","message":"apply_patch failed"}
        {"type":"turn.completed"}
        """
        .write(to: newerURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 10)],
            ofItemAtPath: olderURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 20)],
            ofItemAtPath: newerURL.path
        )

        let snapshot = try CodexAgentTranscriptReader.snapshot(for: packageRoot)

        #expect(snapshot.url?.resolvingSymlinksInPath() == newerURL.resolvingSymlinksInPath())
        #expect(try CodexAgentTranscriptReader.threadID(from: newerURL) == "thread-1")
        #expect(snapshot.entries.map(\.kind) == [
            .threadStarted("thread-1"),
            .turnStarted,
            .agentMessage("I am editing ContentView."),
            .commandExecution(command: "swift build", status: "completed", exitCode: 0),
            .fileChange(
                changes: [CodexAgentFileChange(path: "/tmp/Generated/Sources/Demo/ContentView.swift", kind: "add")],
                status: "completed"
            ),
            .webSearch(
                search: CodexAgentWebSearch(
                    query: "lofi hip hop radio direct mp3 stream URL",
                    actionType: "search",
                    actionQuery: "lofi hip hop radio direct mp3 stream URL",
                    queries: [
                        "lofi hip hop radio direct mp3 stream URL",
                        "SomaFM direct stream URLs",
                    ]
                ),
                status: "completed"
            ),
            .todoList(
                items: [
                    CodexAgentTodoItem(text: "Create ContentView.swift", completed: true),
                    CodexAgentTodoItem(text: "Build and verify", completed: true),
                ],
                status: "completed"
            ),
            .error("apply_patch failed"),
            .turnCompleted,
        ])
    }

    @Test
    func codexAgentTranscriptReaderResumesOnlyMatchingProviderAndToolProfile() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageRoot = root.appendingPathComponent("Generated", isDirectory: true)
        let transcriptDirectory = CodexAgentTranscriptReader.transcriptDirectoryURL(for: packageRoot)
        try FileManager.default.createDirectory(at: transcriptDirectory, withIntermediateDirectories: true)

        let portableURL = transcriptDirectory.appendingPathComponent("agent-portable.jsonl")
        try #"{"type":"thread.started","thread_id":"portable-thread"}"#
            .write(to: portableURL, atomically: true, encoding: .utf8)
        try CodexAgentTranscriptReader.writeMetadata(
            CodexAgentSessionMetadata(
                providerIdentifier: "ironsmith",
                toolCompatibility: .portable,
                transcriptFileName: portableURL.lastPathComponent
            ),
            for: portableURL
        )
        let metadataFreeURL = transcriptDirectory.appendingPathComponent("agent-metadata-free.jsonl")
        try #"{"type":"thread.started","thread_id":"metadata-free-thread"}"#
            .write(to: metadataFreeURL, atomically: true, encoding: .utf8)

        #expect(
            CodexAgentTranscriptReader.latestThreadID(
                for: packageRoot,
                providerIdentifier: "ironsmith",
                toolCompatibility: .portable
            ) == "portable-thread"
        )
        #expect(
            CodexAgentTranscriptReader.latestThreadID(
                for: packageRoot,
                providerIdentifier: "ironsmith",
                toolCompatibility: .openAINative
            ) == nil
        )
        #expect(
            CodexAgentTranscriptReader.latestThreadID(
                for: packageRoot,
                providerIdentifier: "other-provider",
                toolCompatibility: .portable
            ) == nil
        )
    }

    @Test
    func codexAgentDiagnosticsLogCompletedFileChangesAndSuppressInProgressDuplicates() {
        #expect(
            CodexAgentEvent.commandExecution(
                id: "item_1",
                command: "swift build",
                status: "in_progress",
                exitCode: nil
            ).diagnosticSummary == nil
        )
        #expect(
            CodexAgentEvent.commandExecution(
                id: "item_1",
                command: "swift build",
                status: "completed",
                exitCode: 0
            ).diagnosticSummary == "Codex command Completed (exit 0): swift build"
        )
        #expect(
            CodexAgentEvent.fileChange(
                id: "item_2",
                changes: [
                    CodexAgentFileChange(
                        path: "/tmp/Generated/Sources/Demo/ContentView.swift",
                        kind: "add"
                    )
                ],
                status: "completed"
            ).diagnosticSummary == "Codex file change Completed: Add Sources/Demo/ContentView.swift"
        )
        #expect(
            CodexAgentEvent.webSearch(
                id: "item_3",
                search: CodexAgentWebSearch(
                    query: "",
                    actionType: "other",
                    actionQuery: nil,
                    queries: []
                ),
                status: "in_progress"
            ).diagnosticSummary == nil
        )
        #expect(
            CodexAgentEvent.webSearch(
                id: "item_3",
                search: CodexAgentWebSearch(
                    query: "lofi hip hop radio direct mp3 stream URL",
                    actionType: "search",
                    actionQuery: "lofi hip hop radio direct mp3 stream URL",
                    queries: ["lofi hip hop radio direct mp3 stream URL"]
                ),
                status: "completed"
            ).diagnosticSummary == "Codex web search Completed: lofi hip hop radio direct mp3 stream URL"
        )
        #expect(
            CodexAgentEvent.todoList(
                id: "item_4",
                items: [
                    CodexAgentTodoItem(text: "Create ContentView.swift", completed: true),
                    CodexAgentTodoItem(text: "Build and verify", completed: true),
                ],
                status: "completed"
            ).diagnosticSummary == "Codex todo list Completed: 2/2 completed"
        )
    }

    @Test
    func codexAgentTranscriptReaderReturnsEmptySnapshotWhenMissing() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageRoot = root.appendingPathComponent("Generated", isDirectory: true)

        let snapshot = try CodexAgentTranscriptReader.snapshot(for: packageRoot)

        #expect(snapshot == .empty)
        #expect(!CodexAgentTranscriptReader.hasTranscript(for: packageRoot))
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
            openAICodexAuthClient: authClient
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
        #expect(try #require(await cliCapture.environment)["CODEX_API_KEY"] == nil)
        #expect(try #require(await cliCapture.environment)["OPENAI_API_KEY"] == nil)
    }

    @Test
    func codexAgentClientDeletesSwiftTempWorkspaceWhenCodexFails() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageRoot = root.appendingPathComponent("Generated", isDirectory: true)
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        let temporaryDirectory = root.appendingPathComponent("Temporary", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        let cliClient = CodexCLIClient(
            run: { _ in
                Issue.record("Codex agent should use streaming exec.")
                return CodexCLIProcessResult(stdout: "", stderr: "", terminationStatus: 1)
            },
            runStreaming: { _, _, _, _ in
                CodexCLIProcessResult(stdout: "", stderr: "failed", terminationStatus: 1)
            }
        )
        let client = CodexAgentClient.live(
            cliClient: cliClient,
            openAICodexAuthClient: .unconfigured,
            temporaryDirectory: temporaryDirectory
        )

        do {
            _ = try await client.run(
                CodexAgentRequest(
                    packageRootURL: packageRoot,
                    executableName: "Demo",
                    displayName: "Demo",
                    appKind: .window,
                    sandboxEnabled: true,
                    userPrompt: "Make a demo",
                    modelIdentifier: "codex:gpt-5.5",
                    authentication: .apiKey("sk-test")
                )
            )
            Issue.record("Expected Codex failure.")
        } catch let error as CodexAgentError {
            guard case .commandFailed = error else {
                Issue.record("Expected commandFailed, got \(error).")
                return
            }
        }

        let remainingTemporaryItems = try FileManager.default.contentsOfDirectory(
            atPath: temporaryDirectory.path
        )
        #expect(remainingTemporaryItems.isEmpty)
    }

    @Test
    func codexAgentStatusOneSuggestsUsageLimit() {
        let transcriptURL = URL(fileURLWithPath: "/tmp/agent.jsonl")
        let error = CodexAgentError.commandFailed(
            status: 1,
            stderr: "noisy stderr",
            transcriptURL: transcriptURL
        )

        #expect(
            error.errorDescription
                == "Codex couldn't continue. You might be out of Codex usage. Check your usage in Codex and try again after it resets. Transcript: /tmp/agent.jsonl"
        )
    }

    @MainActor
    @Test
    func codexRuntimeCreateFlowLetsCodexCreateContentView() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let requestCapture = CodexAgentRequestCapture()
        let invocationCapture = LanguageModelInvocationCapture()
        let generatedSource = """
        import SwiftUI

        private struct AppFeedback {}

        struct ContentView: View {
            @State private var feedback: AppFeedback?

            var body: some View {
                Text("codex generated")
            }
        }
        """
        let codexAgentClient = CodexAgentClient(run: { request in
            await requestCapture.record(request)
            let layout = ToolPackageLayout(
                packageRootURL: request.packageRootURL,
                executableName: request.executableName
            )
            #expect(!FileManager.default.fileExists(atPath: try layout.packageFileURL(for: layout.contentViewSourcePath).path))
            try generatedSource.write(
                to: try layout.packageFileURL(for: layout.contentViewSourcePath),
                atomically: true,
                encoding: .utf8
            )
            await request.onEvent(.commandExecution(id: nil, command: "swift build", status: "completed", exitCode: 0))
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
            codexAgentAuthentication: .apiKey("sk-test"),
            afterLanguageModelInvocation: {
                await invocationCapture.record()
            }
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
        #expect(contentView == generatedSource)
        #expect(await invocationCapture.count == 1)
    }

    @MainActor
    @Test
    func codexRuntimeRejectsProtectedPackageFileChanges() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }
        let requestCapture = CodexAgentRequestCapture()

        let codexAgentClient = CodexAgentClient(run: { request in
            await requestCapture.record(request)
            let layout = ToolPackageLayout(
                packageRootURL: request.packageRootURL,
                executableName: request.executableName
            )
            try "changed".write(to: layout.packageManifestURL, atomically: true, encoding: .utf8)
            try "changed".write(
                to: try layout.packageFileURL(for: layout.appEntrySourcePath),
                atomically: true,
                encoding: .utf8
            )
            try "struct Extra {}".write(
                to: try layout.packageFileURL(for: "Sources/\(request.executableName)/Extra.swift"),
                atomically: true,
                encoding: .utf8
            )
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

        let request = try #require(await requestCapture.request)
        let layout = ToolPackageLayout(
            packageRootURL: request.packageRootURL,
            executableName: request.executableName
        )
        #expect(
            try String(contentsOf: layout.packageManifestURL, encoding: .utf8)
                == layout.packageManifestContent()
        )
        #expect(
            try String(
                contentsOf: layout.packageFileURL(for: layout.appEntrySourcePath),
                encoding: .utf8
            ) == layout.fixedAppEntrySource(displayName: "Codex Demo", settings: .default)
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: try layout.packageFileURL(
                    for: "Sources/\(request.executableName)/Extra.swift"
                ).path
            )
        )
    }

    @Test
    func agentOutputFileLinksStayInsideToolPackage() throws {
        let packageRoot = try Self.makeTemporaryDirectory().standardizedFileURL
        defer { try? FileManager.default.removeItem(at: packageRoot) }
        let sourceURL = packageRoot.appendingPathComponent("Sources/App/ContentView.swift")
        let webURL = try #require(URL(string: "https://example.com/docs"))

        #expect(
            AgentOutputFileLinkResolver.resolvedURL(
                for: try #require(URL(string: "Sources/App/ContentView.swift")),
                relativeTo: packageRoot
            ) == sourceURL
        )
        #expect(
            AgentOutputFileLinkResolver.resolvedURL(
                for: sourceURL,
                relativeTo: packageRoot
            ) == sourceURL
        )
        #expect(
            AgentOutputFileLinkResolver.resolvedURL(
                for: packageRoot.appendingPathComponent("../outside.swift"),
                relativeTo: packageRoot
            ) == nil
        )
        #expect(
            AgentOutputFileLinkResolver.resolvedURL(
                for: try #require(URL(string: "command://run")),
                relativeTo: packageRoot
            ) == nil
        )
        #expect(
            AgentOutputFileLinkResolver.resolvedURL(for: webURL, relativeTo: packageRoot) == webURL
        )
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
