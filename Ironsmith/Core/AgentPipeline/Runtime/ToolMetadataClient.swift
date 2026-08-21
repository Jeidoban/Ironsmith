import AnyLanguageModel
import Foundation

struct ToolCreationPlan: Equatable, Sendable {
    let displayName: String
    let iconPrompt: String
    let menuBarSystemImage: String
    let category: StoreAppCategory
    let suggestedAppKind: ToolAppKind
    let suggestedSandboxPermissions: GeneratedAppSandboxPermissions
    let suggestedResourcePermissions: GeneratedAppResourcePermissions

    nonisolated init(
        displayName: String,
        iconPrompt: String,
        menuBarSystemImage: String = ToolMenuBarSymbol.fallback,
        category: StoreAppCategory = .utilities,
        suggestedAppKind: ToolAppKind = .window,
        suggestedSandboxPermissions: GeneratedAppSandboxPermissions = .none,
        suggestedResourcePermissions: GeneratedAppResourcePermissions = .none
    ) {
        self.displayName = displayName
        self.iconPrompt = iconPrompt
        self.menuBarSystemImage = ToolMenuBarSymbol.validated(menuBarSystemImage)
        self.category = category
        self.suggestedAppKind = suggestedAppKind
        self.suggestedSandboxPermissions = suggestedSandboxPermissions
        self.suggestedResourcePermissions = suggestedResourcePermissions
    }
}

struct ToolEditPlan: Equatable, Sendable {
    let additionalSandboxPermissions: GeneratedAppSandboxPermissions
    let additionalResourcePermissions: GeneratedAppResourcePermissions

    nonisolated static var empty: Self {
        Self(
            additionalSandboxPermissions: .none,
            additionalResourcePermissions: .none
        )
    }
}

@Generable(description: "Creation plan for a generated macOS app.")
struct GeneratedToolCreationPlan {
    @Guide(description: "A snappy one or two word macOS playful and fun app name in Title Case")
    let displayName: String

    @Guide(
        description:
            "An image-generation prompt that follows the iconPrompt requirements in the instructions."
    )
    let iconPrompt: String

    @Guide(
        description:
            "One SF Symbol name chosen exactly from Ironsmith's allowed menuBarSystemImage list.")
    let menuBarSystemImage: String

    @Guide(
        description:
            "One category raw value chosen exactly from Ironsmith's allowed category list.")
    let category: String

    @Guide(description: "One app type raw value chosen from the allowed app type list.")
    let appKind: String

    @Guide(
        description:
            "Exact sandbox permission raw values required by the explicit request, or an empty list."
    )
    let sandboxPermissions: [String]

    @Guide(
        description:
            "Exact resource permission raw values required by the explicit request, or an empty list."
    )
    let resourcePermissions: [String]
}

extension GeneratedToolCreationPlan {
    nonisolated init(
        displayName: String,
        iconPrompt: String,
        menuBarSystemImage: String = ToolMenuBarSymbol.fallback,
        category: String = StoreAppCategory.utilities.rawValue,
        appKind: String = ToolAppKind.window.rawValue
    ) {
        self.init(
            displayName: displayName,
            iconPrompt: iconPrompt,
            menuBarSystemImage: menuBarSystemImage,
            category: category,
            appKind: appKind,
            sandboxPermissions: [],
            resourcePermissions: []
        )
    }
}

@Generable(description: "Plan for editing an existing generated macOS app.")
struct GeneratedToolEditPlan {
    @Guide(
        description:
            "Exact additional sandbox permission raw values required by this edit, or an empty list."
    )
    let additionalSandboxPermissions: [String]

    @Guide(
        description:
            "Exact additional resource permission raw values required by this edit, or an empty list."
    )
    let additionalResourcePermissions: [String]
}

struct ToolCreationPlanningRequest: Sendable {
    let userPrompt: String
    let imageGenerationProvider: ToolImageGenerationProvider
    let invoker: ToolLanguageModelInvoker
}

struct ToolEditPlanningRequest: Sendable {
    let userPrompt: String
    let toolName: String
    let currentSettings: ToolGenerationSettings
    let invoker: ToolLanguageModelInvoker
}

struct ToolGenerationPlanningClient: Sendable {
    private var planCreationForRequest:
        @Sendable (_ request: ToolCreationPlanningRequest) async -> ToolCreationPlan
    private var planEditForRequest:
        @Sendable (_ request: ToolEditPlanningRequest) async -> ToolEditPlan

