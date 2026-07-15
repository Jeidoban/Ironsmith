import AnyLanguageModel
import Foundation
import ImageIO
import SwiftData
import Testing
@testable import Ironsmith

typealias StoredTool = Ironsmith.Tool

struct AgentPipelineTests {}

extension AgentPipelineTests {
    static func makeRuntime(
        languageModel: any LanguageModel,
        generationOptions: GenerationOptions = GenerationOptions(),
        pipelineConfiguration: ToolGenerationPipelineConfiguration = .ironsmithSpark(repairStrategy: .deterministicOnly),
        toolsDirectoryURL: URL,
        fileClient: AgentFileClient = .live,
        processClient: SwiftPackageProcessClient = .live,
        appBundleClient: ToolAppBundleClient = .noOp(),
        iconClient: ToolIconClient = .noOp,
        metadataClient: ToolMetadataClient = .fallback(),
        promptRefinementClient: ToolPromptRefinementClient = .disabled(),
        promptRefinementEnabled: Bool = true,
        versionBackupClient: ToolVersionBackupClient = .live,
        codexAgentClient: CodexAgentClient = .unconfigured,
        codingAgentModelIdentifier: String = "",
        codexAgentAuthentication: CodexAgentAuthentication? = nil,
        afterLanguageModelInvocation: @escaping @MainActor @Sendable () async -> Void = {}
    ) -> SingleFileToolGenerationRuntime {
        let languageModelContext = AgentLanguageModelContext(
            languageModel: languageModel,
            generationOptions: generationOptions,
            pipelineConfiguration: pipelineConfiguration,
            promptRefinementEnabled: promptRefinementEnabled,
            codingAgentModelIdentifier: codingAgentModelIdentifier,
            codexAgentAuthentication: codexAgentAuthentication,
            afterLanguageModelInvocation: afterLanguageModelInvocation
        )
        let dependencies = ToolGenerationRuntimeDependencies(
            toolsDirectoryURL: toolsDirectoryURL,
            fileClient: fileClient,
            processClient: processClient,
            appBundleClient: appBundleClient,
            iconClient: iconClient,
            metadataClient: metadataClient,
            promptRefinementClient: promptRefinementClient,
            versionBackupClient: versionBackupClient,
            codexAgentClient: codexAgentClient
        )
        return SingleFileToolGenerationRuntime(
            context: ToolGenerationRuntimeContext(
                languageModelContext: languageModelContext,
                dependencies: dependencies
            )
        )
    }

    static func makeInvoker(
        languageModel: any LanguageModel,
        generationOptions: GenerationOptions = GenerationOptions(),
        streaming: Bool = ToolGenerationOptionsResolver.defaultStreaming,
        afterLanguageModelInvocation: @escaping @MainActor @Sendable () async -> Void = {}
    ) -> ToolLanguageModelInvoker {
        let codingAgent = ToolGenerationStageConfiguration(
            stage: .codingAgent,
            languageModel: languageModel,
            generationOptions: generationOptions,
            streaming: streaming
        )
        return ToolLanguageModelInvoker(
            codingAgent: codingAgent,
            promptRefinement: ToolGenerationStageConfiguration(
                stage: .promptRefinement,
                languageModel: languageModel,
                generationOptions: generationOptions,
                streaming: streaming
            ),
            metadata: ToolGenerationStageConfiguration(
                stage: .metadata,
                languageModel: languageModel,
                generationOptions: generationOptions,
                streaming: streaming
            ),
            afterLanguageModelInvocation: afterLanguageModelInvocation
        )
    }

    static func simpleContentViewSource(text: String) -> String {
        """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                Text("\(text)")
            }
        }
        """
    }

    static func sourceWithMissingMember(_ member: String) -> String {
        """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                Text("Broken").\(member)()
            }
        }
        """
    }

