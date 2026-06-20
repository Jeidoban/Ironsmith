import AnyLanguageModel
import Foundation
import ImageIO
import SwiftData
import Testing
@testable import Ironsmith

extension AgentPipelineTests {
    @MainActor
    @Test
    func generatedMetadataSchemaIncludesNameIconAndMenuBarSymbolOnly() throws {
        let data = try JSONEncoder().encode(GeneratedToolMetadata.generationSchema)
        let schema = try #require(String(data: data, encoding: .utf8))

        #expect(schema.contains("displayName"))
        #expect(schema.contains("iconPrompt"))
        #expect(schema.contains("menuBarSystemImage"))
        #expect(!(schema.contains("refinedPrompt")))
    }

    @MainActor
    @Test
    func liveMetadataClientUsesStructuredGenerationForNameAndIcon() async throws {
        let metadata = GeneratedToolMetadata(
            displayName: "Recipe Board",
            iconPrompt: "Recipe cards"
        )
        let response = StructuredMetadataResponse(metadata: metadata)

        let suggestion = await ToolMetadataClient.live().suggestMetadata(
            userPrompt: "recipes",
            languageModel: StructuredMetadataLanguageModel(response: response),
            generationOptions: GenerationOptions(maximumResponseTokens: 4096)
        )

        #expect(suggestion.displayName == "Recipe Board")
        #expect(suggestion.iconPrompt == "Recipe cards")
        #expect(suggestion.menuBarSystemImage == ToolMenuBarSymbol.fallback)
        let prompt = try #require(await response.prompts.first)
        #expect(prompt.contains("User request:\nrecipes"))
        #expect(prompt.contains("Allowed menuBarSystemImage values:"))
        #expect(!(prompt.contains("Planning budget:")))
        #expect(!(prompt.contains("Refined prompt:")))
        #expect(!(prompt.contains("backend")))
        #expect(await response.options.first?.maximumResponseTokens == 4096)
    }

    @MainActor
    @Test
    func metadataSuggestionValidatesMenuBarSymbolAgainstAllowlist() async throws {
        let response = StructuredMetadataResponse(
            metadata: GeneratedToolMetadata(
                displayName: "Timer",
                iconPrompt: "Small timer",
                menuBarSystemImage: "not.a.real.allowed.symbol"
            )
        )

        let suggestion = await ToolMetadataClient.live().suggestMetadata(
            userPrompt: "Build a timer",
            languageModel: StructuredMetadataLanguageModel(response: response),
            generationOptions: GenerationOptions(maximumResponseTokens: 4096)
        )

        #expect(suggestion.menuBarSystemImage == ToolMenuBarSymbol.fallback)
    }

    @MainActor
    @Test
    func liveMetadataClientFallsBackWhenStructuredGenerationFails() async throws {
        let response = StructuredMetadataResponse(error: FakeAgentError.expected)

        let suggestion = await ToolMetadataClient.live().suggestMetadata(
            userPrompt: "Build a pantry tracker",
            languageModel: StructuredMetadataLanguageModel(response: response),
            generationOptions: GenerationOptions(maximumResponseTokens: 4096)
        )

        #expect(suggestion.displayName == "Build A Pantry Tracker")
        #expect(suggestion.iconPrompt == "")
    }

    @MainActor
    @Test
    func livePromptRefinementClientUsesPlainTextSelectedModel() async throws {
        let promptCapture = PromptCapture()
        let optionsCapture = GenerationOptionsCapture()
        let refinedPrompt = "Build a first-version local macOS pantry tracker with a searchable list, editable item details, and expiry highlights."
        let refined = await ToolPromptRefinementClient.live().refinePrompt(
            userPrompt: "Build a pantry tracker",
            languageModel: StubAgentLanguageModel { prompt, options in
                await promptCapture.record(prompt)
                await optionsCapture.record(options)
                return refinedPrompt
            },
            generationOptions: GenerationOptions(maximumResponseTokens: 4096),
            sandboxEnabled: false
        )

        #expect(refined == refinedPrompt)
        let prompt = try #require(await promptCapture.prompts.first)
        #expect(prompt.contains("User request:\nBuild a pantry tracker"))
        #expect(prompt.contains("App sandbox: disabled."))
        #expect(prompt.contains("must not make changes to the user's system unless the user asks"))
        #expect(prompt.contains("Return a plain text prompt"))
        #expect(await optionsCapture.options.first?.maximumResponseTokens == 1000)
    }