    init(
        _ planCreation:
            @escaping @Sendable (_ userPrompt: String) async -> ToolCreationPlan
    ) {
        self.planCreationForRequest = { request in
            await planCreation(request.userPrompt)
        }
        self.planEditForRequest = { _ in .empty }
    }

    init(
        planCreation:
            @escaping @Sendable (_ userPrompt: String) async -> ToolCreationPlan,
        planEdit:
            @escaping @Sendable (_ request: ToolEditPlanningRequest) async -> ToolEditPlan
    ) {
        self.planCreationForRequest = { request in
            await planCreation(request.userPrompt)
        }
        self.planEditForRequest = planEdit
    }

    private init(
        requestBased: Void,
        planCreationForRequest:
            @escaping @Sendable (_ request: ToolCreationPlanningRequest) async -> ToolCreationPlan,
        planEditForRequest:
            @escaping @Sendable (_ request: ToolEditPlanningRequest) async -> ToolEditPlan
    ) {
        self.planCreationForRequest = planCreationForRequest
        self.planEditForRequest = planEditForRequest
    }

    func planCreation(
        userPrompt: String,
        imageGenerationProvider: ToolImageGenerationProvider = .imagePlayground,
        invoker: ToolLanguageModelInvoker
    ) async -> ToolCreationPlan {
        await planCreationForRequest(
            ToolCreationPlanningRequest(
                userPrompt: userPrompt,
                imageGenerationProvider: imageGenerationProvider,
                invoker: invoker
            )
        )
    }

    func planEdit(
        userPrompt: String,
        toolName: String,
        currentSettings: ToolGenerationSettings,
        invoker: ToolLanguageModelInvoker
    ) async -> ToolEditPlan {
        await planEditForRequest(
            ToolEditPlanningRequest(
                userPrompt: userPrompt,
                toolName: toolName,
                currentSettings: currentSettings,
                invoker: invoker
            )
        )
    }

    static func fallback() -> Self {
        Self { userPrompt in
            ToolCreationPlan.fallback(for: userPrompt)
        }
    }

    static func live(
        fallbackLanguageModel: (any LanguageModel)? = SystemLanguageModel.default
    ) -> Self {
        Self(
            requestBased: (),
            planCreationForRequest: { request in
                let userPrompt = request.userPrompt
                let fallback = ToolCreationPlan.fallback(for: userPrompt)

                do {
                    return try await Self.generateMetadata(
                        userPrompt: userPrompt,
                        imageGenerationProvider: request.imageGenerationProvider,
                        invoker: request.invoker,
                        fallback: fallback
                    )
                } catch let primaryError {
                    AgentDiagnosticsLog.append(
                        """
                        Tool metadata generation failed with the selected model.
                        prompt: \(AgentDiagnosticsLog.compact(userPrompt, limit: 240))
                        error:
                        \(AgentDiagnosticsLog.renderError(primaryError, limit: 500))
                        """
                    )

                    if let fallbackLanguageModel, fallbackLanguageModel.isAvailable {
                        let fallbackConfiguration = ToolGenerationStageConfiguration(
                            stage: .metadata,
                            languageModel: fallbackLanguageModel,
                            generationOptions: GenerationOptions(
                                maximumResponseTokens: ToolGenerationOptionsResolver
                                    .metadataMaximumResponseTokens
                            ),
                            streaming: ToolGenerationOptionsResolver.defaultStreaming
                        )
                        do {
                            return try await Self.generateMetadata(
                                userPrompt: userPrompt,
                                imageGenerationProvider: request.imageGenerationProvider,
                                invoker: request.invoker.replacingMetadata(
                                    with: fallbackConfiguration
                                ),
                                fallback: fallback
                            )
                        } catch {
                            AgentDiagnosticsLog.append(
                                """
                                Tool metadata generation also failed with the system language model; using fallback tool metadata.
                                prompt: \(AgentDiagnosticsLog.compact(userPrompt, limit: 240))
                                error:
                                \(AgentDiagnosticsLog.renderError(error, limit: 500))
                                """
                            )
                        }
                    }
                    return fallback
                }
            },
            planEditForRequest: { request in
                do {
                    return try await Self.generateEditPlan(request, invoker: request.invoker)
                } catch let primaryError {
                    AgentDiagnosticsLog.append(
                        """
                        Tool edit planning failed with the selected model.
                        prompt: \(AgentDiagnosticsLog.compact(request.userPrompt, limit: 240))
                        error:
                        \(AgentDiagnosticsLog.renderError(primaryError, limit: 500))
                        """
                    )

                    if let fallbackLanguageModel, fallbackLanguageModel.isAvailable {
                        let fallbackConfiguration = ToolGenerationStageConfiguration(
                            stage: .metadata,
                            languageModel: fallbackLanguageModel,
                            generationOptions: GenerationOptions(
                                maximumResponseTokens: ToolGenerationOptionsResolver
                                    .metadataMaximumResponseTokens
                            ),
                            streaming: ToolGenerationOptionsResolver.defaultStreaming
                        )
                        do {
                            return try await Self.generateEditPlan(
                                request,
                                invoker: request.invoker.replacingMetadata(
                                    with: fallbackConfiguration
                                )
                            )
                        } catch {
                            AgentDiagnosticsLog.append(
                                """
                                Tool edit planning also failed with the system language model; preserving current permissions.
                                prompt: \(AgentDiagnosticsLog.compact(request.userPrompt, limit: 240))
                                error:
                                \(AgentDiagnosticsLog.renderError(error, limit: 500))
                                """
                            )
                        }
                    }
                    return .empty
                }
            }
        )
    }

