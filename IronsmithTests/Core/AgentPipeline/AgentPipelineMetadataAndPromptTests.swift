import AnyLanguageModel
import Foundation
import ImageIO
import SwiftData
import Testing
@testable import Ironsmith

extension AgentPipelineTests {
    @MainActor
    @Test
    func generatedCreationPlanSchemaIncludesMetadataAppKindAndPermissions() throws {
        let data = try JSONEncoder().encode(GeneratedToolCreationPlan.generationSchema)
        let schema = try #require(String(data: data, encoding: .utf8))

        #expect(schema.contains("displayName"))
        #expect(schema.contains("iconPrompt"))
        #expect(schema.contains("menuBarSystemImage"))
        #expect(schema.contains("category"))
        #expect(schema.contains("appKind"))
        #expect(schema.contains("sandboxPermissions"))
        #expect(schema.contains("resourcePermissions"))
        #expect(schema.contains("Exact sandbox permission raw values"))
        #expect(schema.contains("Exact resource permission raw values"))
        #expect(!(schema.contains("refinedPrompt")))
    }

    @MainActor
    @Test
    func creationPlanningRequestsAndValidatesPermissions() async throws {
        let response = StructuredMetadataResponse(
            creationPlan: GeneratedToolCreationPlan(
                displayName: "Camera Dot",
                iconPrompt: "Camera with dot",
                menuBarSystemImage: "camera",
                category: StoreAppCategory.utilities.rawValue,
                appKind: ToolAppKind.menuBar.rawValue,
                sandboxPermissions: [
                    GeneratedAppSandboxPermission.outgoingConnections.rawValue,
                    "unknown-sandbox-permission",
                ],
                resourcePermissions: [
                    GeneratedAppResourcePermission.camera.rawValue,
                    "unknown-resource-permission",
                ]
            )
        )

        let suggestion = await ToolGenerationPlanningClient.live().planCreation(
            userPrompt: "Show a camera status dot in the menu bar",
            invoker: Self.makeInvoker(
                languageModel: StructuredMetadataLanguageModel(response: response),
                generationOptions: GenerationOptions(maximumResponseTokens: 4096)
            )
        )

        #expect(suggestion.suggestedAppKind == .menuBar)
        #expect(suggestion.suggestedSandboxPermissions.enabled == [.outgoingConnections])
        #expect(suggestion.suggestedResourcePermissions.enabled == [.camera])
        let prompt = try #require(await response.prompts.first)
        #expect(prompt.contains("Allowed sandboxPermissions values:"))
        #expect(prompt.contains("Allowed resourcePermissions values:"))
    }

    @MainActor
    @Test
    func editPlanningRequestsOnlyAdditionalValidatedPermissions() async throws {
        let response = StructuredMetadataResponse(
            editPlan: GeneratedToolEditPlan(
                additionalSandboxPermissions: [
                    GeneratedAppSandboxPermission.downloadsFolder.rawValue,
                    "unknown-sandbox-permission",
                ],
                additionalResourcePermissions: [
                    GeneratedAppResourcePermission.microphone.rawValue,
                    "unknown-resource-permission",
                ]
            )
        )
        let plan = await ToolGenerationPlanningClient.live().planEdit(
            userPrompt: "Add voice note export to Downloads",
            toolName: "Notes",
            currentSettings: ToolGenerationSettings(
                resourcePermissions: GeneratedAppResourcePermissions([.camera])
            ),
            invoker: Self.makeInvoker(
                languageModel: StructuredMetadataLanguageModel(response: response),
                generationOptions: GenerationOptions(maximumResponseTokens: 4096)
            )
        )

        #expect(plan.additionalSandboxPermissions.enabled == [.downloadsFolder])
        #expect(plan.additionalResourcePermissions.enabled == [.microphone])
        let prompt = try #require(await response.prompts.first)
        #expect(prompt.contains("Existing app: Notes"))
        #expect(prompt.contains("Existing resource permissions:\ncamera"))
    }

