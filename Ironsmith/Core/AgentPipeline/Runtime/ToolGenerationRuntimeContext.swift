import AnyLanguageModel
import Foundation

enum ToolLanguageModelResponderError: LocalizedError {
    case emptyStream(ToolGenerationStage)

    var errorDescription: String? {
        switch self {
        case .emptyStream:
            return "The AI model returned an empty stream."
        }
    }
}

struct ToolLanguageModelResponder {
    let afterLanguageModelInvocation: @MainActor @Sendable () async -> Void

    init(afterLanguageModelInvocation: @escaping @MainActor @Sendable () async -> Void = {}) {
        self.afterLanguageModelInvocation = afterLanguageModelInvocation
    }

    func respond<Content, PromptContent>(
        stage: ToolGenerationStage,
        in session: LanguageModelSession,
        to prompt: PromptContent,
        generating type: Content.Type = Content.self,
        options: GenerationOptions,
        streaming: Bool = ToolGenerationOptionsResolver.defaultStreaming,
        onSnapshot: (@MainActor (Content.PartiallyGenerated) throws -> Void)? = nil
    ) async throws -> Content
    where Content: Generable, Content.PartiallyGenerated: Sendable, PromptContent: PromptRepresentable {
        do {
            let content: Content
            if streaming {
                content = try await streamResponse(
                    stage: stage,
                    in: session,
                    to: prompt,
                    generating: type,
                    options: options,
                    onSnapshot: onSnapshot
                )
            } else {
                let response = try await session.respond(
                    to: Prompt(prompt),
                    generating: type,
                    options: options
                )
                content = response.content
                if let onSnapshot {
                    try await MainActor.run {
                        try onSnapshot(content.asPartiallyGenerated())
                    }
                }
            }

            await afterLanguageModelInvocation()
            return content
        } catch {
            await afterLanguageModelInvocation()
            throw error
        }
    }

    private func streamResponse<Content, PromptContent>(
        stage: ToolGenerationStage,
        in session: LanguageModelSession,
        to prompt: PromptContent,
        generating type: Content.Type,
        options: GenerationOptions,
        onSnapshot: (@MainActor (Content.PartiallyGenerated) throws -> Void)?
    ) async throws -> Content
    where Content: Generable, Content.PartiallyGenerated: Sendable, PromptContent: PromptRepresentable {
        var latestRawContent: GeneratedContent?
        let stream = session.streamResponse(
            to: Prompt(prompt),
            generating: type,
            options: options
        )
        for try await snapshot in stream {
            latestRawContent = snapshot.rawContent
            if let onSnapshot {
                try await MainActor.run {
                    try onSnapshot(snapshot.content)
                }
            }
        }

        guard let latestRawContent else {
            throw ToolLanguageModelResponderError.emptyStream(stage)
        }
        return try Content(latestRawContent)
    }
}

struct ToolGenerationRuntimeDependencies {
    let toolsDirectoryURL: URL
    let fileClient: AgentFileClient
    let processClient: SwiftPackageProcessClient
    let appBundleClient: ToolAppBundleClient
    let iconClient: ToolIconClient
    let metadataClient: ToolMetadataClient
    let promptRefinementClient: ToolPromptRefinementClient
    let versionBackupClient: ToolVersionBackupClient
    let packageMaterializer: ToolPackageMaterializer

    init(
        toolsDirectoryURL: URL,
        fileClient: AgentFileClient,
        processClient: SwiftPackageProcessClient,
        appBundleClient: ToolAppBundleClient,
        iconClient: ToolIconClient = .noOp,
        metadataClient: ToolMetadataClient = .fallback(),
        promptRefinementClient: ToolPromptRefinementClient = .disabled(),
        versionBackupClient: ToolVersionBackupClient,
        packageMaterializer: ToolPackageMaterializer? = nil
    ) {
        self.toolsDirectoryURL = toolsDirectoryURL
        self.fileClient = fileClient
        self.processClient = processClient
        self.appBundleClient = appBundleClient
        self.iconClient = iconClient
        self.metadataClient = metadataClient
        self.promptRefinementClient = promptRefinementClient
        self.versionBackupClient = versionBackupClient
        self.packageMaterializer = packageMaterializer ?? ToolPackageMaterializer(fileClient: fileClient)
    }