    private static func generateEditPlan(
        _ request: ToolEditPlanningRequest,
        invoker: ToolLanguageModelInvoker
    ) async throws -> ToolEditPlan {
        let session = invoker.makeSession(
            for: .metadata,
            instructions: """
                You plan an edit to an existing generated macOS SwiftUI app.
                Return only permissions newly required by the requested change.
                Select only permissions required by the explicit request, never hypothetical features.
                Do not remove or repeat existing permissions. Use only exact values from the allowed lists.
                Use an empty list when no additional permission in a group is required.
                """
        )
        let response = try await invoker.respond(
            stage: .metadata,
            in: session,
            to: """
                Existing app: \(request.toolName)
                Requested change:
                \(request.userPrompt)

                Existing sandbox permissions:
                \(request.currentSettings.sandboxPermissions.enabledPermissions.map(\.rawValue).joined(separator: ", "))

                Existing resource permissions:
                \(request.currentSettings.resourcePermissions.enabledPermissions.map(\.rawValue).joined(separator: ", "))

                Allowed additionalSandboxPermissions values:
                \(GeneratedAppSandboxPermission.allCases.map(\.rawValue).joined(separator: ", "))

                Allowed additionalResourcePermissions values:
                \(GeneratedAppResourcePermission.allCases.map(\.rawValue).joined(separator: ", "))
                """,
            generating: GeneratedToolEditPlan.self
        )
        return ToolEditPlan(
            additionalSandboxPermissions: GeneratedAppSandboxPermissions(
                response.additionalSandboxPermissions.compactMap(
                    GeneratedAppSandboxPermission.init(rawValue:)
                )
            ),
            additionalResourcePermissions: GeneratedAppResourcePermissions(
                response.additionalResourcePermissions.compactMap(
                    GeneratedAppResourcePermission.init(rawValue:)
                )
            )
        )
    }

    private static func generateMetadata(
        userPrompt: String,
        imageGenerationProvider: ToolImageGenerationProvider,
        invoker: ToolLanguageModelInvoker,
        fallback: ToolCreationPlan
    ) async throws -> ToolCreationPlan {
        let session = invoker.makeSession(
            for: .metadata,
            instructions: metadataInstructions(for: imageGenerationProvider)
        )
        let response = try await invoker.respond(
            stage: .metadata,
            in: session,
            to: Self.metadataPrompt(
                for: userPrompt,
                imageGenerationProvider: imageGenerationProvider
            ),
            generating: GeneratedToolCreationPlan.self
        )
        return Self.metadataSuggestion(response, fallback: fallback)
    }