    @MainActor
    static func inferenceStore(languageModel: any LanguageModel = EmptyLanguageModel()) -> InferenceStore {
        let provider = ProviderCatalog.makeProvider(for: .local)!
        let model = ModelConfig(
            identifier: ModelConfig.appleFoundationIdentifier,
            displayName: "Apple Foundation Model",
            providerIdentifier: ProviderConfig.localProviderIdentifier,
            source: .appleFoundation,
            installState: .builtIn
        )
        let store = InferenceStore(
            dependencies: InferenceDependencies(
                credentialClient: CredentialClient(
                    loadAPIKey: { _ in nil },
                    saveAPIKey: { _, _ in },
                    deleteAPIKey: { _ in }
                ),
                remoteModelClient: RemoteModelClient { _, _ in [] },
                localModelClient: LocalModelClient(
                    makeHubAPI: {
                        fatalError("makeHubAPI should not be used in agent pipeline tests")
                    },
                    downloadModel: { _, _ in URL(fileURLWithPath: "/tmp/model") },
                    deleteModel: { _ in }
                ),
                ollamaClient: .noOp(),
                languageModelClient: LanguageModelClient(
                    makeLanguageModel: { _, _ in languageModel }
                )
            ),
            generationPreferences: Self.generationPreferences(),
            appleFoundationModelPreferenceStore: Self.appleFoundationModelPreferenceStore()
        )
        store.providers = [provider]
        store.persistedModels = [model]
        store.selectedModelID = model.selectionIdentifier
        return store
    }

    @MainActor
    static func generationPreferences() -> GenerationPreferencesStore {
        let suiteName = "IronsmithTests.AgentPipeline.GenerationPreferences.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        return GenerationPreferencesStore(userDefaults: userDefaults)
    }

    static func appleFoundationModelPreferenceStore() -> AppleFoundationModelPreferenceStore {
        let suiteName = "IronsmithTests.AgentPipeline.AppleFoundation.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        let store = AppleFoundationModelPreferenceStore(userDefaults: userDefaults)
        store.isEnabled = true
        return store
    }

    static func eventually(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        _ predicate: @escaping () async -> Bool
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    static func makeIsolatedUserDefaults() throws -> UserDefaults {
        let suiteName = "IronsmithTests.AgentPipeline.DiagnosticsLog.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        return userDefaults
    }

    static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ironsmith-agent-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func plistDictionary(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try #require(plist as? [String: Any])
    }

    static func writePlistDictionary(_ dictionary: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
    }

    static func imagePixelSize(at url: URL) throws -> (width: Int, height: Int) {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)
        return (width, height)
    }

    @MainActor
    static func makeExistingTool(
        toolsDirectory: URL,
        executableName: String,
        source: String
    ) throws -> StoredTool {
        let packageRoot = toolsDirectory.appendingPathComponent(executableName, isDirectory: true)
        let layout = ToolPackageLayout(packageRootURL: packageRoot, executableName: executableName)

        try FileManager.default.createDirectory(at: layout.sourceDirectoryURL, withIntermediateDirectories: true)
        try layout.packageManifestContent().write(to: layout.packageManifestURL, atomically: true, encoding: .utf8)
        try layout.fixedAppEntrySource().write(
            to: packageRoot.appendingPathComponent(layout.appEntrySourcePath),
            atomically: true,
            encoding: .utf8
        )
        try source.write(
            to: packageRoot.appendingPathComponent(layout.contentViewSourcePath),
            atomically: true,
            encoding: .utf8
        )
        return StoredTool(name: executableName, executableName: executableName, packageRootPath: packageRoot.path)
    }

    static func successfulProcessClient() -> SwiftPackageProcessClient {
        SwiftPackageProcessClient(
            build: { _ in
                SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
            },
            showBinPath: { packageRoot in
                packageRoot.appendingPathComponent(".build/debug", isDirectory: true)
            },
            launch: { _ in },
            stripQuarantine: { _ in }
        )
    }

    static func contentViewURL(for result: ToolGenerationResult) -> URL {
        result.packageRootURL.appendingPathComponent("Sources/\(result.executableName)/ContentView.swift")
    }