    static func live(
        toolsDirectoryURL: URL = IronsmithPaths.toolsDirectory,
        fileClient: AgentFileClient = .live,
        processClient: SwiftPackageProcessClient = .live,
        appBundleClient: ToolAppBundleClient = .live(),
        iconClient: ToolIconClient = .live(),
        metadataClient: ToolMetadataClient = .live(),
        promptRefinementClient: ToolPromptRefinementClient = .live(),
        versionBackupClient: ToolVersionBackupClient = .live,
        packageMaterializer: ToolPackageMaterializer? = nil
    ) -> Self {
        Self(
            toolsDirectoryURL: toolsDirectoryURL,
            fileClient: fileClient,
            processClient: processClient,
            appBundleClient: appBundleClient,
            iconClient: iconClient,
            metadataClient: metadataClient,
            promptRefinementClient: promptRefinementClient,
            versionBackupClient: versionBackupClient,
            packageMaterializer: packageMaterializer
        )
    }
}

struct ToolGenerationRuntimeContext {
    let codingAgent: ToolGenerationStageConfiguration
    let promptRefinement: ToolGenerationStageConfiguration
    let metadata: ToolGenerationStageConfiguration
    let pipelineConfiguration: ToolGenerationPipelineConfiguration
    let repairStrategy: ToolRepairStrategy
    let toolsDirectoryURL: URL
    let fileClient: AgentFileClient
    let processClient: SwiftPackageProcessClient
    let appBundleClient: ToolAppBundleClient
    let iconClient: ToolIconClient
    let metadataClient: ToolMetadataClient
    let promptRefinementClient: ToolPromptRefinementClient
    let promptRefinementEnabled: Bool
    let versionBackupClient: ToolVersionBackupClient
    let packageMaterializer: ToolPackageMaterializer
    let afterLanguageModelInvocation: @MainActor @Sendable () async -> Void

    var languageModel: any LanguageModel {
        codingAgent.languageModel
    }

    init(
        languageModelContext: AgentLanguageModelContext,
        dependencies: ToolGenerationRuntimeDependencies
    ) {
        self.codingAgent = languageModelContext.codingAgent
        self.promptRefinement = languageModelContext.promptRefinement
        self.metadata = languageModelContext.metadata
        self.pipelineConfiguration = languageModelContext.pipelineConfiguration
        self.repairStrategy = languageModelContext.repairStrategy
        self.toolsDirectoryURL = dependencies.toolsDirectoryURL
        self.fileClient = dependencies.fileClient
        self.processClient = dependencies.processClient
        self.appBundleClient = dependencies.appBundleClient
        self.iconClient = dependencies.iconClient
        self.metadataClient = dependencies.metadataClient
        self.promptRefinementClient = dependencies.promptRefinementClient
        self.promptRefinementEnabled = languageModelContext.promptRefinementEnabled
        self.versionBackupClient = dependencies.versionBackupClient
        self.packageMaterializer = dependencies.packageMaterializer
        self.afterLanguageModelInvocation = languageModelContext.afterLanguageModelInvocation
    }

    func respond<Content, PromptContent>(
        stage: ToolGenerationStage = .codingAgent,
        in session: LanguageModelSession,
        to prompt: PromptContent,
        generating type: Content.Type = Content.self,
        streaming: Bool? = nil,
        onSnapshot: (@MainActor (Content.PartiallyGenerated) throws -> Void)? = nil
    ) async throws -> Content
    where Content: Generable, Content.PartiallyGenerated: Sendable, PromptContent: PromptRepresentable {
        let configuration = configuration(for: stage)
        return try await ToolLanguageModelResponder(
            afterLanguageModelInvocation: afterLanguageModelInvocation
        ).respond(
            stage: stage,
            in: session,
            to: prompt,
            generating: type,
            options: configuration.generationOptions,
            streaming: streaming ?? configuration.streaming,
            onSnapshot: onSnapshot
        )
    }

    func streamText<PromptContent>(
        stage: ToolGenerationStage = .codingAgent,
        in session: LanguageModelSession,
        to prompt: PromptContent,
        onSnapshot: @escaping @MainActor (String) throws -> Void
    ) async throws -> String where PromptContent: PromptRepresentable {
        try await respond(
            stage: stage,
            in: session,
            to: prompt,
            generating: String.self,
            onSnapshot: onSnapshot
        )
    }

    func configuration(for stage: ToolGenerationStage) -> ToolGenerationStageConfiguration {
        switch stage {
        case .codingAgent:
            codingAgent
        case .promptRefinement:
            promptRefinement
        case .metadata:
            metadata
        }
    }