    @MainActor
    @Test
    func livePromptRefinementClientFallsBackToOriginalPromptOnFailure() async throws {
        let refined = await ToolPromptRefinementClient.live().refinePrompt(
            userPrompt: "Build a pantry tracker",
            languageModel: EmptyLanguageModel(),
            generationOptions: GenerationOptions(maximumResponseTokens: 4096)
        )

        #expect(refined == nil)
    }

    @MainActor
    @Test
    func createModeUsesRefinedPromptForContentViewGenerationWhenEnabled() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let refinedPrompt = "Build a timer dashboard with preset chips, a large active countdown, start pause reset controls, and a clear completed state."
        let promptCapture = PromptCapture()
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { prompt, _ in
                await promptCapture.record(prompt)
                return Self.simpleContentViewSource(text: "refined prompt")
            },
            generationOptions: GenerationOptions(),
            repairStrategy: .deterministicOnly,
            toolsDirectoryURL: toolsDirectory,
            processClient: Self.successfulProcessClient(),
            metadataClient: ToolMetadataClient { _ in
                ToolMetadataSuggestion(
                    displayName: "Timer Desk",
                    iconPrompt: ""
                )
            },
            promptRefinementClient: ToolPromptRefinementClient { _ in
                refinedPrompt
            }
        )

        _ = try await runtime.generateTool(for: "Make a timer", status: { _ in })

        let prompts = await promptCapture.prompts
        #expect(prompts.first?.contains(refinedPrompt) == true)
        #expect(!(prompts.first?.contains("User request: Make a timer") ?? false))
    }

    @MainActor
    @Test
    func createModeUsesOriginalPromptWhenRefinementIsDisabled() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let refinedPrompt = "Build a refined habit planner with analytics and polished empty states."
        let promptCapture = PromptCapture()
        let promptRefinementCapture = InvocationCapture()
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { prompt, _ in
                await promptCapture.record(prompt)
                return Self.simpleContentViewSource(text: "original prompt")
            },
            generationOptions: GenerationOptions(),
            repairStrategy: .deterministicOnly,
            toolsDirectoryURL: toolsDirectory,
            processClient: Self.successfulProcessClient(),
            metadataClient: ToolMetadataClient { _ in
                ToolMetadataSuggestion(
                    displayName: "Habit Desk",
                    iconPrompt: ""
                )
            },
            promptRefinementClient: ToolPromptRefinementClient { _ in
                await promptRefinementCapture.record()
                return refinedPrompt
            },
            promptRefinementEnabled: false
        )

        _ = try await runtime.generateTool(for: "Make a habit tracker", status: { _ in })

        let prompts = await promptCapture.prompts
        #expect(prompts.first?.contains("User request: Make a habit tracker") == true)
        #expect(!(prompts.first?.contains(refinedPrompt) ?? false))
        #expect(await promptRefinementCapture.count == 0)
    }

    @MainActor
    @Test
    func editModeKeepsOriginalPromptAndSkipsMetadataRefinement() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let tool = try Self.makeExistingTool(
            toolsDirectory: toolsDirectory,
            executableName: "EditPrompt",
            source: Self.originalEditableSource
        )
        let promptCapture = PromptCapture()
        let metadataCapture = InvocationCapture()
        let promptRefinementCapture = InvocationCapture()
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { prompt, _ in
                await promptCapture.record(prompt)
                return Self.renameOldToNewDiff
            },
            generationOptions: GenerationOptions(),
            repairStrategy: .modelDiff(maxHunksPerTurn: nil),
            toolsDirectoryURL: toolsDirectory,
            processClient: Self.successfulProcessClient(),
            metadataClient: ToolMetadataClient { _ in
                await metadataCapture.record()
                return ToolMetadataSuggestion(
                    displayName: "Should Not Use",
                    iconPrompt: ""
                )
            },
            promptRefinementClient: ToolPromptRefinementClient { _ in
                await promptRefinementCapture.record()
                return "Rewrite the whole app with unrelated features."
            }
        )

        _ = try await runtime.generateTool(
            for: "Change old to new",
            existingTool: tool,
            status: { _ in }
        )

        let prompts = await promptCapture.prompts
        #expect(prompts.first?.contains("User request: Change old to new") == true)
        #expect(!(prompts.first?.contains("Rewrite the whole app with unrelated features.") ?? false))
        #expect(await metadataCapture.count == 0)
        #expect(await promptRefinementCapture.count == 0)
    }
}