    @MainActor
    @Test
    func liveMetadataClientUsesStructuredGenerationForNameAndIcon() async throws {
        let metadata = GeneratedToolCreationPlan(
            displayName: "Recipe Board",
            iconPrompt: "Recipe cards"
        )
        let response = StructuredMetadataResponse(creationPlan: metadata)

        let suggestion = await ToolGenerationPlanningClient.live().planCreation(
            userPrompt: "recipes",
            invoker: Self.makeInvoker(
                languageModel: StructuredMetadataLanguageModel(response: response),
                generationOptions: GenerationOptions(maximumResponseTokens: 4096)
            )
        )

        #expect(suggestion.displayName == "Recipe Board")
        #expect(suggestion.iconPrompt == "Recipe cards")
        #expect(suggestion.menuBarSystemImage == ToolMenuBarSymbol.fallback)
        #expect(suggestion.category == .utilities)
        let prompt = try #require(await response.prompts.first)
        #expect(prompt.contains("User request:\nrecipes"))
        #expect(prompt.contains("Allowed menuBarSystemImage values:"))
        #expect(prompt.contains("Allowed category values:"))
        #expect(prompt.contains(StoreAppCategory.graphicsDesign.rawValue))
        #expect(prompt.contains("Allowed sandboxPermissions values:"))
        #expect(prompt.contains("Allowed resourcePermissions values:"))
        #expect(!(prompt.contains("Planning budget:")))
        #expect(!(prompt.contains("Refined prompt:")))
        #expect(!(prompt.contains("backend")))
        #expect(await response.options.first?.maximumResponseTokens == 4096)
    }

