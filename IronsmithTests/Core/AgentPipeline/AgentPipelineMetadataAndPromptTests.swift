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
            invoker: Self.makeInvoker(
                languageModel: StructuredMetadataLanguageModel(response: response),
                generationOptions: GenerationOptions(maximumResponseTokens: 4096)
            )
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
    func liveMetadataClientSelectsConceptOnlyPromptModeForHostedImages() async throws {
        let response = StructuredMetadataResponse(
            metadata: GeneratedToolMetadata(
                displayName: "Mortgage Calc",
                iconPrompt: "A small house sheltering a calculator, with one coin orbiting the roofline."
            )
        )

        _ = await ToolMetadataClient.live().suggestMetadata(
            userPrompt: "Make a mortgage calculator",
            imageGenerationProvider: .openAI,
            invoker: Self.makeInvoker(
                languageModel: StructuredMetadataLanguageModel(response: response),
                generationOptions: GenerationOptions(maximumResponseTokens: 4096)
            )
        )

        let prompt = try #require(await response.prompts.first)
        #expect(prompt.contains("Image prompt mode:\nHosted image generation; visual concept only."))
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
            invoker: Self.makeInvoker(
                languageModel: StructuredMetadataLanguageModel(response: response),
                generationOptions: GenerationOptions(maximumResponseTokens: 4096)
            )
        )

        #expect(suggestion.menuBarSystemImage == ToolMenuBarSymbol.fallback)
    }

    @MainActor
    @Test
    func liveMetadataClientFallsBackWhenStructuredGenerationFails() async throws {
        let response = StructuredMetadataResponse(error: FakeAgentError.expected)

        let suggestion = await ToolMetadataClient.live(fallbackLanguageModel: nil).suggestMetadata(
            userPrompt: "Build a pantry tracker",
            invoker: Self.makeInvoker(
                languageModel: StructuredMetadataLanguageModel(response: response),
                generationOptions: GenerationOptions(maximumResponseTokens: 4096)
            )
        )

        #expect(suggestion.displayName == "Build A Pantry Tracker")
        #expect(suggestion.iconPrompt == "")
    }

    @MainActor
    @Test
    func liveMetadataClientUsesSystemModelAfterSelectedModelFails() async throws {
        let primaryResponse = StructuredMetadataResponse(error: FakeAgentError.expected)
        let fallbackResponse = StructuredMetadataResponse(
            metadata: GeneratedToolMetadata(
                displayName: "Pantry Pal",
                iconPrompt: "Pantry shelves"
            )
        )

        let suggestion = await ToolMetadataClient.live(
            fallbackLanguageModel: StructuredMetadataLanguageModel(response: fallbackResponse)
        ).suggestMetadata(
            userPrompt: "Build a pantry tracker",
            invoker: Self.makeInvoker(
                languageModel: StructuredMetadataLanguageModel(response: primaryResponse),
                generationOptions: GenerationOptions(maximumResponseTokens: 4096)
            )
        )

        #expect(suggestion.displayName == "Pantry Pal")
        #expect(suggestion.iconPrompt == "Pantry shelves")
        #expect(await primaryResponse.prompts.count == 1)
        #expect(await fallbackResponse.prompts.count == 1)
        #expect(
            await fallbackResponse.options.first?.maximumResponseTokens
                == ToolGenerationOptionsResolver.metadataMaximumResponseTokens
        )
    }

    @MainActor
    @Test
    func livePromptRefinementClientUsesPlainTextSelectedModel() async throws {
        let promptCapture = PromptCapture()
        let optionsCapture = GenerationOptionsCapture()
        let refinedPrompt = "Build a first-version local macOS pantry tracker with a searchable list, editable item details, and expiry highlights."
        let refined = await ToolPromptRefinementClient.live().refinePrompt(
            userPrompt: "Build a pantry tracker",
            invoker: Self.makeInvoker(
                languageModel: StubAgentLanguageModel { prompt, options in
                    await promptCapture.record(prompt)
                    await optionsCapture.record(options)
                    return refinedPrompt
                },
                generationOptions: GenerationOptions(
                    maximumResponseTokens: ToolGenerationOptionsResolver.promptRefinementMaximumResponseTokens
                )
            ),
            sandboxEnabled: false
        )

        #expect(refined == refinedPrompt)
        let prompt = try #require(await promptCapture.prompts.first)
        #expect(prompt.contains("User request:\nBuild a pantry tracker"))
        #expect(prompt.contains("App sandbox: disabled."))
        #expect(prompt.contains("must not make changes to the user's system unless the user asks"))
        #expect(prompt.contains("Return a plain text prompt"))
        #expect(
            await optionsCapture.options.first?.maximumResponseTokens
                == ToolGenerationOptionsResolver.promptRefinementMaximumResponseTokens
        )
    }

    @MainActor
    @Test
    func livePromptRefinementClientStreamsPlainTextResponse() async throws {
        let refinedPrompt = "Build a mortgage calculator with purchase price, down payment, interest, taxes, insurance, and a clear monthly payment summary."
        let refined = await ToolPromptRefinementClient.live().refinePrompt(
            userPrompt: "Make a mortgage calculator",
            invoker: Self.makeInvoker(
                languageModel: StreamOnlyPromptRefinementLanguageModel(response: refinedPrompt),
                generationOptions: GenerationOptions(maximumResponseTokens: 4096)
            ),
            sandboxEnabled: true
        )

        #expect(refined == refinedPrompt)
    }

    @MainActor
    @Test
    func livePromptRefinementClientIncludesMenuBarAppTypeContext() async throws {
        let promptCapture = PromptCapture()
        let refinedPrompt = "Build a compact menu bar timer with start, pause, reset, and a current-session summary."
        let refined = await ToolPromptRefinementClient.live().refinePrompt(
            userPrompt: "Build a timer",
            invoker: Self.makeInvoker(
                languageModel: StubAgentLanguageModel { prompt, _ in
                    await promptCapture.record(prompt)
                    return refinedPrompt
                },
                generationOptions: GenerationOptions(maximumResponseTokens: 4096)
            ),
            appKind: .menuBar,
            sandboxEnabled: true
        )

        #expect(refined == refinedPrompt)
        let prompt = try #require(await promptCapture.prompts.first)
        #expect(prompt.contains("App type: menu bar app."))
        #expect(prompt.contains("MenuBarExtra popover-style window"))
        #expect(prompt.contains("compact menu bar utility"))
        #expect(prompt.contains("bounded width and height"))
        #expect(!(prompt.contains("Avoid full-app layouts")))
    }

    @MainActor
    @Test
    func livePromptRefinementClientFallsBackToOriginalPromptOnFailure() async throws {
        let refined = await ToolPromptRefinementClient.live().refinePrompt(
            userPrompt: "Build a pantry tracker",
            invoker: Self.makeInvoker(
                languageModel: EmptyLanguageModel(),
                generationOptions: GenerationOptions(maximumResponseTokens: 4096)
            )
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
            pipelineConfiguration: .ironsmithSpark(repairStrategy: .deterministicOnly),
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

        _ = try await runtime.generateTool(
            for: "Make a timer",
            settings: ToolGenerationSettings(appKind: .menuBar)
        )

        let prompts = await promptCapture.prompts
        #expect(prompts.first?.contains(refinedPrompt) == true)
        #expect(prompts.first?.contains("App type: menu bar app.") == true)
        #expect(prompts.first?.contains("MenuBarExtra popover-style window") == true)
        #expect(prompts.first?.contains("compact menu bar utility") == true)
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
            pipelineConfiguration: .ironsmithSpark(repairStrategy: .deterministicOnly),
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

        _ = try await runtime.generateTool(for: "Make a habit tracker", settings: .default)

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
                return Self.renameOldToNewPatch
            },
            generationOptions: GenerationOptions(),
            pipelineConfiguration: .ironsmithFlame(repairStrategy: .modelSearchReplace(maxPatchBlocksPerTurn: ToolGenerationRepairPolicy.largeModelPatchBlocksPerTurn)),
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
            settings: .default
        )

        let prompts = await promptCapture.prompts
        #expect(prompts.first?.contains("User request: Change old to new") == true)
        #expect(!(prompts.first?.contains("Rewrite the whole app with unrelated features.") ?? false))
        #expect(await metadataCapture.count == 0)
        #expect(await promptRefinementCapture.count == 0)
    }

    @MainActor
    @Test
    func languageModelInvokerStreamsByDefaultAndRunsSuccessHookOnce() async throws {
        let modeCapture = InvocationModeCapture()
        let invocationCapture = InvocationCapture()
        let model = InvocationModeLanguageModel(
            modeCapture: modeCapture,
            respondResult: .success("responded"),
            streamResult: .success("streamed")
        )
        let session = LanguageModelSession(model: model)
        let invoker = Self.makeInvoker(
            languageModel: model,
            afterLanguageModelInvocation: {
                await invocationCapture.record()
            }
        )

        let response = try await invoker.respond(
            stage: .codingAgent,
            in: session,
            to: "Build a timer",
            generating: String.self
        )

        #expect(response == "streamed")
        #expect(await modeCapture.modes == [.stream])
        #expect(await invocationCapture.count == 1)
    }

    @MainActor
    @Test
    func languageModelInvokerSupportsExplicitNonStreamingOverride() async throws {
        let modeCapture = InvocationModeCapture()
        let model = InvocationModeLanguageModel(
            modeCapture: modeCapture,
            respondResult: .success("responded"),
            streamResult: .success("streamed")
        )
        let session = LanguageModelSession(model: model)
        let invoker = Self.makeInvoker(languageModel: model)

        let response = try await invoker.respond(
            stage: .codingAgent,
            in: session,
            to: "Build a timer",
            generating: String.self,
            streaming: false
        )

        #expect(response == "responded")
        #expect(await modeCapture.modes == [.respond])
    }

    @MainActor
    @Test
    func languageModelInvokerRunsFailureHookOnce() async throws {
        let modeCapture = InvocationModeCapture()
        let invocationCapture = InvocationCapture()
        let model = InvocationModeLanguageModel(
            modeCapture: modeCapture,
            respondResult: .success("responded"),
            streamResult: .failure(FakeAgentError.expected)
        )
        let session = LanguageModelSession(model: model)
        let invoker = Self.makeInvoker(
            languageModel: model,
            afterLanguageModelInvocation: {
                await invocationCapture.record()
            }
        )

        do {
            _ = try await invoker.respond(
                stage: .codingAgent,
                in: session,
                to: "Build a timer",
                generating: String.self
            )
            Issue.record("Expected responder to throw.")
        } catch {
            #expect(error as? FakeAgentError == .expected)
        }

        #expect(await modeCapture.modes == [.stream])
        #expect(await invocationCapture.count == 1)
    }
}