    nonisolated private static func metadataPrompt(
        for userPrompt: String,
        imageGenerationProvider: ToolImageGenerationProvider
    ) -> String {
        """
            User request:
            \(userPrompt)

            Image prompt mode:
            \(imagePromptModeDescription(for: imageGenerationProvider))

            Allowed menuBarSystemImage values:
            \(ToolMenuBarSymbol.allowedSymbols.joined(separator: ", "))

            Allowed category values:
            \(StoreAppCategory.allCases.map(\.rawValue).joined(separator: ", "))

            Allowed appKind values:
            \(ToolAppKind.allCases.map(\.rawValue).joined(separator: ", "))

            Allowed sandboxPermissions values:
            \(GeneratedAppSandboxPermission.allCases.map(\.rawValue).joined(separator: ", "))

            Allowed resourcePermissions values:
            \(GeneratedAppResourcePermission.allCases.map(\.rawValue).joined(separator: ", "))
            """
    }

    nonisolated private static func metadataInstructions(
        for imageGenerationProvider: ToolImageGenerationProvider
    ) -> String {
        """
            You create compact metadata for a SwiftUI AI coding agent for a macOS app.

            displayName:
            - Must be one or two separate words.
            - Must be Title Case.
            - Must name the user's requested app, task, or workflow, not the icon artwork or symbol.
            - Should feel snappy, playful, and useful for a small macOS app.
            - Do not use punctuation, emoji, or generic suffixes like App or Tool.

            iconPrompt:
            \(imagePromptInstructions(for: imageGenerationProvider))

            menuBarSystemImage:
            - Must be one exact SF Symbol name from the allowed list in the prompt.
            - Choose the closest symbol for the user's requested app.
            - Do not invent names or include variants outside that list.

            category:
            - Must be one exact raw value from the allowed category list in the prompt.
            - Choose the category that best represents the app's primary purpose.
            - Use utilities only when no more specific category applies.

            appKind:
            - Choose menu_bar only for a compact, glanceable utility centered on a quick interaction.
            - Choose window for workflows that need substantial content, navigation, editing space, or multiple controls.
            - Use exactly one allowed raw value.

            sandboxPermissions and resourcePermissions:
            - Select only permissions required to implement the user's explicit request.
            - Do not add permissions for hypothetical future features.
            - Use only exact values from the corresponding allowed lists.
            - Use an empty list when no permission in a group is required.
            """
    }

    nonisolated private static func imagePromptModeDescription(
        for provider: ToolImageGenerationProvider
    ) -> String {
        switch provider {
        case .gemini, .openAI, .ironsmith:
            return "Hosted image generation; visual concept only."
        case .automatic, .imagePlayground, .disabled:
            return "Compact Image Playground-compatible concept."
        }
    }

    nonisolated private static func imagePromptInstructions(
        for provider: ToolImageGenerationProvider
    ) -> String {
        switch provider {
        case .gemini, .openAI, .ironsmith:
            return """
                - Write one concise visual concept of 8 to 20 words.
                - Describe only the concrete subject, any meaningful secondary object, and how they relate or are arranged.
                - Choose a concept specific to the requested app instead of repeating the app name.
                - Do not specify icon shape, canvas, background, palette, materials, lighting, depth, style, rendering quality, legibility, macOS conventions, or generation instructions.
                - Good examples: A small house sheltering a calculator, with one coin orbiting the roofline. A calendar page whose date square becomes a checkmark.
                """
        case .automatic, .imagePlayground, .disabled:
            return """
                - Must be a tiny object phrase, not a sentence or description.
                - Must be 2 to 5 words.
                - Good examples: Calculator in front of house. Gamepad with buttons.
                - Do not mention app icon, macOS, style, text, letters, screenshots, UI, logos, or backgrounds.
                """
        }
    }

    nonisolated private static func metadataSuggestion(
        _ response: GeneratedToolCreationPlan,
        fallback: ToolCreationPlan
    ) -> ToolCreationPlan {
        let displayName = response.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let iconPrompt = response.iconPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let menuBarSystemImage = ToolMenuBarSymbol.validated(response.menuBarSystemImage)
        let category =
            StoreAppCategory(
                rawValue: response.category.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            ?? fallback.category
        return ToolCreationPlan(
            displayName: displayName.isEmpty ? fallback.displayName : displayName,
            iconPrompt: iconPrompt.isEmpty ? fallback.iconPrompt : iconPrompt,
            menuBarSystemImage: menuBarSystemImage,
            category: category,
            suggestedAppKind: ToolAppKind(
                rawValue: response.appKind.trimmingCharacters(in: .whitespacesAndNewlines)
            ) ?? fallback.suggestedAppKind,
            suggestedSandboxPermissions: GeneratedAppSandboxPermissions(
                response.sandboxPermissions.compactMap(
                    GeneratedAppSandboxPermission.init(rawValue:))
            ),
            suggestedResourcePermissions: GeneratedAppResourcePermissions(
                response.resourcePermissions.compactMap(
                    GeneratedAppResourcePermission.init(rawValue:))
            )
        )
    }
}

struct ToolPromptRefinementRequest: Sendable {
    let userPrompt: String
    let appKind: ToolAppKind
    let sandboxEnabled: Bool
    let codingAgent: ToolCodingAgent
    let invoker: ToolLanguageModelInvoker
}

struct ToolPromptRefinementClient: Sendable {
    private var refinePromptForRequest:
        @Sendable (_ request: ToolPromptRefinementRequest) async -> String?

