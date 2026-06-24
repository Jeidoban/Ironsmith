import AnyLanguageModel
import Foundation
import ImageIO
import SwiftData
import Testing
@testable import Ironsmith

extension AgentPipelineTests {
    @MainActor
    @Test
    func toolLibraryStorePersistsOnlyAfterSuccessfulGeneration() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let packageRoot = URL(fileURLWithPath: "/tmp/fake-tool", isDirectory: true)
        let generationCapture = GenerationCapture()
        let generationClient = ToolGenerationClient { request in
            await generationCapture.record(request)
            try await request.lifecycle.prepareCreatedTool(
                ToolGenerationPreparedTool(
                    name: "Fake Tool",
                    executableName: "FakeTool",
                    bundleIdentifier: ToolBundleIdentifier.make(executableName: "FakeTool"),
                    settings: request.settings,
                    packageRootURL: packageRoot
                ),
                request.prompt
            )
            return ToolGenerationResult(
                toolName: "Fake Tool",
                executableName: "FakeTool",
                settings: request.settings,
                packageRootURL: packageRoot
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
        inferenceStore.generationPreferences.generatedAppMicrophoneAccessEnabled = true
        inferenceStore.generationPreferences.generatedAppCameraAccessEnabled = true
        store.prompt = "Build a fake tool"

        await store.submitPrompt(modelContext: context, inferenceStore: inferenceStore)

        let tools = try context.fetch(FetchDescriptor<StoredTool>())
        #expect(tools.count == 1)
        #expect(tools.first?.name == "Fake Tool")
        #expect(tools.first?.packageRootPath == packageRoot.path)
        #expect(store.prompt == "Make a mortgage calculator")
        #expect(!(store.isGenerating))
        #expect(await generationCapture.settings?.sandboxPermissions.enabled == [.internet, .userSelectedFiles])
        #expect(await generationCapture.settings?.resourcePermissions.enabled == [.microphone, .camera])
        #expect(await runCapture.ranToolIDs.isEmpty)

        let failingRunCapture = ToolRunCapture()
        let failingStore = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: ToolGenerationClient { _ in
                    throw FakeAgentError.expected
                },
                runnerClient: ToolRunnerClient { tool in
                    await failingRunCapture.record(tool)
                }
            )
        )
        failingStore.prompt = "Build a failing tool"

        await failingStore.submitPrompt(modelContext: context, inferenceStore: inferenceStore)

        #expect(try context.fetch(FetchDescriptor<StoredTool>()).count == 1)
        #expect(failingStore.presentedErrorMessage != nil)
        #expect(await failingRunCapture.ranToolIDs.isEmpty)
    }
}
