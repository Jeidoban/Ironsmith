import Foundation
import Testing
@testable import Ironsmith

@Suite(.serialized)
struct CustomCodingAgentTests {
    @MainActor
    @Test
    func presetsAreEditableRunnerConfigurations() {
        let claude = CustomCodingAgentPreset.claudeCode.agent
        #expect(claude.name == "Claude Code")
        #expect(
            claude.command
                == "claude -p --permission-mode auto --output-format stream-json --verbose --model sonnet {{prompt}}"
        )
        #expect(claude.promptDelivery == .placeholder)

        let openCode = CustomCodingAgentPreset.openCode.agent
        #expect(openCode.name == "OpenCode")
        #expect(openCode.command == "opencode run {{prompt}}")
    }

    @MainActor
    @Test
    func storeValidatesPersistsAndClearsDeletedSelection() throws {
        let suiteName = "CustomCodingAgentTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CustomCodingAgentStore(userDefaults: defaults)
        let saved = try store.save(
            CustomCodingAgent(
                name: "  My Agent  ",
                command: "  runner {{prompt}}  "
            )
        )
        store.selectedAgentID = saved.id
        #expect(saved.name == "My Agent")
        #expect(saved.command == "runner {{prompt}}")

        let reloaded = CustomCodingAgentStore(userDefaults: defaults)
        #expect(reloaded.agents == [saved])
        #expect(reloaded.selectedAgent == saved)

        #expect(throws: CustomCodingAgentValidationError.duplicateName) {
            try reloaded.save(CustomCodingAgent(name: "my agent", command: "other {{prompt}}"))
        }
        #expect(throws: CustomCodingAgentValidationError.invalidPlaceholderCount) {
            try reloaded.save(CustomCodingAgent(name: "Bad", command: "runner"))
        }
        #expect(throws: CustomCodingAgentValidationError.placeholderNotAllowedWithStandardInput) {
            try reloaded.save(
                CustomCodingAgent(
                    name: "Stdin",
                    command: "runner {{prompt}}",
                    promptDelivery: .standardInput
                )
            )
        }

        reloaded.delete(id: saved.id)
        #expect(reloaded.agents.isEmpty)
        #expect(reloaded.selectedAgentID == nil)
    }

    @Test
    func placeholderPromptIsPassedAsAQuotedPositionalArgument() {
        let prompt = #"hello $(touch /tmp/should-not-run) ' " world"#
        let agent = CustomCodingAgent(name: "Runner", command: "tool --prompt {{prompt}}")
        let request = CustomCodingAgentRequest(
            agent: agent,
            packageRootURL: URL(fileURLWithPath: "/tmp"),
            prompt: prompt
        )

        #expect(CustomCodingAgentClient.shellArguments(for: request) == [
            "-lc",
            #"tool --prompt "$1""#,
            "Runner",
            prompt,
        ])
    }

    @Test
    func standardInputDoesNotPutPromptInShellArguments() {
        let agent = CustomCodingAgent(
            name: "Runner",
            command: "tool --stdin",
            promptDelivery: .standardInput
        )
        let request = CustomCodingAgentRequest(
            agent: agent,
            packageRootURL: URL(fileURLWithPath: "/tmp"),
            prompt: "secret prompt"
        )
        #expect(CustomCodingAgentClient.shellArguments(for: request) == ["-lc", "tool --stdin"])
    }

    @Test
    func liveClientStreamsBothOutputsAndWritesJSONL() async throws {
        let packageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "custom-agent-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: packageRoot) }

        let recorder = CustomOutputRecorder()
        let agent = CustomCodingAgent(
            name: "Test Runner",
            command: "read prompt; printf 'out:%s\\n' \"$prompt\"; printf 'err:%s\\n' \"$prompt\" >&2",
            promptDelivery: .standardInput
        )
        let result = try await CustomCodingAgentClient.live.run(
            CustomCodingAgentRequest(
                agent: agent,
                packageRootURL: packageRoot,
                prompt: "hello stdin"
            ) { output in
                await recorder.append(output)
            }
        )

        #expect(result.terminationStatus == 0)
        #expect(
            result.transcriptURL.deletingLastPathComponent()
                == ToolPackageLayout.customAgentTranscriptsDirectoryURL(for: packageRoot)
        )
        #expect(result.transcriptURL.lastPathComponent.hasPrefix("test-runner-"))
        let streamed = await recorder.outputs
        #expect(streamed.contains { $0.stream == .stdout && $0.text == "out:hello stdin" })
        #expect(streamed.contains { $0.stream == .stderr && $0.text == "err:hello stdin" })
        let persisted = try CustomCodingAgentTranscriptReader.entries(for: packageRoot)
        #expect(persisted.count == 2)
        #expect(CustomCodingAgentTranscriptReader.hasTranscript(for: packageRoot))
    }

    @Test
    func displayEntriesShowOnlyClaudeAssistantTextWhilePreservingOtherOutput() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [
            CustomCodingAgentOutput(
                timestamp: timestamp,
                runner: "Claude Code",
                stream: .stdout,
                text: #"{"type":"system","subtype":"init","session_id":"session"}"#
            ),
            CustomCodingAgentOutput(
                timestamp: timestamp,
                runner: "Claude Code",
                stream: .stdout,
                text: #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"private"},{"type":"text","text":"Now I'll write the ContentView."},{"type":"tool_use","name":"Write"}]}}"#
            ),
            CustomCodingAgentOutput(
                timestamp: timestamp,
                runner: "Claude Code",
                stream: .stdout,
                text: #"{"type":"result","session_id":"session","result":"Duplicate final text"}"#
            ),
            CustomCodingAgentOutput(
                timestamp: timestamp,
                runner: "Other Runner",
                stream: .stdout,
                text: #"{"status":"ordinary JSON"}"#
            ),
            CustomCodingAgentOutput(
                timestamp: timestamp,
                runner: "Claude Code",
                stream: .stderr,
                text: "warning"
            ),
        ]

        let displayed = CustomCodingAgentTranscriptReader.displayEntries(from: entries)

        #expect(displayed.map(\.text) == [
            "Now I'll write the ContentView.",
            #"{"status":"ordinary JSON"}"#,
            "warning",
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func liveClientDrainsOutputBeforeSendingStandardInput() async throws {
        let packageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "custom-agent-pipe-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: packageRoot) }

        let agent = CustomCodingAgent(
            name: "Pipe Runner",
            command: "dd if=/dev/zero bs=1024 count=128 2>/dev/null | tr '\\0' x; printf '\\n'; read prompt; printf 'received:%s\\n' \"$prompt\"",
            promptDelivery: .standardInput
        )
        _ = try await CustomCodingAgentClient.live.run(
            CustomCodingAgentRequest(
                agent: agent,
                packageRootURL: packageRoot,
                prompt: "after output"
            )
        )
        let entries = try CustomCodingAgentTranscriptReader.entries(for: packageRoot)
        #expect(entries.contains { $0.text == "received:after output" })
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingLiveClientTerminatesCompoundCommandGroup() async throws {
        let packageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "custom-agent-cancel-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: packageRoot) }

        let agent = CustomCodingAgent(
            name: "Compound Runner",
            command: "trap '' TERM; (trap '' TERM; sleep 30) & wait",
            promptDelivery: .standardInput
        )
        let task = Task {
            try await CustomCodingAgentClient.live.run(
                CustomCodingAgentRequest(
                    agent: agent,
                    packageRootURL: packageRoot,
                    prompt: "cancel"
                )
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test
    func workspacePromptIncludesReadOnlyAttachmentPaths() {
        let attachmentURL = URL(fileURLWithPath: "/tmp/reference image.png")
        let prompt = CustomCodingAgentPrompt.compose(
            userPrompt: "Build it",
            displayName: "Example",
            executableName: "Example",
            appKind: .window,
            sandboxEnabled: true,
            attachments: [
                ToolPersistedPromptAttachment(
                    fileName: "reference image.png",
                    url: attachmentURL,
                    isImage: true
                )
            ]
        )
        #expect(prompt.contains(attachmentURL.path))
        #expect(prompt.contains("strictly as read-only context"))
        #expect(prompt.contains("Create or edit only Sources/Example/ContentView.swift"))
    }

    @MainActor
    @Test
    func selectedRunnerFlowsIntoCustomPipelineContext() async throws {
        let preferences = InferenceTests.generationPreferences()
        preferences.codingAgentPreference = .custom
        let suiteName = "CustomCodingAgentContextTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let runners = CustomCodingAgentStore(userDefaults: defaults)
        let runner = try runners.save(
            CustomCodingAgent(name: "CLI", command: "agent {{prompt}}")
        )
        runners.selectedAgentID = runner.id

        let store = InferenceStore(
            dependencies: InferenceTests.dependencies(),
            generationPreferences: preferences,
            customCodingAgents: runners,
            appleFoundationModelPreferenceStore: InferenceTests.appleFoundationModelPreferenceStore()
        )
        let provider = try #require(ProviderCatalog.makeProvider(for: .ollama))
        let model = ModelConfig(
            identifier: "test-model",
            displayName: "Test Model",
            providerIdentifier: provider.identifier,
            source: .remote,
            installState: .installed
        )
        store.providers = [provider]
        store.remoteModels = [model]
        store.selectedModelID = model.selectionIdentifier

        let context = try await store.makeSelectedAgentLanguageModelContext()
        #expect(context.pipelineConfiguration == .custom())
        #expect(context.customCodingAgent == runner)
        #expect(context.codexAgentAuthentication == nil)
        #expect(context.codingAgentSupportsImageInput)
    }

    @MainActor
    @Test
    func failedCustomRunnerRestoresProtectedWorkspaceFiles() async throws {
        let toolsDirectory = try AgentPipelineTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let runner = CustomCodingAgent(name: "Failing Runner", command: "agent {{prompt}}")
        let client = CustomCodingAgentClient { request in
            let layout = ToolPackageLayout(
                packageRootURL: request.packageRootURL,
                executableName: "CustomFailure"
            )
            try "corrupted".write(
                to: layout.packageManifestURL,
                atomically: true,
                encoding: .utf8
            )
            try "struct Extra {}".write(
                to: layout.sourceDirectoryURL.appendingPathComponent("Extra.swift"),
                atomically: true,
                encoding: .utf8
            )
            throw CustomCodingAgentError.commandFailed(
                status: 7,
                transcriptURL: request.packageRootURL.appendingPathComponent("failure.jsonl")
            )
        }
        let runtime = AgentPipelineTests.makeRuntime(
            languageModel: EmptyLanguageModel(),
            pipelineConfiguration: .custom(),
            toolsDirectoryURL: toolsDirectory,
            processClient: AgentPipelineTests.successfulProcessClient(),
            planningClient: ToolGenerationPlanningClient { _ in
                ToolCreationPlan(displayName: "Custom Failure", iconPrompt: "")
            },
            customCodingAgentClient: client,
            customCodingAgent: runner
        )

        await #expect(throws: CustomCodingAgentError.self) {
            _ = try await runtime.generateTool(for: "Build a failing app", settings: .default)
        }

        let packageRoot = toolsDirectory.appendingPathComponent("custom-failure", isDirectory: true)
        let layout = ToolPackageLayout(
            packageRootURL: packageRoot,
            executableName: "CustomFailure"
        )
        let manifest = try String(contentsOf: layout.packageManifestURL, encoding: .utf8)
        #expect(manifest.contains("// swift-tools-version"))
        #expect(!manifest.contains("corrupted"))
        #expect(!FileManager.default.fileExists(
            atPath: layout.sourceDirectoryURL.appendingPathComponent("Extra.swift").path
        ))
    }
}

private actor CustomOutputRecorder {
    private(set) var outputs: [CustomCodingAgentOutput] = []

    func append(_ output: CustomCodingAgentOutput) {
        outputs.append(output)
    }
}