    init(_ refinePrompt: @escaping @Sendable (_ userPrompt: String) async -> String?) {
        self.refinePromptForRequest = { request in
            await refinePrompt(request.userPrompt)
        }
    }

    private init(
        requestBased: Void,
        refinePromptForRequest:
            @escaping @Sendable (_ request: ToolPromptRefinementRequest) async -> String?
    ) {
        self.refinePromptForRequest = refinePromptForRequest
    }

    func refinePrompt(
        userPrompt: String,
        invoker: ToolLanguageModelInvoker,
        appKind: ToolAppKind = .window,
        sandboxEnabled: Bool = true,
        codingAgent: ToolCodingAgent = .ironsmithSpark
    ) async -> String? {
        await refinePromptForRequest(
            ToolPromptRefinementRequest(
                userPrompt: userPrompt,
                appKind: appKind,
                sandboxEnabled: sandboxEnabled,
                codingAgent: codingAgent,
                invoker: invoker
            )
        )
    }

    static func disabled() -> Self {
        Self { _ in nil }
    }

    static func live() -> Self {
        Self(
            requestBased: (),
            refinePromptForRequest: { request in
                do {
                    let session = request.invoker.makeSession(
                        for: .promptRefinement,
                        instructions: promptRefinementInstructions(for: request.codingAgent)
                    )
                    let response = try await request.invoker.respond(
                        stage: .promptRefinement,
                        in: session,
                        to: Self.promptRefinementPrompt(
                            for: request.userPrompt,
                            appKind: request.appKind,
                            sandboxEnabled: request.sandboxEnabled
                        ),
                        generating: String.self
                    )
                    let prompt = cleanedRefinedPrompt(response)
                    if prompt.isEmpty {
                        AgentDiagnosticsLog.append(
                            """
                            Tool prompt refinement returned empty prompt; using original prompt.
                            prompt: \(AgentDiagnosticsLog.compact(request.userPrompt, limit: 240))
                            rawCharacters: \(response.count)
                            """
                        )
                        return nil
                    }

                    AgentDiagnosticsLog.append(
                        """
                        Tool prompt refinement generated.
                        prompt: \(AgentDiagnosticsLog.compact(request.userPrompt, limit: 240))
                        refinedPrompt: \(AgentDiagnosticsLog.compact(prompt, limit: 1_500))
                        """
                    )
                    return prompt
                } catch {
                    AgentDiagnosticsLog.append(
                        """
                        Tool prompt refinement failed; using original prompt.
                        prompt: \(AgentDiagnosticsLog.compact(request.userPrompt, limit: 240))
                        error:
                        \(AgentDiagnosticsLog.renderError(error, limit: 500))
                        """
                    )
                    return nil
                }
            })
    }

    nonisolated private static func promptRefinementPrompt(
        for userPrompt: String,
        appKind: ToolAppKind,
        sandboxEnabled: Bool
    ) -> String {
        """
        Return a plain text prompt to be given to a macOS SwiftUI AI coding agent for the user's request below.

        \(ToolGenerationPrompts.appPresentationContext(appKind: appKind))

        \(ToolGenerationPrompts.sandboxContext(sandboxEnabled: sandboxEnabled))

        User request:
        \(userPrompt)
        """
    }

    nonisolated static func promptRefinementInstructions(
        for codingAgent: ToolCodingAgent
    ) -> String {
        switch codingAgent {
        case .ironsmithSpark:
            return sparkPromptRefinementInstructions
        case .ironsmithFlame, .codex:
            return additivePromptRefinementInstructions
        }
    }