private enum InvocationMode: Equatable {
    case respond
    case stream
}

private actor InvocationModeCapture {
    private(set) var modes: [InvocationMode] = []

    func record(_ mode: InvocationMode) {
        modes.append(mode)
    }
}

private struct InvocationModeLanguageModel: LanguageModel {
    typealias UnavailableReason = Never

    let modeCapture: InvocationModeCapture
    let respondResult: Result<String, any Error>
    let streamResult: Result<String, any Error>

    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        await modeCapture.record(.respond)
        guard type == String.self else {
            throw FakeAgentError.unsupportedStructuredGeneration
        }
        let response = try respondResult.get()
        return LanguageModelSession.Response(
            content: response as! Content,
            rawContent: GeneratedContent(response),
            transcriptEntries: []
        )
    }

    func streamResponse<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        let modeCapture = modeCapture
        let streamResult = streamResult
        return LanguageModelSession.ResponseStream(
            stream: AsyncThrowingStream { continuation in
                Task {
                    await modeCapture.record(.stream)
                    guard type == String.self else {
                        continuation.finish(throwing: FakeAgentError.unsupportedStructuredGeneration)
                        return
                    }
                    do {
                        let response = try streamResult.get()
                        continuation.yield(
                            .init(
                                content: (response as! Content).asPartiallyGenerated(),
                                rawContent: GeneratedContent(response)
                            )
                        )
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        )
    }
}

private struct StreamOnlyPromptRefinementLanguageModel: LanguageModel {
    typealias UnavailableReason = Never

    let response: String

    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        throw FakeAgentError.expected
    }

    func streamResponse<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        LanguageModelSession.ResponseStream(
            content: response as! Content,
            rawContent: GeneratedContent(response)
        )
    }
}