    func makeUniquePackageRoot(displayName: String) throws -> URL {
        try packageMaterializer.makeUniquePackageRoot(
            displayName: displayName,
            toolsDirectoryURL: toolsDirectoryURL
        )
    }

    func write(
        _ content: String,
        to path: String,
        packageRootURL: URL
    ) throws {
        try fileClient.writeString(content, packageFileURL(for: path, packageRootURL: packageRootURL))
    }

    func readIfPresent(_ path: String, packageRootURL: URL) throws -> String {
        let url = try packageFileURL(for: path, packageRootURL: packageRootURL)
        guard fileClient.fileExists(url) else { return "" }
        return try fileClient.readString(url)
    }

    func packageFileURL(for path: String, packageRootURL: URL) throws -> URL {
        try ToolPackageLayout.packageFileURL(for: path, packageRootURL: packageRootURL)
    }

    func jsonString(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func cleanedText(_ response: String) -> String {
        response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cleanedSource(_ response: String) -> String {
        let strippedThinking = stripThinkingBlocks(from: response)
        let trimmed = strippedThinking.trimmingCharacters(in: .whitespacesAndNewlines)
        let unfenced: String
        if trimmed.hasPrefix("```") {
            let lines = trimmed.components(separatedBy: .newlines)
            var remaining = Array(lines.dropFirst())
            if let last = remaining.last, last.trimmingCharacters(in: .whitespacesAndNewlines) == "```" {
                remaining.removeLast()
            }
            unfenced = remaining.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            unfenced = trimmed
        }

        let lines = unfenced.components(separatedBy: .newlines)
        if let startIndex = lines.firstIndex(where: { isLikelySwiftSourceLine($0) }) {
            return lines[startIndex...]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return unfenced
    }

    private static func stripThinkingBlocks(from response: String) -> String {
        var cleaned = response
        let patterns = [
            #"<think>[\s\S]*?</think>"#,
            #"<thinking>[\s\S]*?</thinking>"#,
            #"<reasoning>[\s\S]*?</reasoning>"#,
            #"<\|channel\>(thought|analysis)[\s\S]*?<channel\|>"#
        ]

        for pattern in patterns {
            cleaned = cleaned.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        return cleaned
    }

    private static func isLikelySwiftSourceLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        return trimmed.hasPrefix("import ")
            || trimmed.hasPrefix("@main")
            || trimmed.hasPrefix("struct ")
            || trimmed.hasPrefix("final class ")
            || trimmed.hasPrefix("class ")
            || trimmed.hasPrefix("enum ")
            || trimmed.hasPrefix("protocol ")
            || trimmed.hasPrefix("actor ")
            || trimmed.hasPrefix("extension ")
            || trimmed.hasPrefix("typealias ")
            || trimmed.hasPrefix("func ")
            || trimmed.hasPrefix("//")
            || trimmed.hasPrefix("#if")
    }
}

enum ToolGenerationError: LocalizedError, Equatable {
    case emptyPrompt
    case compileFailed(String)
    case invalidRepairPatch
    case noRepairPatchCandidate
    case stoppedToSaveTokens(String)

    var errorDescription: String? {
        switch self {
        case .emptyPrompt:
            return "Enter a prompt before building an app."
        case .compileFailed(let output):
            return output.isEmpty ? "The generated package did not compile." : output
        case .invalidRepairPatch:
            return "The repair model returned an invalid patch."
        case .noRepairPatchCandidate:
            return "No deterministic repair patch was available."
        case .stoppedToSaveTokens(let message):
            return message
        }
    }

    var isResumableStop: Bool {
        switch self {
        case .stoppedToSaveTokens:
            return true
        case .emptyPrompt, .compileFailed, .invalidRepairPatch, .noRepairPatchCandidate:
            return false
        }
    }

    static func isContextWindowExceeded(_ error: any Error) -> Bool {
        let description = error.localizedDescription.lowercased()
        let reflected = String(reflecting: error).lowercased()
        return Self.contextWindowNeedles.contains { needle in
            description.contains(needle) || reflected.contains(needle)
        }
    }

    private static let contextWindowNeedles = [
        "context window",
        "context length",
        "context size",
        "maximum context",
        "exceeds context",
        "exceeded context",
        "too many tokens",
        "token limit"
    ]
}
