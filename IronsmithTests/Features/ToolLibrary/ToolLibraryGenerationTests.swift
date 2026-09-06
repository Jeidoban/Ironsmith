import AnyLanguageModel
import Foundation
import Supabase
import SwiftData
import Testing
@testable import Ironsmith

extension ToolLibraryTests {
    @MainActor
    @Test
    func downloadedAppFirstEditUsesExistingStoreAttributionAndSourceHash() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = "import SwiftUI\nstruct ContentView: View { var body: some View { Text(\"Original\") } }\n"
        let tool = Tool(
            name: "Tiny Notes",
            executableName: "TinyNotes",
            packageRootPath: root.path,
            storeMetadata: ToolStoreMetadata(
                provenance: StoreProvenance(
                    remixSource: StoreVersionReference(
                        versionId: "00000000-0000-4000-8000-000000000201",
                        storeId: IronsmithStoreConstants.communityStoreId,
                        appId: "00000000-0000-4000-8000-000000000101",
                        sourceSha256: IronsmithStoreClient.sha256Hex(for: source)
                    ),
                    inspirations: []
                )
            )
        )
        let sourceURL = try tool.packageLayout.packageFileURL(for: tool.contentViewSourcePath)
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        let store = ToolLibraryStore()

        #expect(store.isFirstEditOfDownloadedApp(tool))
        #expect(
            store.remixIdentitySubmissionAction(
                for: tool,
                isStoreFeatureEnabled: true,
                generatesIdentity: true,
                hasPresentedNotice: false,
                isConfirmedDownloadedFromAnotherUser: true
            ) == .presentNotice
        )
        #expect(
            store.remixIdentitySubmissionAction(
                for: tool,
                isStoreFeatureEnabled: true,
                generatesIdentity: true,
                hasPresentedNotice: true,
                isConfirmedDownloadedFromAnotherUser: true
            ) == .generateIdentity
        )
        #expect(
            store.remixIdentitySubmissionAction(
                for: tool,
                isStoreFeatureEnabled: true,
                generatesIdentity: false,
                hasPresentedNotice: false,
                isConfirmedDownloadedFromAnotherUser: true
            ) == .submit
        )
        #expect(
            store.remixIdentitySubmissionAction(
                for: tool,
                isStoreFeatureEnabled: true,
                generatesIdentity: true,
                hasPresentedNotice: false,
                isConfirmedDownloadedFromAnotherUser: false
            ) == .submit
        )
        #expect(
            store.remixIdentitySubmissionAction(
                for: tool,
                isStoreFeatureEnabled: false,
                generatesIdentity: true,
                hasPresentedNotice: false,
                isConfirmedDownloadedFromAnotherUser: true
            ) == .submit
        )
        try (source + "// changed\n").write(
            to: sourceURL,
            atomically: true,
            encoding: .utf8
        )
        #expect(!store.isFirstEditOfDownloadedApp(tool))
        #expect(
            store.remixIdentitySubmissionAction(
                for: tool,
                isStoreFeatureEnabled: true,
                generatesIdentity: true,
                hasPresentedNotice: false,
                isConfirmedDownloadedFromAnotherUser: true
            ) == .submit
        )

        try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        tool.generationState = .stopped
        tool.generationMode = .edit
        #expect(!store.isFirstEditOfDownloadedApp(tool))
    }

    @MainActor
    @Test
    func remixStatusOnlyTracksDownloadedAppsFirstEdit() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let inferenceStore = InferenceStore(
            dependencies: Self.inferenceDependencies(),
            appleFoundationModelPreferenceStore: try Self.appleFoundationModelPreferenceStore()
        )
        await inferenceStore.loadIfNeeded(modelContext: context)

        let source =
            "import SwiftUI\nstruct ContentView: View { var body: some View { Text(\"Original\") } }\n"
        let tool = Tool(
            name: "Tiny Notes",
            executableName: "TinyNotes",
            packageRootPath: root.path,
            storeMetadata: ToolStoreMetadata(
                provenance: StoreProvenance(
                    remixSource: StoreVersionReference(
                        versionId: "00000000-0000-4000-8000-000000000202",
                        storeId: IronsmithStoreConstants.communityStoreId,
                        appId: "00000000-0000-4000-8000-000000000102",
                        appName: "Original Notes",
                        sourceSha256: IronsmithStoreClient.sha256Hex(for: source)
                    ),
                    inspirations: []
                )
            )
        )
        let sourceURL = try tool.packageLayout.packageFileURL(for: tool.contentViewSourcePath)
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        context.insert(tool)
        try context.save()

        let store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: ToolGenerationClient { _ in
                    throw ToolGenerationError.stoppedToSaveTokens("Paused for test")
                },
                runnerClient: ToolRunnerClient { _ in }
            )
        )
        store.selectForEditing(tool)
        store.prompt = "Change the app"

        await store.submitPrompt(modelContext: context, inferenceStore: inferenceStore)

        #expect(tool.generationState == .stopped)
        #expect(store.isActivelyRemixingFromStore(tool))

        store.discardGeneration(tool, in: context)
        #expect(!store.isActivelyRemixingFromStore(tool))

        try (source + "// changed\n").write(
            to: sourceURL,
            atomically: true,
            encoding: .utf8
        )
        store.selectForEditing(tool)
        store.prompt = "Change it again"

        await store.submitPrompt(modelContext: context, inferenceStore: inferenceStore)

        #expect(tool.generationState == .stopped)
        #expect(!store.isActivelyRemixingFromStore(tool))
    }

    @MainActor
    @Test
    func toolLibraryStoreSuppressesGenerationCancellationErrors() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let inferenceStore = InferenceStore(
            dependencies: Self.inferenceDependencies(),
            appleFoundationModelPreferenceStore: try Self.appleFoundationModelPreferenceStore()
        )
        await inferenceStore.loadIfNeeded(modelContext: context)

        let store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: ToolGenerationClient { _ in
                    throw CancellationError()
                },
                runnerClient: ToolRunnerClient { _ in }
            )
        )
        store.prompt = "Build a cancellable tool"

        await store.submitPrompt(modelContext: context, inferenceStore: inferenceStore)

        #expect(store.presentedErrorMessage == nil)
        #expect(!(store.isGenerating))
    }

    @MainActor
    @Test
    func toolLibraryStoreSuppressesCancelledURLSessionGenerationErrors() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let inferenceStore = InferenceStore(
            dependencies: Self.inferenceDependencies(),
            appleFoundationModelPreferenceStore: try Self.appleFoundationModelPreferenceStore()
        )
        await inferenceStore.loadIfNeeded(modelContext: context)

        let store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: ToolGenerationClient { _ in
                    throw NSError(
                        domain: NSURLErrorDomain,
                        code: NSURLErrorCancelled,
                        userInfo: [NSLocalizedDescriptionKey: "cancelled"]
                    )
                },
                runnerClient: ToolRunnerClient { _ in }
            )
        )
        store.prompt = "Build a cancellable tool"

        await store.submitPrompt(modelContext: context, inferenceStore: inferenceStore)

        #expect(store.presentedErrorMessage == nil)
        #expect(!(store.isGenerating))
    }

    @MainActor
    @Test
    func toolLibraryStoreKeepsLateCanceledSuccessfulCreateReady() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let inferenceStore = InferenceStore(
            dependencies: Self.inferenceDependencies(),
            appleFoundationModelPreferenceStore: try Self.appleFoundationModelPreferenceStore()
        )
        await inferenceStore.loadIfNeeded(modelContext: context)

        let packageRoot = root.appendingPathComponent("LateCreate", isDirectory: true)
        let gate = LateGenerationCompletionGate()
        let notificationCapture = ToolGenerationNotificationCapture()
        let store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: ToolGenerationClient { request in
                    try await request.lifecycle.prepareCreatedTool(
                        ToolGenerationPreparedTool(
                            name: "Late Create",
                            executableName: "LateCreate",
                            bundleIdentifier: ToolBundleIdentifier.make(executableName: "LateCreate"),
                            settings: request.settings,
                            packageRootURL: packageRoot
                        ),
                        request.prompt
                    )
                    await gate.startAndWaitForRelease()
                    return ToolGenerationResult(
                        toolName: "Late Create",
                        executableName: "LateCreate",
                        settings: request.settings,
                        packageRootURL: packageRoot
                    )
                },
                runnerClient: ToolRunnerClient { _ in },
                notificationClient: ToolGenerationNotificationClient { notification in
                    await notificationCapture.record(notification)
                }
            )
        )
        store.prompt = "Build a late finishing create"
        store.startPromptSubmission(modelContext: context, inferenceStore: inferenceStore)

        await gate.waitForStart()
        let lateAttachmentURL = root.appendingPathComponent("late.txt")
        try Data("late".utf8).write(to: lateAttachmentURL)
        store.addAttachments(from: [lateAttachmentURL])
        #expect(store.attachments.isEmpty)
        store.cancelGeneration()
        await gate.release()
        await Self.waitForIdle(store)

        let tool = try #require(try context.fetch(FetchDescriptor<StoredTool>()).first)
        #expect(tool.generationState == .ready)
        #expect(tool.generationPhase == .completed)
        #expect(tool.generationMode == nil)
        #expect(tool.pendingPrompt == nil)
        #expect(store.presentedErrorMessage == nil)
        #expect(await notificationCapture.recorded().isEmpty)
    }

    @MainActor
    @Test
    func toolLibraryStoreKeepsLateCanceledSuccessfulResumeReady() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let inferenceStore = InferenceStore(
            dependencies: Self.inferenceDependencies(),
            appleFoundationModelPreferenceStore: try Self.appleFoundationModelPreferenceStore()
        )
        await inferenceStore.loadIfNeeded(modelContext: context)

        let packageRoot = root.appendingPathComponent("LateResume", isDirectory: true)
        let tool = StoredTool(
            name: "Late Resume",
            executableName: "LateResume",
            packageRootPath: packageRoot.path,
            generationState: .stopped,
            generationPhase: .generatingSource,
            generationMode: .create,
            pendingPrompt: "Resume a late finishing app"
        )
        context.insert(tool)
        try context.save()

        let gate = LateGenerationCompletionGate()
        let store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: ToolGenerationClient { request in
                    await gate.startAndWaitForRelease()
                    return ToolGenerationResult(
                        toolName: "Late Resume",
                        executableName: "LateResume",
                        settings: request.settings,
                        packageRootURL: packageRoot
                    )
                },
                runnerClient: ToolRunnerClient { _ in }
            )
        )
        store.continueGeneration(tool, modelContext: context, inferenceStore: inferenceStore)

        await gate.waitForStart()
        store.cancelGeneration()
        await gate.release()
        await Self.waitForIdle(store)

        #expect(tool.generationState == .ready)
        #expect(tool.generationPhase == .completed)
        #expect(tool.generationMode == nil)
        #expect(tool.pendingPrompt == nil)
        #expect(store.presentedErrorMessage == nil)
    }

    @MainActor
    @Test
    func successfulAutoRemixCompactsPendingContextAndPersistsRelationships() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let inferenceStore = InferenceStore(
            dependencies: Self.inferenceDependencies(),
            appleFoundationModelPreferenceStore: try Self.appleFoundationModelPreferenceStore()
        )
        await inferenceStore.loadIfNeeded(modelContext: context)

        let packageRoot = root.appendingPathComponent("AutoRemix", isDirectory: true)
        let snapshot = StoreRemixTestFixture.snapshot()
        let store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: ToolGenerationClient { request in
                    #expect(request.storeAssistedGenerationEnabled)
                    try await request.lifecycle.prepareCreatedTool(
                        ToolGenerationPreparedTool(
                            name: "Auto Remix",
                            executableName: "AutoRemix",
                            bundleIdentifier: ToolBundleIdentifier.make(
                                executableName: "AutoRemix"
                            ),
                            settings: request.settings,
                            packageRootURL: packageRoot
                        ),
                        request.prompt
                    )
                    try ToolStoreRemixStateClient.live.stage(snapshot, packageRoot)
                    try await request.lifecycle.updateStoreGenerationContext(snapshot)
                    return ToolGenerationResult(
                        toolName: "Auto Remix",
                        executableName: "AutoRemix",
                        settings: request.settings,
                        packageRootURL: packageRoot
                    )
                },
                runnerClient: ToolRunnerClient { _ in }
            )
        )
        inferenceStore.generationPreferences.autoRemixEnabled = true
        store.prompt = snapshot.originalPrompt

        await store.submitPrompt(
            modelContext: context,
            inferenceStore: inferenceStore,
            storeAssistedGenerationAvailable: true
        )

        let tool = try #require(try context.fetch(FetchDescriptor<StoredTool>()).first)
        #expect(tool.generationState == .ready)
        #expect(!store.isActivelyRemixingFromStore(tool))
        #expect(tool.storeRemixSource?.storeId == snapshot.plan.base?.storeId)
        #expect(tool.storeRemixSource?.appId == snapshot.plan.base?.appId)
        #expect(tool.storeRemixSource?.versionId == snapshot.plan.base?.versionId)
        #expect(tool.storeAttributionVersionIds == snapshot.plan.inspirations.map(\.versionId))
        #expect(try ToolStoreRemixStateClient.live.pendingContext(packageRoot) == nil)
        #expect(tool.storeRemixSource?.appName == "Simple Timer")
        #expect(
            tool.storeInspirationLinks.compactMap(\.appName)
                == ["Preset Timer", "Sound Timer"]
        )
    }

    @MainActor
    @Test
    func toolLibraryResumeKeepsNewAttachmentsQueuedForNextRun() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let attachmentURL = root.appendingPathComponent("next-run.txt")
        try Data("next run".utf8).write(to: attachmentURL)

        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let inferenceStore = InferenceStore(
            dependencies: Self.inferenceDependencies(),
            appleFoundationModelPreferenceStore: try Self.appleFoundationModelPreferenceStore()
        )
        await inferenceStore.loadIfNeeded(modelContext: context)

        let packageRoot = root.appendingPathComponent("Paused", isDirectory: true)
        let layout = ToolPackageLayout(packageRootURL: packageRoot, executableName: "Paused")
        _ = try ToolPromptAttachmentStorage.live.replaceCurrentRun(
            [
                ToolPromptAttachment(
                    fileName: "current-run.txt",
                    kind: .file,
                    data: Data("current".utf8)
                )
            ],
            layout
        )
        let tool = StoredTool(
            name: "Paused",
            executableName: "Paused",
            packageRootPath: packageRoot.path,
            generationState: .stopped,
            generationPhase: .generatingSource,
            generationMode: .create,
            pendingPrompt: "Continue the current run"
        )
        context.insert(tool)
        try context.save()

        let capture = ResumeAttachmentCapture()
        let gate = LateGenerationCompletionGate()
        let store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: ToolGenerationClient { request in
                    await capture.record(request.attachments)
                    await gate.startAndWaitForRelease()
                    return ToolGenerationResult(
                        toolName: tool.name,
                        executableName: tool.executableName,
                        settings: request.settings,
                        packageRootURL: packageRoot
                    )
                },
                runnerClient: ToolRunnerClient { _ in }
            )
        )
        store.addAttachments(from: [attachmentURL])

        store.continueGeneration(tool, modelContext: context, inferenceStore: inferenceStore)
        await gate.waitForStart()
        #expect(await capture.attachmentCount == 0)
        await gate.release()
        await Self.waitForIdle(store)

        #expect(store.attachments.count == 1)
        #expect(store.attachments.first?.fileName == "next-run.txt")
        #expect(tool.generationState == .ready)
        #expect(!FileManager.default.fileExists(atPath: layout.currentRunAttachmentsDirectoryURL.path))
    }

    @MainActor
    @Test
    func toolLibraryStoreShowsNoModelMessageWhenGenerationHasNoSelectedModel() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let inferenceStore = InferenceStore(dependencies: Self.inferenceDependencies())
        let store = ToolLibraryStore()
        store.prompt = "Build a notes tool"

        await store.submitPrompt(modelContext: context, inferenceStore: inferenceStore)

        #expect(store.presentedErrorMessage == InferenceMessages.noAvailableModels)
        #expect(store.presentedErrorAction == nil)
        #expect(!(store.isGenerating))
    }

    @MainActor
    @Test
    func toolLibraryStoreOffersCreditPurchaseWhenIronsmithCreditsAreExhausted() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let provider = ProviderCatalog.makeProvider(for: .ironsmith)!
        let model = ModelConfig(
            identifier: "openai/gpt-5.4",
            displayName: "GPT 5.4",
            providerIdentifier: provider.identifier,
            source: .remote,
            installState: .installed
        )
        let inferenceStore = InferenceStore(
            dependencies: Self.inferenceDependencies(
                accountClient: Self.ironsmithAccountClient(balanceCredits: 0)
            )
        )
        inferenceStore.providers = [provider]
        inferenceStore.remoteModels = [model]
        inferenceStore.selectedModelID = model.selectionIdentifier

        let store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: ToolGenerationClient { _ in
                    Issue.record("Generation should not start without credits.")
                    throw CancellationError()
                },
                runnerClient: ToolRunnerClient { _ in }
            )
        )
        store.prompt = "Build a dashboard"

        await store.submitPrompt(modelContext: context, inferenceStore: inferenceStore)

        #expect(store.presentedErrorMessage == InferenceStoreError.insufficientIronsmithCredits.localizedDescription)
        #expect(store.presentedErrorAction == ToolLibraryPresentedErrorAction.buyIronsmithCredits)
        #expect(!(store.isGenerating))
    }

    @MainActor
    @Test
    func toolLibraryStoreRewritesGenericAnyLanguageModelGenerationErrors() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let provider = ProviderCatalog.makeProvider(for: .ironsmith)!
        let model = ModelConfig(
            identifier: "openai/gpt-5.4",
            displayName: "GPT 5.4",
            providerIdentifier: provider.identifier,
            source: .remote,
            installState: .installed
        )
        let preferences = GenerationPreferencesStore(userDefaults: try Self.makeIsolatedUserDefaults())
        preferences.codingAgentPreference = .ironsmithFlame
        let inferenceStore = InferenceStore(
            dependencies: Self.inferenceDependencies(
                accountClient: Self.ironsmithAccountClient(balanceCredits: 12)
            ),
            generationPreferences: preferences
        )
        inferenceStore.providers = [provider]
        inferenceStore.remoteModels = [model]
        inferenceStore.selectedModelID = model.selectionIdentifier

        let store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: ToolGenerationClient { _ in
                    throw NSError(domain: "AnyLanguageModel.AnyLanguageModelError", code: 0)
                },
                runnerClient: ToolRunnerClient { _ in }
            )
        )
        store.prompt = "Build a dashboard"

        await store.submitPrompt(modelContext: context, inferenceStore: inferenceStore)

        #expect(store.presentedErrorMessage == "There was an error generating your app. Please try again.")
        #expect(store.presentedErrorAction == nil)
        #expect(!(store.isGenerating))
    }

    @Test
    func toolRowStatusUsesCodexWorkingTextOnlyForCodexOwnedPhases() {
        #expect(
            ToolRowGenerationStatusResolver.statusText(
                phase: .planning,
                repairErrorCount: nil,
                activeCodingAgent: nil
            ) == "Generating metadata"
        )
        #expect(
            ToolRowGenerationStatusResolver.statusText(
                phase: .generatingSource,
                repairErrorCount: nil,
                activeCodingAgent: .codex
            ) == "Agent is working"
        )
        #expect(
            ToolRowGenerationStatusResolver.statusText(
                phase: .generatingEditDiff,
                repairErrorCount: nil,
                activeCodingAgent: .codex
            ) == "Agent is working"
        )
        #expect(
            ToolRowGenerationStatusResolver.statusText(
                phase: .generatingRepairDiff,
                repairErrorCount: 2,
                activeCodingAgent: .codex
            ) == "Agent is working"
        )
        #expect(
            ToolRowGenerationStatusResolver.statusText(
                phase: .repairing,
                repairErrorCount: 2,
                activeCodingAgent: .codex
            ) == "Agent is working"
        )
        #expect(
            ToolRowGenerationStatusResolver.statusText(
                phase: .packaging,
                repairErrorCount: nil,
                activeCodingAgent: .codex
            ) == "Packaging"
        )
        #expect(
            ToolRowGenerationStatusResolver.statusText(
                phase: .generatingSource,
                repairErrorCount: nil,
                activeCodingAgent: .ironsmithFlame
            ) == "Generating source"
        )
        #expect(
            ToolRowGenerationStatusResolver.statusText(
                phase: .repairing,
                repairErrorCount: 2,
                activeCodingAgent: nil
            ) == "Repairing 2 errors"
        )
    }

    @MainActor
    @Test
    func toolLibraryStoreEnablesAgentOutputForExistingCodexTranscript() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageRoot = root.appendingPathComponent("TranscriptTool", isDirectory: true)
        let transcriptDirectory = CodexAgentTranscriptReader.transcriptDirectoryURL(for: packageRoot)
        try FileManager.default.createDirectory(at: transcriptDirectory, withIntermediateDirectories: true)
        let tool = StoredTool(
            name: "Transcript Tool",
            executableName: "TranscriptTool",
            packageRootPath: packageRoot.path
        )
        let store = ToolLibraryStore()

        #expect(!store.canShowAgentOutput(for: tool))

        try #"{"type":"thread.started","thread_id":"thread-1"}"#
            .write(
                to: transcriptDirectory.appendingPathComponent("agent-test.jsonl"),
                atomically: true,
                encoding: .utf8
            )

        #expect(store.canShowAgentOutput(for: tool))
    }

    @MainActor
    @Test
    func toolLibraryStoreTracksActiveCodexAgentDuringCreateGeneration() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let preferences = GenerationPreferencesStore(userDefaults: try Self.makeIsolatedUserDefaults())
        preferences.codingAgentPreference = .codex
        let inferenceStore = InferenceStore(
            dependencies: Self.inferenceDependencies(),
            generationPreferences: preferences,
            appleFoundationModelPreferenceStore: try Self.appleFoundationModelPreferenceStore()
        )
        let provider = ProviderCatalog.makeProvider(for: .openAI)!
        let model = ModelConfig(
            identifier: "codex:gpt-5.5",
            displayName: "GPT-5.5 (Codex)",
            providerIdentifier: provider.identifier,
            source: .remote,
            installState: .installed
        )
        inferenceStore.providers = [provider]
        inferenceStore.remoteModels = [model]
        inferenceStore.selectedModelID = model.selectionIdentifier

        let packageRoot = root.appendingPathComponent("ActiveCodex", isDirectory: true)
        let capture = ToolLibraryActiveAgentCapture()
        var store: ToolLibraryStore!
        store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: ToolGenerationClient { request in
                    try await request.lifecycle.prepareCreatedTool(
                        ToolGenerationPreparedTool(
                            name: "Active Codex",
                            executableName: "ActiveCodex",
                            bundleIdentifier: ToolBundleIdentifier.make(executableName: "ActiveCodex"),
                            settings: request.settings,
                            packageRootURL: packageRoot
                        ),
                        request.prompt
                    )
                    await capture.record(
                        store.activeCodingAgentByToolID.values.contains(.codex)
                    )
                    return ToolGenerationResult(
                        toolName: "Active Codex",
                        executableName: "ActiveCodex",
                        settings: request.settings,
                        packageRootURL: packageRoot
                    )
                },
                runnerClient: ToolRunnerClient { _ in }
            )
        )
        store.prompt = "Build with Codex"

        await store.submitPrompt(modelContext: context, inferenceStore: inferenceStore)

        #expect(await capture.sawActiveCodex)
        #expect(store.activeCodingAgentByToolID.isEmpty)
    }

    @MainActor
    @Test
    func toolLibraryStoreRefreshesIronsmithCreditsAfterEachModelInvocation() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let provider = ProviderCatalog.makeProvider(for: .ironsmith)!
        let model = ModelConfig(
            identifier: "openai/gpt-5.4",
            displayName: "GPT 5.4",
            providerIdentifier: provider.identifier,
            source: .remote,
            installState: .installed
        )
        let preferences = GenerationPreferencesStore(userDefaults: try Self.makeIsolatedUserDefaults())
        preferences.codingAgentPreference = .ironsmithFlame
        let accountCapture = IronsmithAccountFetchCapture(balances: [100, 91, 84, 84])
        let inferenceStore = InferenceStore(
            dependencies: Self.inferenceDependencies(
                accountClient: Self.ironsmithAccountClient(fetchCapture: accountCapture)
            ),
            generationPreferences: preferences
        )
        inferenceStore.providers = [provider]
        inferenceStore.remoteModels = [model]
        inferenceStore.selectedModelID = model.selectionIdentifier

        let packageRoot = URL(fileURLWithPath: "/tmp/ironsmith-credit-refresh", isDirectory: true)
        let store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: ToolGenerationClient { request in
                    try await request.lifecycle.prepareCreatedTool(
                        ToolGenerationPreparedTool(
                            name: "Credit Tool",
                            executableName: "CreditTool",
                            bundleIdentifier: ToolBundleIdentifier.make(executableName: "CreditTool"),
                            settings: request.settings,
                            packageRootURL: packageRoot
                        ),
                        request.prompt
                    )
                    await request.languageModelContext.languageModelInvoker.recordInvocationCompleted()
                    await request.languageModelContext.languageModelInvoker.recordInvocationCompleted()
                    return ToolGenerationResult(
                        toolName: "Credit Tool",
                        executableName: "CreditTool",
                        settings: request.settings,
                        packageRootURL: packageRoot
                    )
                },
                runnerClient: ToolRunnerClient { _ in }
            )
        )
        store.prompt = "Build a credit watching tool"

        await store.submitPrompt(modelContext: context, inferenceStore: inferenceStore)

        #expect(await accountCapture.fetchCount == 4)
        #expect(inferenceStore.ironsmithAccountSummary?.credits.balanceCredits == 84)
        #expect(store.presentedErrorMessage == nil)
        #expect(!(store.isGenerating))
    }

    @MainActor
    @Test
    func toolLibraryStoreNotifiesWhenGenerationFinishes() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let inferenceStore = InferenceStore(
            dependencies: Self.inferenceDependencies(),
            appleFoundationModelPreferenceStore: try Self.appleFoundationModelPreferenceStore()
        )
        await inferenceStore.loadIfNeeded(modelContext: context)

        let packageRoot = root.appendingPathComponent("FinishedTool", isDirectory: true)
        let notificationCapture = ToolGenerationNotificationCapture()
        let store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: ToolGenerationClient { request in
                    try await request.lifecycle.prepareCreatedTool(
                        ToolGenerationPreparedTool(
                            name: "Finished Tool",
                            executableName: "FinishedTool",
                            bundleIdentifier: ToolBundleIdentifier.make(executableName: "FinishedTool"),
                            settings: request.settings,
                            packageRootURL: packageRoot
                        ),
                        request.prompt
                    )
                    return ToolGenerationResult(
                        toolName: "Finished Tool",
                        executableName: "FinishedTool",
                        settings: request.settings,
                        packageRootURL: packageRoot
                    )
                },
                runnerClient: ToolRunnerClient { _ in },
                notificationClient: ToolGenerationNotificationClient { notification in
                    await notificationCapture.record(notification)
                }
            )
        )
        store.prompt = "Build a finished tool"

        await store.submitPrompt(modelContext: context, inferenceStore: inferenceStore)

        let notifications = await notificationCapture.recorded()
        #expect(
            notifications == [
                ToolGenerationNotification(
                    kind: .finished,
                    toolName: "Finished Tool",
                    detail: nil
                )
            ]
        )
    }

    @MainActor
    @Test
    func toolLibraryStoreDoesNotNotifyWhenGenerationFinishesWhilePopoverIsVisible() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let inferenceStore = InferenceStore(
            dependencies: Self.inferenceDependencies(),
            appleFoundationModelPreferenceStore: try Self.appleFoundationModelPreferenceStore()
        )
        await inferenceStore.loadIfNeeded(modelContext: context)

        let packageRoot = root.appendingPathComponent("VisibleTool", isDirectory: true)
        let notificationCapture = ToolGenerationNotificationCapture()
        let store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: ToolGenerationClient { request in
                    try await request.lifecycle.prepareCreatedTool(
                        ToolGenerationPreparedTool(
                            name: "Visible Tool",
                            executableName: "VisibleTool",
                            bundleIdentifier: ToolBundleIdentifier.make(executableName: "VisibleTool"),
                            settings: request.settings,
                            packageRootURL: packageRoot
                        ),
                        request.prompt
                    )
                    return ToolGenerationResult(
                        toolName: "Visible Tool",
                        executableName: "VisibleTool",
                        settings: request.settings,
                        packageRootURL: packageRoot
                    )
                },
                runnerClient: ToolRunnerClient { _ in },
                notificationClient: ToolGenerationNotificationClient { notification in
                    await notificationCapture.record(notification)
                }
            )
        )
        store.setPopoverVisible(true)
        store.prompt = "Build a visible tool"

        await store.submitPrompt(modelContext: context, inferenceStore: inferenceStore)

        #expect(await notificationCapture.recorded().isEmpty)
    }

    @MainActor
    @Test
    func toolLibraryStorePresentsMessageForResumableTokenStop() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let inferenceStore = InferenceStore(
            dependencies: Self.inferenceDependencies(),
            appleFoundationModelPreferenceStore: try Self.appleFoundationModelPreferenceStore()
        )
        await inferenceStore.loadIfNeeded(modelContext: context)

        let packageRoot = root.appendingPathComponent("TokenStop", isDirectory: true)
        let message = "Stopped after 6 repair attempts preserve tokens. Continue to keep repairing from current source."
        let tool = StoredTool(
            name: "Token Stop",
            executableName: "TokenStop",
            packageRootPath: packageRoot.path,
            generationState: .stopped,
            generationPhase: .generatingRepairDiff,
            generationMode: .edit,
            pendingPrompt: "Continue repairing"
        )
        context.insert(tool)
        try context.save()

        let gate = LateGenerationCompletionGate()
        let notificationCapture = ToolGenerationNotificationCapture()
        let store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: ToolGenerationClient { _ in
                    await gate.startAndWaitForRelease()
                    throw ToolGenerationError.stoppedToSaveTokens(message)
                },
                runnerClient: ToolRunnerClient { _ in },
                notificationClient: ToolGenerationNotificationClient { notification in
                    await notificationCapture.record(notification)
                }
            )
        )

        store.continueGeneration(tool, modelContext: context, inferenceStore: inferenceStore)
        await gate.waitForStart()
        await gate.release()
        await Self.waitForIdle(store)

        #expect(tool.generationState == .stopped)
        #expect(tool.generationErrorSummary == message)
        #expect(store.presentedErrorMessage == message)
        #expect(store.presentedErrorAction == nil)
        #expect(
            await notificationCapture.recorded() == [
                ToolGenerationNotification(
                    kind: .stopped,
                    toolName: "Token Stop",
                    detail: message
                )
            ]
        )
    }
}

