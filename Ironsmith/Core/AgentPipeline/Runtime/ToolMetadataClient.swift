import AnyLanguageModel
import Foundation

struct ToolMetadataSuggestion: Equatable, Sendable {
    let displayName: String
    let iconPrompt: String
    let menuBarSystemImage: String

    nonisolated init(
        displayName: String,
        iconPrompt: String,
        menuBarSystemImage: String = ToolMenuBarSymbol.fallback
    ) {
        self.displayName = displayName
        self.iconPrompt = iconPrompt
        self.menuBarSystemImage = ToolMenuBarSymbol.validated(menuBarSystemImage)
    }
}

@Generable(description: "Metadata for a small generated macOS app.")
struct GeneratedToolMetadata {
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
}

extension GeneratedToolMetadata {
    nonisolated init(displayName: String, iconPrompt: String) {
        self.init(
            displayName: displayName,
            iconPrompt: iconPrompt,
            menuBarSystemImage: ToolMenuBarSymbol.fallback
        )
    }
}

struct ToolMetadataRequest: Sendable {
    let userPrompt: String
    let imageGenerationProvider: ToolImageGenerationProvider
    let invoker: ToolLanguageModelInvoker
}

struct ToolMetadataClient: Sendable {
    private var suggestMetadataForRequest:
        @Sendable (_ request: ToolMetadataRequest) async -> ToolMetadataSuggestion

    init(
        _ suggestMetadata:
            @escaping @Sendable (_ userPrompt: String) async -> ToolMetadataSuggestion
    ) {
        self.suggestMetadataForRequest = { request in
            await suggestMetadata(request.userPrompt)
        }
    }

    private init(
        requestBased: Void,
        suggestMetadataForRequest:
            @escaping @Sendable (_ request: ToolMetadataRequest) async -> ToolMetadataSuggestion
    ) {
        self.suggestMetadataForRequest = suggestMetadataForRequest
    }

    func suggestMetadata(
        userPrompt: String,
        imageGenerationProvider: ToolImageGenerationProvider = .imagePlayground,
        invoker: ToolLanguageModelInvoker
    ) async -> ToolMetadataSuggestion {
        await suggestMetadataForRequest(
            ToolMetadataRequest(
                userPrompt: userPrompt,
                imageGenerationProvider: imageGenerationProvider,
                invoker: invoker
            )
        )
    }

    static func fallback() -> Self {
        Self { userPrompt in
            ToolMetadataSuggestion.fallback(for: userPrompt)
        }
    }

    static func live(
        fallbackLanguageModel: (any LanguageModel)? = SystemLanguageModel.default
    ) -> Self {
        Self(
            requestBased: (),
            suggestMetadataForRequest: { request in
                let userPrompt = request.userPrompt
                let fallback = ToolMetadataSuggestion.fallback(for: userPrompt)

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
            })
    }

    private static func generateMetadata(
        userPrompt: String,
        imageGenerationProvider: ToolImageGenerationProvider,
        invoker: ToolLanguageModelInvoker,
        fallback: ToolMetadataSuggestion
    ) async throws -> ToolMetadataSuggestion {
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
            generating: GeneratedToolMetadata.self
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
        _ response: GeneratedToolMetadata,
        fallback: ToolMetadataSuggestion
    ) -> ToolMetadataSuggestion {
        let displayName = response.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let iconPrompt = response.iconPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let menuBarSystemImage = ToolMenuBarSymbol.validated(response.menuBarSystemImage)
        return ToolMetadataSuggestion(
            displayName: displayName.isEmpty ? fallback.displayName : displayName,
            iconPrompt: iconPrompt.isEmpty ? fallback.iconPrompt : iconPrompt,
            menuBarSystemImage: menuBarSystemImage
        )
    }
}

struct ToolPromptRefinementRequest: Sendable {
    let userPrompt: String
    let appKind: ToolAppKind
    let sandboxEnabled: Bool
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
        sandboxEnabled: Bool = true
    ) async -> String? {
        await refinePromptForRequest(
            ToolPromptRefinementRequest(
                userPrompt: userPrompt,
                appKind: appKind,
                sandboxEnabled: sandboxEnabled,
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
                        instructions: promptRefinementInstructions
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

    nonisolated private static let promptRefinementInstructions = """
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
        - The request states whether the generated app uses the app sandbox. Treat that as runtime context, not a reason to reduce useful scope. If sandboxed, preserve the useful workflow and phrase it with sandbox-compatible macOS patterns. If not sandboxed, the app may use what it needs to complete the user's ask, but must not make changes to the user's system unless the user asks for them or the request requires them.
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

extension ToolMetadataSuggestion {
    nonisolated static func fallback(for userPrompt: String) -> ToolMetadataSuggestion {
        let displayName = ToolNameSanitizer.displayName(fromPrompt: userPrompt)
        return ToolMetadataSuggestion(
            displayName: displayName,
            iconPrompt: "",
            menuBarSystemImage: ToolMenuBarSymbol.fallback
        )
    }
}