    nonisolated static func generatedContentViewURL(in packageRoot: URL) -> URL? {
        let sourcesURL = packageRoot.appendingPathComponent("Sources", isDirectory: true)
        guard let sourceDirectories = try? FileManager.default.contentsOfDirectory(
            at: sourcesURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return sourceDirectories
            .first { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }?
            .appendingPathComponent("ContentView.swift")
    }

    static let originalEditableSource = """
    import SwiftUI

    struct ContentView: View {
        var body: some View {
            Text("old")
        }
    }
    """

    static let renameOldToNewPatch = """
    <<<<<<< SEARCH
            Text("old")
    =======
            Text("new")
    >>>>>>> REPLACE
    """

    static let breakOldTextPatch = """
    <<<<<<< SEARCH
            Text("old")
    =======
            Text("broken").definitelyNotReal()
    >>>>>>> REPLACE
    """
}

actor AppBundleCapture {
    private(set) var builtRequests: [ToolAppBundleRequest] = []
    private(set) var exportedRequests: [ToolAppBundleRequest] = []
    private(set) var launchedURL: URL?
    private(set) var terminatedURL: URL?
    private var runningURL: URL?

    func recordBuild(_ request: ToolAppBundleRequest) {
        builtRequests.append(request)
    }

    func recordExport(_ request: ToolAppBundleRequest) {
        exportedRequests.append(request)
    }

    func recordLaunch(_ url: URL) {
        launchedURL = url
        runningURL = url
    }

    func recordTermination(_ url: URL) {
        terminatedURL = url
        if runningURL == url {
            runningURL = nil
        }
    }

    func isRunning(_ url: URL) -> Bool {
        runningURL == url
    }
}

actor ToolRunCapture {
    private(set) var ranToolIDs: [UUID] = []

    func record(_ tool: StoredTool) {
        ranToolIDs.append(tool.id)
    }
}

actor BundleProcessCapture {
    private(set) var releaseBuildPackageRoot: URL?
    private(set) var signedAppURL: URL?
    private(set) var signedEntitlementsURL: URL?
    private(set) var verifiedAppURL: URL?
    private(set) var strippedURL: URL?

    func recordReleaseBuild(_ url: URL) {
        releaseBuildPackageRoot = url
    }

    func recordSign(appURL: URL, entitlementsURL: URL?) {
        signedAppURL = appURL
        signedEntitlementsURL = entitlementsURL
    }

    func recordVerify(_ url: URL) {
        verifiedAppURL = url
    }

    func recordStripped(_ url: URL) {
        strippedURL = url
    }
}

actor FormatCapture {
    private(set) var formattedURLs: [URL] = []

    func record(_ url: URL) {
        formattedURLs.append(url)
    }
}

actor GenerationCapture {
    private(set) var prompt: String?
    private(set) var existingToolID: UUID?
    private(set) var settings: ToolGenerationSettings?
    private(set) var repairStrategy: ToolRepairStrategy?

    func record(_ request: ToolGenerationRequest) {
        prompt = request.prompt
        existingToolID = request.existingTool?.id
        settings = request.settings
        repairStrategy = request.languageModelContext.repairStrategy
    }
}

actor LanguageModelInvocationCapture {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

actor CancellationCapture {
    private(set) var hasStarted = false
    private(set) var wasCancelled = false

    func recordStarted() {
        hasStarted = true
    }

    func recordCancelled() {
        wasCancelled = true
    }
}

actor PromptCapture {
    private(set) var prompts: [String] = []

    func record(_ prompt: Prompt) {
        prompts.append(String(describing: prompt))
    }

    func record(_ promptDescription: String) {
        prompts.append(promptDescription)
    }
}

actor GenerationOptionsCapture {
    private(set) var options: [GenerationOptions] = []

    func record(_ options: GenerationOptions) {
        self.options.append(options)
    }
}

actor InvocationCapture {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

actor StructuredMetadataResponse {
    private let metadata: GeneratedToolMetadata?
    private let error: (any Error)?
    private(set) var prompts: [String] = []
    private(set) var options: [GenerationOptions] = []

    init(metadata: GeneratedToolMetadata? = nil, error: (any Error)? = nil) {
        self.metadata = metadata
        self.error = error
    }

    func next<Content>(
        prompt: Prompt,
        generating type: Content.Type,
        options: GenerationOptions
    ) throws -> LanguageModelSession.Response<Content> where Content: Generable {
        prompts.append(String(describing: prompt))
        self.options.append(options)

        if let error {
            throw error
        }

        guard type == GeneratedToolMetadata.self, let metadata else {
            throw FakeAgentError.unsupportedStructuredGeneration
        }

        return LanguageModelSession.Response(
            content: metadata as! Content,
            rawContent: metadata.generatedContent,
            transcriptEntries: []
        )
    }
}

struct StructuredMetadataLanguageModel: LanguageModel {
    typealias UnavailableReason = Never

    let response: StructuredMetadataResponse

    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        try await response.next(prompt: prompt, generating: type, options: options)
    }

    func streamResponse<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        let response = response
        return LanguageModelSession.ResponseStream(
            stream: AsyncThrowingStream { continuation in
                Task {
                    do {
                        let generated = try await response.next(
                            prompt: prompt,
                            generating: type,
                            options: options
                        )
                        continuation.yield(
                            .init(
                                content: generated.content.asPartiallyGenerated(),
                                rawContent: generated.rawContent
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

actor LanguageModelResponseQueue {
    private var responses: [String]
    private(set) var count = 0

    init(_ responses: [String]) {
        self.responses = responses
    }

    func next() throws -> String {
        guard !responses.isEmpty else {
            throw FakeAgentError.missingResponse
        }
        count += 1
        return responses.removeFirst()
    }
}

actor BudgetExhaustionResponses {
    private let brokenSource: String
    private let regeneratedSource: String
    private(set) var generationCount = 0
    private(set) var repairCount = 0

    init(brokenSource: String, regeneratedSource: String) {
        self.brokenSource = brokenSource
        self.regeneratedSource = regeneratedSource
    }

    func next(_ prompt: Prompt) throws -> String {
        if prompt.description.contains("Build failed for ContentView.swift.") {
            repairCount += 1
            return """
            <<<<<<< SEARCH
                        Text("Broken \(repairCount)").missing\(repairCount)()
            =======
                        Text("Fixed \(repairCount)")
            >>>>>>> REPLACE
            """
        }

        generationCount += 1
        return generationCount == 1 ? brokenSource : regeneratedSource
    }
}

actor ContextWindowThenSuccess {
    private let success: String
    private(set) var count = 0

    init(success: String) {
        self.success = success
    }

    func next() throws -> String {
        count += 1
        if count == 1 {
            throw FakeAgentError.contextWindow
        }
        return success
    }
}

actor BuildFailureThenSuccess {
    private let executableName: String
    private(set) var count = 0

    init(executableName: String) {
        self.executableName = executableName
    }

    func next(packageRoot: URL) -> SwiftPackageBuildResult {
        count += 1
        guard count == 1 else {
            return SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
        }

        let output = """
        \(packageRoot.path)/Sources/\(executableName)/ContentView.swift:5:25: error: value of type 'Text' has no member 'definitelyNotReal'
        """
        return SwiftPackageBuildResult(succeeded: false, stdout: output, stderr: "", terminationStatus: 1)
    }
}

actor DeterministicSpacingBuilds {
    private let executableName: String
    private let repeatedDiagnosticCount: Int
    private(set) var count = 0

    init(executableName: String, repeatedDiagnosticCount: Int) {
        self.executableName = executableName
        self.repeatedDiagnosticCount = repeatedDiagnosticCount
    }

    func next(packageRoot: URL) -> SwiftPackageBuildResult {
        count += 1
        let contentViewURL = packageRoot.appendingPathComponent("Sources/\(executableName)/ContentView.swift")
        let source = (try? String(contentsOf: contentViewURL, encoding: .utf8)) ?? ""
        guard let line = source.lineNumber(containing: "newIdx< tokens.count") else {
            return SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
        }

        let diagnostic = """
        \(contentViewURL.path):\(line):38: error: expected '{' after 'if' condition
        \(line) |                             if newIdx< tokens.count {
        """
        let output = Array(repeating: diagnostic, count: repeatedDiagnosticCount).joined(separator: "\n")
        return SwiftPackageBuildResult(succeeded: false, stdout: output, stderr: "", terminationStatus: 1)
    }
}

actor SequentialDeterministicSpacingBuilds {
    private let executableName: String
    private(set) var count = 0

    init(executableName: String) {
        self.executableName = executableName
    }

    func next(packageRoot: URL) -> SwiftPackageBuildResult {
        count += 1
        let contentViewURL = packageRoot.appendingPathComponent("Sources/\(executableName)/ContentView.swift")
        let source = (try? String(contentsOf: contentViewURL, encoding: .utf8)) ?? ""
        let target = count == 1 ? "firstIdx< tokens.count" : "secondIdx< tokens.count"
        guard let line = source.lineNumber(containing: target) else {
            return SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
        }

        let diagnostic = """
        \(contentViewURL.path):\(line):25: error: expected '{' after 'if' condition
        \(line) |                         if \(target) {
        """
        return SwiftPackageBuildResult(succeeded: false, stdout: diagnostic, stderr: "", terminationStatus: 1)
    }
}

actor UnsupportedModifierBuilds {
    private let executableName: String
    private(set) var count = 0

    init(executableName: String) {
        self.executableName = executableName
    }

    func next(packageRoot: URL) -> SwiftPackageBuildResult {
        count += 1
        let contentViewURL = packageRoot.appendingPathComponent("Sources/\(executableName)/ContentView.swift")
        let source = (try? String(contentsOf: contentViewURL, encoding: .utf8)) ?? ""
        guard let line = source.lineNumber(containing: "definitelyNotReal") else {
            return SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
        }

        let output = """
        \(contentViewURL.path):\(line):24: error: value of type 'Text' has no member 'definitelyNotReal'
        """
        return SwiftPackageBuildResult(succeeded: false, stdout: output, stderr: "", terminationStatus: 1)
    }
}

actor MultipleUnsupportedModifierBuilds {
    private let executableName: String
    private(set) var count = 0

    init(executableName: String) {
        self.executableName = executableName
    }

    func next(packageRoot: URL) -> SwiftPackageBuildResult {
        count += 1
        let contentViewURL = packageRoot.appendingPathComponent("Sources/\(executableName)/ContentView.swift")
        let source = (try? String(contentsOf: contentViewURL, encoding: .utf8)) ?? ""
        let diagnostics = source
            .components(separatedBy: .newlines)
            .enumerated()
            .compactMap { offset, line -> String? in
                guard line.contains("definitelyNotReal") else { return nil }
                return "\(contentViewURL.path):\(offset + 1):36: error: value of type 'Text' has no member 'definitelyNotReal'"
            }
        guard !diagnostics.isEmpty else {
            return SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
        }

        return SwiftPackageBuildResult(succeeded: false, stdout: diagnostics.joined(separator: "\n"), stderr: "", terminationStatus: 1)
    }
}

actor DistinctUnsupportedModifierBuilds {
    private let executableName: String
    private(set) var count = 0

    init(executableName: String) {
        self.executableName = executableName
    }

    func next(packageRoot: URL) -> SwiftPackageBuildResult {
        count += 1
        let contentViewURL = packageRoot.appendingPathComponent("Sources/\(executableName)/ContentView.swift")
        let source = (try? String(contentsOf: contentViewURL, encoding: .utf8)) ?? ""
        let diagnostics = source
            .components(separatedBy: .newlines)
            .enumerated()
            .compactMap { offset, line -> String? in
                guard let markerRange = line.range(of: #"\.missing[0-9]+\(\)"#, options: .regularExpression) else {
                    return nil
                }
                let member = String(line[markerRange])
                    .replacingOccurrences(of: ".", with: "")
                    .replacingOccurrences(of: "()", with: "")
                return "\(contentViewURL.path):\(offset + 1):36: error: value of type 'Text' has no member '\(member)'"
            }
        guard !diagnostics.isEmpty else {
            return SwiftPackageBuildResult(succeeded: true, stdout: "", stderr: "", terminationStatus: 0)
        }

        return SwiftPackageBuildResult(succeeded: false, stdout: diagnostics.joined(separator: "\n"), stderr: "", terminationStatus: 1)
    }
}

struct StubAgentLanguageModel: LanguageModel {
    typealias UnavailableReason = Never

    let responseProvider: @Sendable (Prompt, GenerationOptions) async throws -> String

    init(
        responseProvider: @escaping @Sendable (Prompt, GenerationOptions) async throws -> String
    ) {
        self.responseProvider = responseProvider
    }

    static func fixed(_ response: String) -> Self {
        Self { _, _ in response }
    }

    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        guard type == String.self else {
            throw FakeAgentError.unsupportedStructuredGeneration
        }

        let text = try await responseProvider(prompt, options)
        return LanguageModelSession.Response(
            content: text as! Content,
            rawContent: GeneratedContent(text),
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
        let responseProvider = self.responseProvider
        let yieldState = SingleYieldState()
        let stream = AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, any Error>(
            unfolding: {
                guard await yieldState.claim() else { return nil }
                guard type == String.self else {
                    throw FakeAgentError.unsupportedStructuredGeneration
                }
                let text = try await responseProvider(prompt, options)
                return .init(
                    content: (text as! Content).asPartiallyGenerated(),
                    rawContent: GeneratedContent(text)
                )
            }
        )
        return LanguageModelSession.ResponseStream(stream: stream)
    }
}

private actor SingleYieldState {
    private var hasYielded = false

    func claim() -> Bool {
        guard !hasYielded else { return false }
        hasYielded = true
        return true
    }
}

actor StreamingResponseProbe {
    private(set) var prompts: [String] = []
    private(set) var didStart = false
    private(set) var didCancel = false

    func recordStart(promptDescription: String) {
        didStart = true
        prompts.append(promptDescription)
    }

    func recordCancel() {
        didCancel = true
    }
}

struct PartialThenSuspendingLanguageModel: LanguageModel {
    typealias UnavailableReason = Never

    let partialResponse: String
    let probe: StreamingResponseProbe

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
        let partialResponse = self.partialResponse
        let probe = self.probe
        let promptDescription = String(describing: prompt)
        let stream = AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, any Error> {
            continuation in
            let task = Task {
                do {
                    guard type == String.self else {
                        throw FakeAgentError.unsupportedStructuredGeneration
                    }
                    await probe.recordStart(promptDescription: promptDescription)
                    continuation.yield(
                        .init(
                            content: (partialResponse as! Content).asPartiallyGenerated(),
                            rawContent: GeneratedContent(partialResponse)
                        )
                    )
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                    continuation.finish()
                } catch {
                    await probe.recordCancel()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
        return LanguageModelSession.ResponseStream(stream: stream)
    }
}

struct EmptyLanguageModel: LanguageModel {
    typealias UnavailableReason = Never

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
            stream: AsyncThrowingStream { continuation in
                continuation.finish(throwing: FakeAgentError.expected)
            }
        )
    }
}

enum FakeAgentError: LocalizedError {
    case expected
    case contextWindow
    case missingResponse
    case unsupportedStructuredGeneration

    var errorDescription: String? {
        switch self {
        case .expected:
            return "Expected test failure."
        case .contextWindow:
            return "The request exceeded the model context window size."
        case .missingResponse:
            return "Missing fake agent response."
        case .unsupportedStructuredGeneration:
            return "The fake language model only supports plain-text generation in this test."
        }
    }
}

extension String {
    func lineNumber(containing needle: String) -> Int? {
        components(separatedBy: .newlines)
            .firstIndex { $0.contains(needle) }
            .map { $0 + 1 }
    }
}