    nonisolated private static let additivePromptRefinementInstructions = """
        You lightly refine a user's app request for a macOS SwiftUI AI coding agent.
        Return only the refined prompt as one concise plain-text paragraph, without markdown, labels, commentary, code, or file names.

        The refined prompt:
        - Must be additive only: preserve every requested feature and constraint without removing, simplifying, replacing, or reprioritizing any part of the request. The user's explicit request takes priority over the defaults below.
        - Should expand the user's request with specific product intent, core features, expected interactions, layout and visual design direction, and useful states such as empty, loading, complete, or error states when relevant.
        - Must preserve whether the generated app is a window app or menu bar app.
        - For menu bar apps, describe a compact menu bar popover utility with concise controls, short labels, bounded size, and a focused quick workflow. Do not expand the request into a full-size desktop app, dashboard, sidebar layout, multi-pane workflow, or large complicated UI unless explicitly requested.
        - For window apps, describe a normal native macOS window app layout when appropriate.
        - Prefer one polished primary workflow over many secondary workflows while preserving all requested features.
        - If a requested feature can be implemented with a native Apple framework such as Vision for OCR, PDFKit for PDFs, or AVFoundation for media, explicitly call it out.
        - Must describe a self-contained Mac app unless the user explicitly requests external services.
        - May include local persistence, local files, import/export, and open/save flows when they make sense.
        - Must not add or imply a separate backend service, custom server component, account system, iCloud, CloudKit, push notifications, analytics, subscriptions, or cross-device sync unless explicitly requested.
        - Should emphasize a native macOS feel using appropriate SwiftUI macOS patterns and system controls.
        - For games, drawing canvases, and highly visual toys, the refined prompt may describe custom graphics and game-like UI, but it should keep the app local-only unless the user requests network features and remain sensible for macOS pointer, keyboard, and window behavior.
        """

    nonisolated private static let sparkPromptRefinementInstructions = """
        You refine a user's app request into a compact build prompt for a macOS SwiftUI AI coding agent.
        Return only the refined prompt as plain text.
        Do not return JSON, code, markdown, bullets, labels, commentary, code, or file names.

        The refined prompt:
        - Must be one short paragraph.
        - Must be under 750 characters.
        - Should expand the user's request with specific product intent, core features, expected interactions, layout and visual design direction, and useful states such as empty, loading, complete, or error states when relevant.
        - Treat every request as a first-version prototype unless the user explicitly asks for a full-featured app.
        - Must preserve whether the generated app is a window app or menu bar app.
        - For menu bar apps, describe a compact menu bar popover utility with concise controls, short labels, bounded size, and a focused quick workflow. Do not expand the request into a full-size desktop app, dashboard, sidebar layout, multi-pane workflow, or large complicated UI.
        - For window apps, describe a normal native macOS window app layout when appropriate.
        - Choose at most 3 core user-facing features.
        - If the user lists many features, preserve the most important ones and explicitly simplify or omit the rest.
        - Prefer one polished primary workflow over many secondary workflows.
        - If a requested feature can be implemented with a native Apple framework such as Vision for OCR, PDFKit for PDFs, AVFoundation for media etc., explicitly call it out.
        - Must describe a self-contained Mac app, with direct internet requests allowed only when the user's request requires them.
        - May include local persistence, local files, import/export, and open/save flows when they make sense.
        - Must not mention or imply a separate backend service, custom server component, account system, iCloud, CloudKit, push notifications, analytics, subscriptions, or cross-device sync.
        - Should emphasize a native macOS feel using appropriate SwiftUI macOS patterns and system controls.
        - For games, drawing canvases, and highly visual toys, refinedPrompt may describe custom graphics and game-like UI, but it should still keep the app local-only and sensible for macOS pointer, keyboard, and window behavior.
        """

    nonisolated private static func cleanedRefinedPrompt(_ prompt: String) -> String {
        prompt
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension ToolCreationPlan {
    nonisolated static func fallback(for userPrompt: String) -> ToolCreationPlan {
        let displayName = ToolNameSanitizer.displayName(fromPrompt: userPrompt)
        return ToolCreationPlan(
            displayName: displayName,
            iconPrompt: "",
            menuBarSystemImage: ToolMenuBarSymbol.fallback,
            category: .utilities
        )
    }
}
