import AnyLanguageModel
import Foundation
import Testing

@testable import Ironsmith

@Suite("Store app questions")
struct StoreAppQuestionTests {
    @MainActor
    @Test
    func questionStreamsAnAnswerUsingTheCompleteCurrentSource() async throws {
        let promptCapture = PromptCapture()
        let inferenceStore = Self.inferenceStore(
            languageModel: StubAgentLanguageModel { prompt, _ in
                await promptCapture.record(prompt)
                return "It shows a greeting in a SwiftUI window."
            }
        )
        let source = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                Text("Complete source marker")
            }
        }
        """
        let app = Self.app(sourceCode: source)
        let sourceStore = StoreAppSourceStore(
            exportClient: StoreSourceCodeExportClient(openSource: { _ in })
        )
        let questionStore = StoreAppQuestionStore()
        questionStore.question = "What does this app show?"

        questionStore.ask(
            about: app,
            sourceStore: sourceStore,
            loadCurrentSource: { source },
            inferenceStore: inferenceStore
        )

        await Self.waitForAnswer(in: questionStore)

        #expect(questionStore.answer == "It shows a greeting in a SwiftUI window.")
        #expect(questionStore.errorMessage == nil)
        #expect(sourceStore.sourceCode == source)
        let prompt = try #require(await promptCapture.prompts.first)
        #expect(prompt.contains(source))
        #expect(prompt.contains("What does this app show?"))
    }

    @MainActor
    @Test
    func questionReportsWhenTheModelExceedsItsContextWindow() async throws {
        let inferenceStore = Self.inferenceStore(
            languageModel: StubAgentLanguageModel { _, _ in
                throw FakeAgentError.contextWindow
            }
        )
        let source = "struct ContentView { let marker = \"complete source\" }"
        let app = Self.app(sourceCode: source)
        let sourceStore = StoreAppSourceStore(
            exportClient: StoreSourceCodeExportClient(openSource: { _ in })
        )
        let questionStore = StoreAppQuestionStore()
        questionStore.question = "What does this do?"

        questionStore.ask(
            about: app,
            sourceStore: sourceStore,
            loadCurrentSource: { source },
            inferenceStore: inferenceStore
        )

        await Self.waitForAnswer(in: questionStore)

        #expect(questionStore.answer.isEmpty)
        #expect(
            questionStore.errorMessage
                == StoreAppQuestionError.sourceExceedsContextWindow.errorDescription
        )
    }

    @MainActor
    @Test
    func questionIncludesLicenseAndRemixProvenance() async throws {
        let promptCapture = PromptCapture()
        let inferenceStore = Self.inferenceStore(
            languageModel: StubAgentLanguageModel { prompt, _ in
                await promptCapture.record(prompt)
                return "The inherited terms are preserved."
            }
        )
        let source = "struct ContentView { var body: some View { Text(\"Hello\") } }"
        let app = Self.app(
            sourceCode: source,
            legalAttributions: [
                StoreLegalAttribution(
                    versionId: "parent-version",
                    appName: "Original Greeting",
                    creatorHandle: "original",
                    creatorDisplayName: "Original Creator",
                    publicationYear: 2025,
                    license: .apache2
                )
            ],
            remix: StoreVersionLinkMetadata(
                storeId: "00000000-0000-4000-8000-000000000011",
                appId: "00000000-0000-4000-8000-000000000102",
                appName: "Original Greeting",
                versionId: "parent-version",
                versionNumber: 4
            )
        )
        let sourceStore = StoreAppSourceStore(
            exportClient: StoreSourceCodeExportClient(openSource: { _ in })
        )
        let questionStore = StoreAppQuestionStore()
        questionStore.question = "What terms apply?"

        questionStore.ask(
            about: app,
            sourceStore: sourceStore,
            loadCurrentSource: { source },
            inferenceStore: inferenceStore
        )

        await Self.waitForAnswer(in: questionStore)

        let prompt = try #require(await promptCapture.prompts.first)
        #expect(prompt.contains("Direct remix ancestry: Original Greeting, Store version 4"))
        #expect(prompt.contains("Original Greeting: Copyright 2025 @original · Apache License 2.0"))
    }

    @Test
    func sharedMarkdownParserPreservesWhitespaceAndRendersInlineMarkdown() {
        let rendered = IronsmithMarkdown.attributedString("### Details\n\n- **Important** with `code`")
        let plainText = String(rendered.characters)

        #expect(plainText == "### Details\n\n- Important with code")
    }

    @MainActor
    private static func inferenceStore(
        languageModel: any LanguageModel
    ) -> InferenceStore {
        var dependencies = InferenceTests.dependencies()
        dependencies.languageModelClient = LanguageModelClient(
            makeLanguageModel: { _, _ in languageModel }
        )
        let preferences = InferenceTests.generationPreferences()
        preferences.codingAgentPreference = .ironsmithFlame
        let store = InferenceStore(
            dependencies: dependencies,
            generationPreferences: preferences,
            modelSelection: InferenceTests.modelSelection(),
            appleFoundationModelPreferenceStore: InferenceTests.appleFoundationModelPreferenceStore()
        )
        let provider = ProviderCatalog.makeProvider(for: .openAI)!
        let model = ModelConfig(
            identifier: "store-question-test",
            displayName: "Store Question Test",
            providerIdentifier: provider.identifier,
            source: .remote,
            installState: .installed
        )
        store.providers = [provider]
        store.remoteModels = [model]
        store.selectedModelID = model.selectionIdentifier
        return store
    }

    private static func app(
        sourceCode: String,
        legalAttributions: [StoreLegalAttribution] = [],
        remix: StoreVersionLinkMetadata? = nil
    ) -> StoreAppDetail {
        let appID = "00000000-0000-4000-8000-000000000101"
        let version = StoreVersionMetadata(
            id: "00000000-0000-4000-8000-000000000201",
            appId: appID,
            versionNumber: 1,
            sourceSha256: IronsmithStoreClient.sha256Hex(for: sourceCode),
            generationSettings: StoreGenerationSettingsDTO(settings: .default),
            runtimeVersion: "ironsmith-macos-v1",
            license: .mit,
            legalAttributions: legalAttributions,
            remixedFromVersionId: nil,
            publishedAt: "2026-06-27T00:00:00.000Z"
        )
        return StoreAppDetail(
            id: appID,
            storeId: "00000000-0000-4000-8000-000000000011",
            storeVisibility: "public",
            authorDisplayName: "Jade",
            authorHandle: "jade",
            name: "Greeting",
            shortDescription: "A greeting app",
            description: "Shows a greeting.",
            category: .utilities,
            status: .published,
            publishedAt: "2026-06-27T00:00:00.000Z",
            createdAt: "2026-06-27T00:00:00.000Z",
            updatedAt: "2026-06-27T00:00:00.000Z",
            icon: nil,
            iconMaster: nil,
            screenshots: [],
            currentVersion: version,
            versions: [version],
            remix: remix,
            inspirations: []
        )
    }

    @MainActor
    private static func waitForAnswer(in store: StoreAppQuestionStore) async {
        for _ in 0..<100 {
            if !store.isAnswering { return }
            await Task.yield()
        }
    }
}