private actor ToolGenerationNotificationCapture {
    private var notifications: [ToolGenerationNotification] = []

    func record(_ notification: ToolGenerationNotification) {
        notifications.append(notification)
    }

    func recorded() -> [ToolGenerationNotification] {
        notifications
    }
}

private actor ResumeAttachmentCapture {
    private(set) var attachmentCount = -1

    func record(_ attachments: [ToolPromptAttachment]) {
        attachmentCount = attachments.count
    }
}

private actor ToolLibraryActiveAgentCapture {
    private(set) var sawActiveCodex = false

    func record(_ isActiveCodex: Bool) {
        sawActiveCodex = sawActiveCodex || isActiveCodex
    }
}

private actor LateGenerationCompletionGate {
    private var isStarted = false
    private var isReleased = false
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func startAndWaitForRelease() async {
        isStarted = true
        startContinuations.forEach { $0.resume() }
        startContinuations.removeAll()

        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitForStart() async {
        guard !isStarted else { return }
        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

extension ToolLibraryTests {
    @MainActor
    @Test
    func toolLibraryCodingAgentContextCountsExistingEditSourceLines() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = Tool(
            name: "Large Editor",
            executableName: "LargeEditor",
            packageRootPath: root.path
        )
        let contentViewURL = try ToolPackageLayout.packageFileURL(
            for: tool.contentViewSourcePath,
            packageRootURL: root
        )
        try FileManager.default.createDirectory(
            at: contentViewURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let store = ToolLibraryStore()

        try Array(repeating: "line", count: 600)
            .joined(separator: "\n")
            .appending("\n")
            .write(to: contentViewURL, atomically: true, encoding: .utf8)
        let sixHundred = store.codingAgentResolutionContext(
            for: tool,
            generationMode: .edit
        )
        #expect(sixHundred.existingSourceLineCount == 600)
        #expect(!sixHundred.isLargeEdit)

        try Array(repeating: "line", count: 601)
            .joined(separator: "\n")
            .appending("\n")
            .write(to: contentViewURL, atomically: true, encoding: .utf8)
        let sixHundredOne = store.codingAgentResolutionContext(
            for: tool,
            generationMode: .edit
        )
        #expect(sixHundredOne.existingSourceLineCount == 601)
        #expect(sixHundredOne.isLargeEdit)
    }

    @MainActor
    static func waitForIdle(_ store: ToolLibraryStore) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while store.isGenerating && DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