    @MainActor
    @Test
    func liveMetadataClientSelectsConceptOnlyPromptModeForHostedImages() async throws {
        let response = StructuredMetadataResponse(
            creationPlan: GeneratedToolCreationPlan(
                displayName: "Mortgage Calc",
                iconPrompt: "A small house sheltering a calculator, with one coin orbiting the roofline."
            )
        )

        _ = await ToolGenerationPlanningClient.live().planCreation(
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
            creationPlan: GeneratedToolCreationPlan(
                displayName: "Timer",
                iconPrompt: "Small timer",
                menuBarSystemImage: "not.a.real.allowed.symbol"
            )
        )

        let suggestion = await ToolGenerationPlanningClient.live().planCreation(
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
    func metadataSuggestionUsesValidatedStoreCategory() async throws {
        let response = StructuredMetadataResponse(
            creationPlan: GeneratedToolCreationPlan(
                displayName: "Budget Board",
                iconPrompt: "Ledger with coins",
                menuBarSystemImage: ToolMenuBarSymbol.fallback,
                category: StoreAppCategory.finance.rawValue
            )
        )

        let suggestion = await ToolGenerationPlanningClient.live().planCreation(
            userPrompt: "Build a budget planner",
            invoker: Self.makeInvoker(
                languageModel: StructuredMetadataLanguageModel(response: response),
                generationOptions: GenerationOptions(maximumResponseTokens: 4096)
            )
        )

        #expect(suggestion.category == .finance)
    }

    @MainActor
    @Test
    func metadataSuggestionFallsBackForInvalidCategoryAndAppKind() async throws {
        let response = StructuredMetadataResponse(
            creationPlan: GeneratedToolCreationPlan(
                displayName: "Budget Board",
                iconPrompt: "Ledger with coins",
                menuBarSystemImage: ToolMenuBarSymbol.fallback,
                category: "not-a-category",
                appKind: "not-an-app-kind"
            )
        )

        let suggestion = await ToolGenerationPlanningClient.live().planCreation(
            userPrompt: "Build a budget planner",
            invoker: Self.makeInvoker(
                languageModel: StructuredMetadataLanguageModel(response: response),
                generationOptions: GenerationOptions(maximumResponseTokens: 4096)
            )
        )

        #expect(suggestion.category == .utilities)
        #expect(suggestion.suggestedAppKind == .window)
    }

    @MainActor
    @Test
    func liveMetadataClientFallsBackWhenStructuredGenerationFails() async throws {
        let response = StructuredMetadataResponse(error: FakeAgentError.expected)

        let suggestion = await ToolGenerationPlanningClient.live(fallbackLanguageModel: nil).planCreation(
            userPrompt: "Build a pantry tracker",
            invoker: Self.makeInvoker(
                languageModel: StructuredMetadataLanguageModel(response: response),
                generationOptions: GenerationOptions(maximumResponseTokens: 4096)
            )
        )

        #expect(suggestion.displayName == "Build A Pantry Tracker")
        #expect(suggestion.iconPrompt == "")
        #expect(suggestion.category == .utilities)
    }

    @MainActor
    @Test
    func liveEditPlanningPreservesPermissionsWhenStructuredGenerationFails() async {
        let response = StructuredMetadataResponse(error: FakeAgentError.expected)

        let plan = await ToolGenerationPlanningClient.live(fallbackLanguageModel: nil).planEdit(
            userPrompt: "Add a label",
            toolName: "Pantry",
            currentSettings: ToolGenerationSettings(
                resourcePermissions: GeneratedAppResourcePermissions([.camera])
            ),
            invoker: Self.makeInvoker(
                languageModel: StructuredMetadataLanguageModel(response: response),
                generationOptions: GenerationOptions(maximumResponseTokens: 4096)
            )
        )

        #expect(plan == .empty)
        #expect(await response.prompts.count == 1)
    }

    @MainActor
    @Test
    func liveMetadataClientUsesSystemModelAfterSelectedModelFails() async throws {
        let primaryResponse = StructuredMetadataResponse(error: FakeAgentError.expected)
        let fallbackResponse = StructuredMetadataResponse(
            creationPlan: GeneratedToolCreationPlan(
                displayName: "Pantry Pal",
                iconPrompt: "Pantry shelves"
            )
        )

        let suggestion = await ToolGenerationPlanningClient.live(
            fallbackLanguageModel: StructuredMetadataLanguageModel(response: fallbackResponse)
        ).planCreation(
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

    @Test
    func promptRefinementScopeMatchesCodingAgentCapacity() {
        let spark = ToolPromptRefinementClient.promptRefinementInstructions(
            for: .ironsmithSpark)
        let flame = ToolPromptRefinementClient.promptRefinementInstructions(
            for: .ironsmithFlame)
        let codex = ToolPromptRefinementClient.promptRefinementInstructions(for: .codex)

        #expect(spark.contains("Choose at most 3 core user-facing features."))
        #expect(spark.contains("explicitly simplify or omit the rest."))
        #expect(spark.contains("Must be under 750 characters."))
        for instructions in [flame, codex] {
            #expect(instructions.contains("Must be additive only: preserve every requested feature and constraint"))
            #expect(instructions.contains("without removing, simplifying, replacing, or reprioritizing"))
            #expect(instructions.contains("specific product intent, core features, expected interactions"))
            #expect(instructions.contains("Must preserve whether the generated app is a window app or menu bar app."))
            #expect(instructions.contains("For menu bar apps, describe a compact menu bar popover utility"))
            #expect(instructions.contains("For window apps, describe a normal native macOS window app layout"))
            #expect(instructions.contains("Prefer one polished primary workflow over many secondary workflows"))
            #expect(instructions.contains("native Apple framework such as Vision for OCR, PDFKit for PDFs, or AVFoundation"))
            #expect(instructions.contains("Must describe a self-contained Mac app"))
            #expect(instructions.contains("May include local persistence, local files, import/export"))
            #expect(instructions.contains("Must not add or imply a separate backend service"))
            #expect(instructions.contains("Should emphasize a native macOS feel"))
            #expect(instructions.contains("games, drawing canvases, and highly visual toys"))
            #expect(!instructions.contains("Choose at most 3 core user-facing features."))
            #expect(!instructions.contains("explicitly simplify or omit the rest."))
            #expect(!instructions.contains("Must be under 750 characters."))
        }
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
            planningClient: ToolGenerationPlanningClient { _ in
                ToolCreationPlan(
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
            planningClient: ToolGenerationPlanningClient { _ in
                ToolCreationPlan(
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
    func storeGenerationRequestUsesCodingAgentAndPermissionPolicy() throws {
        let request = StoreGenerationContextRequest(
            originalPrompt: "Build a timer",
            refinedPrompt: "Build a focused timer",
            settings: .default,
            codingAgent: .ironsmithFlame,
            automaticallySelectPermissions: false
        )

        #expect(request.codingAgent == "flame")
        #expect(request.permissionMode == "strict")
        let encoded = try String(
            decoding: JSONEncoder().encode(request),
            as: UTF8.self
        )
        #expect(!encoded.contains("runtimeVersion"))
    }

    @MainActor
    @Test
    func compactStoreGenerationContextPlanDecodesGenerationAndProvenanceData() throws {
        let data = Data(
            #"""
            {
              "mode": "base_with_capabilities",
              "codingAgent": "flame",
              "promptContext": "[STORE-ASSISTED GENERATION CONTEXT]",
              "resolvedSandboxPermissions": ["internet"],
              "resolvedResourcePermissions": ["camera"],
              "base": {
                "versionId": "base-version",
                "storeId": "store-1",
                "appId": "app-1",
                "appName": "Simple Timer",
                "versionNumber": 3,
                "sourceSha256": "base-sha",
                "sourceCode": "import SwiftUI"
              },
              "inspirations": [{
                "versionId": "inspiration-version",
                "storeId": "store-2",
                "appId": "app-2",
                "appName": "Preset Timer"
              }]
            }
            """#.utf8
        )

        let plan = try JSONDecoder().decode(StoreGenerationContextPlan.self, from: data)

        #expect(plan.mode == .baseWithCapabilities)
        #expect(plan.codingAgent == "flame")
        #expect(plan.promptContext == "[STORE-ASSISTED GENERATION CONTEXT]")
        #expect(plan.resolvedSandboxPermissions == ["internet"])
        #expect(plan.resolvedResourcePermissions == ["camera"])
        #expect(plan.base?.sourceCode == "import SwiftUI")
        #expect(plan.base?.versionId == "base-version")
        #expect(plan.inspirations.first?.appName == "Preset Timer")
        #expect(plan.inspirations.map(\.versionId) == ["inspiration-version"])
    }

    @MainActor
    @Test
    func storeContextPlanMustMatchTheResumeCodingAgent() {
        let plan = StoreGenerationContextPlan(
            mode: .scratch,
            codingAgent: "flame",
            promptContext: "",
            resolvedSandboxPermissions: [],
            resolvedResourcePermissions: [],
            base: nil,
            inspirations: []
        )

        #expect(SingleFileToolGenerationRuntime.canReuseStoreContextPlan(plan, with: "flame"))
        #expect(!SingleFileToolGenerationRuntime.canReuseStoreContextPlan(plan, with: "spark"))
    }

    @MainActor
    @Test
    func storeAssistedCreateMaterializesBaseAndUsesItAsAnEditContext() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let refinedPrompt = "Build a focused timer with selectable presets."
        let promptCapture = PromptCapture()
        let storeCapture = StoreGenerationCapture()
        let plan = StoreGenerationContextPlan(
            mode: .baseWithCapabilities,
            codingAgent: "spark",
            promptContext: """
                [STORE-ASSISTED GENERATION CONTEXT]
                Selection mode: base_with_capabilities
                Reusable capability from “Preset Timer”: Selectable presets
            """,
            resolvedSandboxPermissions: ["internet", "userSelectedFiles"],
            resolvedResourcePermissions: ["camera"],
            base: StoreGenerationBaseContext(
                versionId: "version-base",
                storeId: "store-1",
                appId: "app-1",
                appName: "Simple Timer",
                versionNumber: 3,
                sourceSha256: "sha256",
                sourceCode: Self.originalEditableSource
            ),
            inspirations: [
                StoreGenerationInspirationReference(
                    versionId: "version-capability",
                    storeId: "store-1",
                    appId: "app-2",
                    appName: "Preset Timer"
                )
            ]
        )
        var storeClient = IronsmithStoreClient.unconfigured
        storeClient.prepareGenerationContext = { request in
            await storeCapture.record(request: request)
            return plan
        }
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { prompt, _ in
                await promptCapture.record(prompt)
                return Self.renameOldToNewUnifiedDiff
            },
            generationOptions: GenerationOptions(),
            pipelineConfiguration: .ironsmithSpark(
                repairStrategy: .modelSearchReplace(maxPatchBlocksPerTurn: 1)
            ),
            toolsDirectoryURL: toolsDirectory,
            processClient: Self.successfulProcessClient(),
            planningClient: ToolGenerationPlanningClient { _ in
                ToolCreationPlan(displayName: "Auto Remix Timer", iconPrompt: "")
            },
            promptRefinementClient: ToolPromptRefinementClient { _ in refinedPrompt },
            storeClient: storeClient
        )
        let lifecycle = ToolGenerationLifecycle(
            updateStoreGenerationContext: { context in
                await storeCapture.record(snapshot: context)
            },
            updatePhase: { _, phase, _ in
                await storeCapture.record(phase: phase)
            }
        )

        let result = try await runtime.generateTool(
            for: "Make a timer with presets",
            settings: .default,
            planningPolicy: ToolGenerationPlanningPolicy(
                appKindPreference: .automatic,
                automaticallySelectPermissions: true,
                alwaysIncludedSandboxPermissions: .none,
                alwaysIncludedResourcePermissions: .none
            ),
            lifecycle: lifecycle,
            storeAssistedGenerationEnabled: true
        )

        let source = try String(contentsOf: Self.contentViewURL(for: result), encoding: .utf8)
        let prompts = await promptCapture.prompts
        #expect(source.contains(#"Text("new")"#))
        #expect(!(source.contains(#"Text("old")"#)))
        #expect(await storeCapture.request?.originalPrompt == "Make a timer with presets")
        #expect(await storeCapture.request?.refinedPrompt == refinedPrompt)
        #expect(await storeCapture.request?.codingAgent == "spark")
        #expect(await storeCapture.request?.permissionMode == "automatic")
        #expect(result.settings.sandboxPermissions.contains(.outgoingConnections))
        #expect(result.settings.resourcePermissions.contains(.camera))
        #expect(await storeCapture.plan == plan)
        #expect(await storeCapture.snapshot?.originalPrompt == "Make a timer with presets")
        #expect(await storeCapture.snapshot?.refinedPrompt == refinedPrompt)
        let pendingContext = try ToolStoreRemixStateClient.live.pendingContext(
            result.packageRootURL
        )
        #expect(pendingContext?.promptContext == plan.promptContext)
        #expect(pendingContext?.resolvedSandboxPermissions == plan.resolvedSandboxPermissions)
        #expect(pendingContext?.resolvedResourcePermissions == plan.resolvedResourcePermissions)
        #expect(await storeCapture.phases.contains(.searchingStore))
        #expect(prompts.first?.contains("[STORE-ASSISTED GENERATION CONTEXT]") == true)
        #expect(prompts.first?.contains("Selectable presets") == true)
        #expect(prompts.first?.contains("Edit ContentView.swift by returning a unified diff only.") == true)
    }

    @MainActor
    @Test
    func failedResumeReplanClearsPreviousStoreContextBeforeScratchGeneration() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let tool = try Self.makeExistingTool(
            toolsDirectory: toolsDirectory,
            executableName: "ReplannedTimer",
            source: Self.originalEditableSource
        )
        tool.generationState = .stopped
        tool.generationPhase = .planning
        tool.generationMode = .create
        let savedSnapshot = StoreRemixTestFixture.snapshot(codingAgent: "flame")
        try ToolStoreRemixStateClient.live.stage(savedSnapshot, tool.packageRootURL)
        tool.replaceStoreProvenance(
            remixSource: savedSnapshot.plan.base.map {
                StoreVersionReference(
                    versionId: $0.versionId,
                    storeId: $0.storeId,
                    appId: $0.appId,
                    appName: $0.appName,
                    versionNumber: $0.versionNumber,
                    sourceSha256: $0.sourceSha256
                )
            },
            inspirations: savedSnapshot.plan.inspirations.map {
                StoreVersionReference(
                    versionId: $0.versionId,
                    storeId: $0.storeId,
                    appId: $0.appId,
                    appName: $0.appName
                )
            }
        )

        let promptCapture = PromptCapture()
        let clearCapture = StoreGenerationClearCapture()
        var storeClient = IronsmithStoreClient.unconfigured
        storeClient.prepareGenerationContext = { _ in
            throw FakeAgentError.expected
        }
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { prompt, _ in
                await promptCapture.record(prompt)
                return Self.simpleContentViewSource(text: "scratch")
            },
            generationOptions: GenerationOptions(),
            pipelineConfiguration: .ironsmithSpark(
                repairStrategy: .modelSearchReplace(maxPatchBlocksPerTurn: 1)
            ),
            toolsDirectoryURL: toolsDirectory,
            processClient: Self.successfulProcessClient(),
            storeClient: storeClient
        )
        let lifecycle = ToolGenerationLifecycle(
            clearStoreGenerationContextForScratchFallback: {
                refinedPrompt,
                discardedBaseVersionId in
                await clearCapture.record(
                    refinedPrompt: refinedPrompt,
                    discardedBaseVersionId: discardedBaseVersionId
                )
                await MainActor.run {
                    tool.storeProvenance = nil
                    tool.pendingPrompt = refinedPrompt
                }
            }
        )

        _ = try await runtime.generateTool(
            for: savedSnapshot.originalPrompt,
            existingTool: tool,
            settings: .default,
            lifecycle: lifecycle,
            storeAssistedGenerationEnabled: true
        )

        #expect(await clearCapture.refinedPrompt == savedSnapshot.refinedPrompt)
        #expect(
            await clearCapture.discardedBaseVersionId == nil
        )
        #expect(try ToolStoreRemixStateClient.live.pendingContext(tool.packageRootURL) == nil)
        #expect(tool.storeProvenance == nil)
        #expect(tool.pendingPrompt == savedSnapshot.refinedPrompt)
        #expect(await promptCapture.prompts.first?.contains(savedSnapshot.refinedPrompt) == true)
        #expect(
            await promptCapture.prompts.first?.contains(
                "[STORE-ASSISTED GENERATION CONTEXT]"
            ) == false
        )
    }

    @MainActor
    @Test
    func missingPendingStoreContextClearsDurableProvenanceBeforeScratchResume() async throws {
        let toolsDirectory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }

        let tool = try Self.makeExistingTool(
            toolsDirectory: toolsDirectory,
            executableName: "MissingStoreContext",
            source: Self.originalEditableSource
        )
        tool.generationState = .stopped
        tool.generationPhase = .generatingSource
        tool.generationMode = .create
        tool.replaceStoreProvenance(
            remixSource: StoreVersionReference(
                versionId: "missing-base-version",
                storeId: "store-1",
                appId: "base-app"
            ),
            inspirations: [StoreVersionReference(versionId: "inspiration-version")]
        )

        let promptCapture = PromptCapture()
        let clearCapture = StoreGenerationClearCapture()
        let runtime = Self.makeRuntime(
            languageModel: StubAgentLanguageModel { prompt, _ in
                await promptCapture.record(prompt)
                return Self.simpleContentViewSource(text: "scratch")
            },
            generationOptions: GenerationOptions(),
            pipelineConfiguration: .ironsmithSpark(
                repairStrategy: .modelSearchReplace(maxPatchBlocksPerTurn: 1)
            ),
            toolsDirectoryURL: toolsDirectory,
            processClient: Self.successfulProcessClient()
        )
        let originalPrompt = "Build a timer from scratch"
        let lifecycle = ToolGenerationLifecycle(
            clearStoreGenerationContextForScratchFallback: {
                refinedPrompt,
                discardedBaseVersionId in
                await clearCapture.record(
                    refinedPrompt: refinedPrompt,
                    discardedBaseVersionId: discardedBaseVersionId
                )
                await MainActor.run {
                    tool.storeProvenance = nil
                    tool.pendingPrompt = refinedPrompt
                }
            }
        )

        _ = try await runtime.generateTool(
            for: originalPrompt,
            existingTool: tool,
            settings: .default,
            lifecycle: lifecycle,
            storeAssistedGenerationEnabled: false
        )

        #expect(await clearCapture.refinedPrompt == originalPrompt)
        #expect(await clearCapture.discardedBaseVersionId == nil)
        #expect(tool.storeProvenance == nil)
        #expect(tool.pendingPrompt == originalPrompt)
        #expect(await promptCapture.prompts.first?.contains(originalPrompt) == true)
        #expect(
            await promptCapture.prompts.first?.contains(
                "[STORE-ASSISTED GENERATION CONTEXT]"
            ) == false
        )
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
            planningClient: ToolGenerationPlanningClient { _ in
                await metadataCapture.record()
                return ToolCreationPlan(
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
