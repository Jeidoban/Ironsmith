//
//  ToolLibraryStore.swift
//  Ironsmith
//

import Foundation
import Observation
import SwiftData

enum ToolLibraryPresentedErrorAction: Equatable {
    case buyIronsmithCredits
}

private enum ToolLibraryGenerationError: LocalizedError {
    case missingPreparedTool

    var errorDescription: String? {
        switch self {
        case .missingPreparedTool:
            return "Ironsmith could not finish this app because generation did not prepare a library record."
        }
    }
}

private final class BindingBox<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

@MainActor
@Observable
final class ToolLibraryStore {
    // Tool-library UI state: which tool is selected, and what the composer should say.
    var prompt: String
    var presentedErrorMessage: String?
    var presentedErrorAction: ToolLibraryPresentedErrorAction?
    var isGenerating = false
    var sandboxEnabled = true
    var appKind: ToolAppKind = .window
    var menuBarSystemImage = ToolMenuBarSymbol.fallback
    var sandboxPermissions = GeneratedAppSandboxPermissions.default
    var resourcePermissions = GeneratedAppResourcePermissions.none
    var runningToolID: UUID?
    var exportingToolID: UUID?
    private(set) var selectedToolID: UUID?
    private(set) var selectedToolName: String?
    private var restorableToolIDs = Set<UUID>()
    @ObservationIgnored private var nextGenerationSettings: ToolGenerationSettings?
    @ObservationIgnored private var hasCustomizedNextGenerationSettings = false
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    private let dependencies: ToolLibraryDependencies

    private struct RestoreAvailabilitySnapshot: Sendable {
        let id: UUID
        let packageRootPath: String
    }

    init(dependencies: ToolLibraryDependencies? = nil) {
        prompt = Self.defaultPrompt
        self.dependencies = dependencies ?? .live
    }

    var promptPlaceholder: String {
        if let selectedToolName {
            return "Describe changes for \(selectedToolName)…"
        }

        return "Describe a new app to build…"
    }

    var canSubmitPrompt: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating
    }

    var hasSelectedTool: Bool {
        selectedToolID != nil
    }

    func toggleSelection(for tool: Tool, defaultSettings: ToolGenerationSettings = .default) {
        initializeNextGenerationSettingsIfNeeded(defaultSettings)
        if selectedToolID == tool.id {
            clearSelection()
        } else {
            selectForEditing(tool, defaultSettings: defaultSettings)
        }
    }

    func selectForEditing(_ tool: Tool, defaultSettings: ToolGenerationSettings = .default) {
        guard tool.isGenerationReady else { return }
        initializeNextGenerationSettingsIfNeeded(defaultSettings)
        selectedToolID = tool.id
        selectedToolName = tool.name
        applyComposerSettings(tool.generationSettings(defaults: defaultSettings))
    }

    func handleDeletedTool(_ tool: Tool) {
        restorableToolIDs.remove(tool.id)
        if selectedToolID == tool.id {
            clearSelection()
        }
    }

    func syncSelection(with tools: [Tool], defaultSettings: ToolGenerationSettings = .default) {
        initializeNextGenerationSettingsIfNeeded(defaultSettings)
        restorableToolIDs.formIntersection(tools.map(\.id))

        guard let selectedToolID else {
            return
        }

        guard let selectedTool = tools.first(where: { $0.id == selectedToolID }) else {
            clearSelection()
            return
        }
        guard selectedTool.isGenerationReady else {
            clearSelection()
            return
        }

        selectedToolName = selectedTool.name
        applyComposerSettings(selectedTool.generationSettings(defaults: defaultSettings))
    }

    func initializeNextGenerationSettingsIfNeeded(_ defaultSettings: ToolGenerationSettings) {
        guard !hasCustomizedNextGenerationSettings else { return }
        nextGenerationSettings = defaultSettings
        if !hasSelectedTool {
            applyComposerSettings(defaultSettings)
        }
    }

    func rememberCurrentGenerationSettingsForNextGeneration() {
        nextGenerationSettings = currentComposerSettings
        hasCustomizedNextGenerationSettings = true
    }

    func isSelected(_ tool: Tool) -> Bool {
        selectedToolID == tool.id
    }

    func delete(_ tool: Tool, in modelContext: ModelContext) {
        guard !(isGenerating && tool.generationState == .generating) else { return }
        let packageRootURL = tool.packageRootURL
        handleDeletedTool(tool)
        modelContext.delete(tool)

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            presentError(error.localizedDescription)
            return
        }

        do {
            try removePackageIfExists(packageRootURL)
        } catch {
            presentError("Deleted app from the library, but could not remove its files: \(error.localizedDescription)")
        }
    }

    func canRestorePreviousVersion(_ tool: Tool) -> Bool {
        tool.isGenerationReady && restorableToolIDs.contains(tool.id)
    }

    func refreshRestoreAvailability(for tools: [Tool]) async {
        let snapshots = tools.map {
            RestoreAvailabilitySnapshot(id: $0.id, packageRootPath: $0.packageRootPath)
        }
        let nextRestorableToolIDs = await Task.detached(priority: .utility) {
            var restorableToolIDs = Set<UUID>()
            for snapshot in snapshots {
                if Task.isCancelled { return Set<UUID>() }
                if Self.computeCanRestorePreviousVersion(snapshot) {
                    restorableToolIDs.insert(snapshot.id)
                }
            }
            return restorableToolIDs
        }.value

        guard !Task.isCancelled else { return }
        restorableToolIDs = nextRestorableToolIDs
    }

    nonisolated private static func computeCanRestorePreviousVersion(_ snapshot: RestoreAvailabilitySnapshot) -> Bool {
        let packageRootURL = URL(fileURLWithPath: snapshot.packageRootPath, isDirectory: true)
        let previousVersionURL = ToolPackageLayout.previousContentViewVersionURL(for: packageRootURL)
        return FileManager.default.fileExists(atPath: previousVersionURL.path)
    }

    func startPromptSubmission(modelContext: ModelContext, inferenceStore: InferenceStore) {
        guard canSubmitPrompt, generationTask == nil else { return }
        generationTask = Task { @MainActor in
            await submitPrompt(modelContext: modelContext, inferenceStore: inferenceStore)
            generationTask = nil
        }
    }

    func cancelGeneration() {
        guard isGenerating else { return }
        clearPresentedErrorState()
        generationTask?.cancel()
    }

    func continueGeneration(
        _ tool: Tool,
        modelContext: ModelContext,
        inferenceStore: InferenceStore
    ) {
        guard canContinueGeneration(tool), generationTask == nil else { return }
        generationTask = Task { @MainActor in
            await resumeGeneration(tool, modelContext: modelContext, inferenceStore: inferenceStore)
            generationTask = nil
        }
    }

    func discardGeneration(_ tool: Tool, in modelContext: ModelContext) {
        guard !isGenerating, canContinueGeneration(tool) else { return }
        let packageRootURL = tool.packageRootURL
        removePendingDraft(for: tool)

        do {
            switch tool.generationMode ?? .create {
            case .create:
                handleDeletedTool(tool)
                modelContext.delete(tool)
                try modelContext.save()
                try removePackageIfExists(packageRootURL)
            case .edit:
                clearPendingGeneration(on: tool)
                try modelContext.save()
            }
        } catch {
            modelContext.rollback()
            presentError(error.localizedDescription)
        }
    }

    func restorePreviousVersion(_ tool: Tool, in modelContext: ModelContext) async {
        guard !isGenerating, tool.isGenerationReady else { return }
        isGenerating = true
        clearPresentedErrorState()
        defer {
            isGenerating = false
        }

        do {
            let layout = tool.packageLayout
            let contentViewPath = tool.contentViewSourcePath
            let restoredSettings = try dependencies.versionBackupClient.restorePreviousVersion(
                tool.packageRootURL,
                contentViewPath,
                tool.generationSettings(defaults: .default)
            )
            tool.applyGenerationSettings(restoredSettings)
            try Self.writeAppEntry(
                layout: layout,
                displayName: tool.name,
                settings: restoredSettings
            )
            try await dependencies.buildClient.buildTool(tool)
            clearPendingGeneration(on: tool)
            if selectedToolID == tool.id {
                applyComposerSettings(restoredSettings)
            }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            presentError(error.localizedDescription)
        }
    }

    func submitPrompt(modelContext: ModelContext, inferenceStore: InferenceStore) async {
        guard canSubmitPrompt else { return }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let submittedSelectedToolID = selectedToolID
        let submittedToolName = selectedToolName
        let submittedSettings = submittedGenerationSettings(
            defaultSettings: Self.defaultGenerationSettings(from: inferenceStore.generationPreferences)
        )
        var activeTool: Tool?
        isGenerating = true
        clearPresentedErrorState()

        do {
            let selectedTool = try fetchSelectedTool(in: modelContext)
            activeTool = selectedTool
            if submittedSelectedToolID != nil {
                clearSelection()
            }

            try await inferenceStore.prepareSelectedModelForGeneration()
            let languageModelContext = try await inferenceStore.makeSelectedAgentLanguageModelContext()
            if let selectedTool {
                markToolGenerating(
                    selectedTool,
                    mode: .edit,
                    phase: .planning,
                    prompt: trimmedPrompt
                )
                try modelContext.save()
            }

            let activeToolBox = BindingBox(activeTool)
            let lifecycle = generationLifecycle(
                modelContext: modelContext,
                activeTool: activeToolBox
            ) { tool in
                activeTool = tool
                activeToolBox.value = tool
            }

            let result = try await dependencies.generationClient.generateTool(
                ToolGenerationRequest(
                    prompt: trimmedPrompt,
                    existingTool: selectedTool,
                    settings: submittedSettings,
                    languageModelContext: languageModelContext,
                    lifecycle: lifecycle
                )
            )

            let completedTool = try requirePreparedTool(selectedTool ?? activeTool)
            applyCompletedGenerationResult(
                result,
                to: completedTool,
                prompt: trimmedPrompt
            )
            try modelContext.save()
            prompt = Self.defaultPrompt
            await refreshIronsmithCreditsIfNeeded(inferenceStore)
        } catch {
            if IronsmithErrorPresentation.isCancellation(error) || Task.isCancelled {
                handleGenerationCancellation(activeTool, in: modelContext)
            } else {
                await refreshIronsmithCreditsIfNeeded(inferenceStore)
                if let activeTool {
                    markToolFailed(activeTool, error: error)
                    try? modelContext.save()
                } else {
                    modelContext.rollback()
                }
                AgentDiagnosticsLog.append(
                    """
                    Tool generation failed.
                    prompt: \(AgentDiagnosticsLog.compact(trimmedPrompt, limit: 240))
                    selectedTool: \(submittedToolName ?? "<new tool>")
                    error:
                    \(AgentDiagnosticsLog.renderError(error))
                    """
                )
                presentGenerationError(error)
            }
        }

        isGenerating = false
    }

    private func refreshIronsmithCreditsIfNeeded(_ inferenceStore: InferenceStore) async {
        guard inferenceStore.selectedModelUsesIronsmith else { return }
        await inferenceStore.refreshIronsmithAccountSummary()
    }

    private func presentGenerationError(_ error: Error) {
        presentError(
            generationErrorMessage(for: error),
            action: generationErrorAction(for: error)
        )
    }

    private func generationErrorMessage(for error: Error) -> String {
        if isGenericAnyLanguageModelError(error) {
            return "There was an error generating your app. Please try again."
        }

        return error.localizedDescription
    }

    private func generationErrorAction(for error: Error) -> ToolLibraryPresentedErrorAction? {
        if let inferenceStoreError = error as? InferenceStoreError,
           case .insufficientIronsmithCredits = inferenceStoreError {
            return .buyIronsmithCredits
        }

        return nil
    }

    private func isGenericAnyLanguageModelError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain.contains("AnyLanguageModel") {
            return true
        }

        if error.localizedDescription.contains("AnyLanguageModel")
            || String(reflecting: error).contains("AnyLanguageModel") {
            return true
        }

        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isGenericAnyLanguageModelError(underlyingError)
        }

        return false
    }

    func showInFinder(_ tool: Tool) async {
        do {
            try await dependencies.finderClient.showToolDirectory(tool)
        } catch {
            presentError(error.localizedDescription)
        }
    }

    func viewSource(_ tool: Tool) async {
        guard tool.isGenerationReady else { return }
        do {
            let contentViewURL = try Self.contentViewURL(for: tool)
            try await dependencies.finderClient.openURL(contentViewURL)
        } catch {
            presentError(error.localizedDescription)
        }
    }

    func run(_ tool: Tool) async {
        guard tool.isGenerationReady, runningToolID == nil else { return }
        runningToolID = tool.id
        defer { runningToolID = nil }

        do {
            try await dependencies.runnerClient.runTool(tool)
        } catch {
            presentError(error.localizedDescription)
        }
    }

    func export(_ tool: Tool) async {
        guard tool.isGenerationReady, exportingToolID == nil, !isGenerating else { return }
        exportingToolID = tool.id
        defer {
            exportingToolID = nil
        }

        do {
            let exportedAppURL = try await dependencies.exportClient.exportTool(tool)
            try await dependencies.finderClient.revealURL(exportedAppURL)
        } catch {
            presentError(error.localizedDescription)
        }
    }

    func clearPresentedError() {
        clearPresentedErrorState()
    }

    private func presentError(
        _ message: String,
        action: ToolLibraryPresentedErrorAction? = nil
    ) {
        presentedErrorMessage = message
        presentedErrorAction = action
    }

    private func clearPresentedErrorState() {
        presentedErrorMessage = nil
        presentedErrorAction = nil
    }

    private func clearSelection() {
        selectedToolID = nil
        selectedToolName = nil
        applyComposerSettings(nextGenerationSettings ?? .default)
    }

    private var currentComposerSettings: ToolGenerationSettings {
        ToolGenerationSettings(
            appKind: appKind,
            menuBarSystemImage: menuBarSystemImage,
            sandboxEnabled: sandboxEnabled,
            sandboxPermissions: sandboxPermissions,
            resourcePermissions: resourcePermissions
        )
    }

    private func applyComposerSettings(_ settings: ToolGenerationSettings) {
        sandboxEnabled = settings.sandboxEnabled
        appKind = settings.appKind
        menuBarSystemImage = settings.menuBarSystemImage
        sandboxPermissions = settings.sandboxPermissions
        resourcePermissions = settings.resourcePermissions
    }

    private func submittedGenerationSettings(defaultSettings: ToolGenerationSettings) -> ToolGenerationSettings {
        let defaultBackedSandboxPermissions = !hasSelectedTool && nextGenerationSettings == nil
            ? defaultSettings.sandboxPermissions
            : sandboxPermissions
        let defaultBackedResourcePermissions = !hasSelectedTool && nextGenerationSettings == nil
            ? defaultSettings.resourcePermissions
            : resourcePermissions
        return ToolGenerationSettings(
            appKind: appKind,
            menuBarSystemImage: menuBarSystemImage,
            sandboxEnabled: sandboxEnabled,
            sandboxPermissions: defaultBackedSandboxPermissions,
            resourcePermissions: defaultBackedResourcePermissions
        )
    }

    static func defaultGenerationSettings(from preferences: GenerationPreferencesStore) -> ToolGenerationSettings {
        ToolGenerationSettings(
            sandboxEnabled: true,
            sandboxPermissions: preferences.generatedAppSandboxPermissions,
            resourcePermissions: preferences.generatedAppResourcePermissions
        )
    }

    private func fetchSelectedTool(in modelContext: ModelContext) throws -> Tool? {
        guard let selectedToolID else {
            return nil
        }
        let toolID = selectedToolID

        let descriptor = FetchDescriptor<Tool>(
            predicate: #Predicate { tool in
                tool.id == toolID
            }
        )
        return try modelContext.fetch(descriptor).first
    }

    private func resumeGeneration(
        _ tool: Tool,
        modelContext: ModelContext,
        inferenceStore: InferenceStore
    ) async {
        guard canContinueGeneration(tool) else { return }
        let resumePrompt = (tool.pendingPrompt ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resumePrompt.isEmpty else {
            presentError("Ironsmith does not have enough saved prompt context to continue this generation.")
            return
        }

        isGenerating = true
        clearPresentedErrorState()
        let activeToolBox = BindingBox<Tool?>(tool)
        let lifecycle = generationLifecycle(
            modelContext: modelContext,
            activeTool: activeToolBox
        ) { _ in }

        do {
            try await inferenceStore.prepareSelectedModelForGeneration()
            let languageModelContext = try await inferenceStore.makeSelectedAgentLanguageModelContext()
            let settings = tool.generationSettings(
                defaults: Self.defaultGenerationSettings(from: inferenceStore.generationPreferences)
            )
            markToolGenerating(
                tool,
                mode: tool.generationMode ?? .create,
                phase: tool.generationPhase ?? .planning,
                prompt: resumePrompt
            )
            try modelContext.save()

            let result = try await dependencies.generationClient.generateTool(
                ToolGenerationRequest(
                    prompt: resumePrompt,
                    existingTool: tool,
                    settings: settings,
                    languageModelContext: languageModelContext,
                    lifecycle: lifecycle
                )
            )
            applyCompletedGenerationResult(result, to: tool, prompt: resumePrompt)
            try modelContext.save()
            await refreshIronsmithCreditsIfNeeded(inferenceStore)
        } catch {
            if IronsmithErrorPresentation.isCancellation(error) || Task.isCancelled {
                handleGenerationCancellation(tool, in: modelContext)
            } else {
                await refreshIronsmithCreditsIfNeeded(inferenceStore)
                markToolFailed(tool, error: error)
                try? modelContext.save()
                presentGenerationError(error)
            }
        }

        isGenerating = false
    }

    private func handleGenerationCancellation(_ tool: Tool?, in modelContext: ModelContext) {
        if let tool {
            markToolStopped(tool)
            try? modelContext.save()
        } else {
            modelContext.rollback()
        }
        clearPresentedErrorState()
    }

    private func generationLifecycle(
        modelContext: ModelContext,
        activeTool: BindingBox<Tool?>,
        onPrepared: @escaping (Tool) -> Void = { _ in }
    ) -> ToolGenerationLifecycle {
        ToolGenerationLifecycle(
            preservesCreatedPackageOnCancellation: true,
            prepareCreatedTool: { preparedTool, prompt in
                try await MainActor.run {
                    let tool: Tool
                    if let activePreparedTool = activeTool.value {
                        tool = activePreparedTool
                        tool.name = preparedTool.name
                        tool.executableName = preparedTool.executableName
                        tool.bundleIdentifier = preparedTool.bundleIdentifier
                        tool.applyGenerationSettings(preparedTool.settings)
                        tool.packageRootPath = preparedTool.packageRootURL.path
                        tool.generationState = .generating
                        tool.generationPhase = .planning
                        tool.generationMode = .create
                        tool.pendingPrompt = prompt
                        tool.generationErrorSummary = nil
                        tool.generationRepairErrorCount = nil
                        tool.updatedAt = .now
                    } else {
                        tool = Tool(
                            name: preparedTool.name,
                            executableName: preparedTool.executableName,
                            bundleIdentifier: preparedTool.bundleIdentifier,
                            sandboxEnabled: preparedTool.settings.sandboxEnabled,
                            appKind: preparedTool.settings.appKind,
                            menuBarSystemImage: preparedTool.settings.menuBarSystemImage,
                            sandboxPermissions: preparedTool.settings.sandboxPermissions,
                            resourcePermissions: preparedTool.settings.resourcePermissions,
                            packageRootPath: preparedTool.packageRootURL.path,
                            generationState: .generating,
                            generationPhase: .planning,
                            generationMode: .create,
                            pendingPrompt: prompt
                        )
                        modelContext.insert(tool)
                    }
                    try modelContext.save()
                    activeTool.value = tool
                    onPrepared(tool)
                }
            },
            updatePendingPrompt: { prompt in
                try await MainActor.run {
                    guard let tool = activeTool.value else { return }
                    tool.pendingPrompt = prompt
                    tool.updatedAt = .now
                    try modelContext.save()
                }
            },
            updateRepairErrorCount: { count in
                try await MainActor.run {
                    guard let tool = activeTool.value else { return }
                    tool.generationRepairErrorCount = count
                    tool.updatedAt = .now
                    try modelContext.save()
                }
            },
            updatePhase: { state, phase, errorSummary in
                try await MainActor.run {
                    guard let tool = activeTool.value else { return }
                    tool.generationState = state
                    tool.generationPhase = phase
                    if phase != .generatingRepairDiff && phase != .repairing {
                        tool.generationRepairErrorCount = nil
                    }
                    if let errorSummary {
                        tool.generationErrorSummary = Self.shortSummary(for: errorSummary)
                    } else if state == .generating {
                        tool.generationErrorSummary = nil
                    }
                    tool.updatedAt = .now
                    try modelContext.save()
                }
            }
        )
    }

    private func markToolGenerating(
        _ tool: Tool,
        mode: ToolGenerationMode,
        phase: ToolGenerationPhase,
        prompt: String
    ) {
        tool.generationState = .generating
        tool.generationPhase = phase
        tool.generationMode = mode
        tool.pendingPrompt = prompt
        tool.generationErrorSummary = nil
        tool.generationRepairErrorCount = nil
        tool.updatedAt = .now
    }

    private func markToolStopped(_ tool: Tool) {
        tool.generationState = .stopped
        tool.generationErrorSummary = nil
        tool.generationRepairErrorCount = nil
        tool.updatedAt = .now
    }

    private func markToolFailed(_ tool: Tool, error: Error) {
        tool.generationState = .failed
        tool.generationErrorSummary = Self.shortSummary(for: generationErrorMessage(for: error))
        tool.generationRepairErrorCount = nil
        tool.updatedAt = .now
    }

    private func applyCompletedGenerationResult(
        _ result: ToolGenerationResult,
        to tool: Tool,
        prompt: String
    ) {
        tool.name = result.toolName
        tool.executableName = result.executableName
        tool.bundleIdentifier = result.bundleIdentifier
        tool.applyGenerationSettings(result.settings)
        tool.packageRootPath = result.packageRootURL.path
        clearPendingGeneration(on: tool)
    }

    private func clearPendingGeneration(on tool: Tool) {
        tool.generationState = .ready
        tool.generationPhase = .completed
        tool.generationMode = nil
        tool.pendingPrompt = nil
        tool.generationErrorSummary = nil
        tool.generationRepairErrorCount = nil
        removePendingDraft(for: tool)
        tool.updatedAt = .now
    }

    private func requirePreparedTool(_ tool: Tool?) throws -> Tool {
        guard let tool else {
            throw ToolLibraryGenerationError.missingPreparedTool
        }
        return tool
    }

    private func canContinueGeneration(_ tool: Tool) -> Bool {
        !isGenerating && (tool.generationState == .stopped || tool.generationState == .failed)
    }

    private func removePendingDraft(for tool: Tool) {
        let draftURL = ToolPackageLayout.pendingContentViewDraftURL(for: tool.packageRootURL)
        guard FileManager.default.fileExists(atPath: draftURL.path) else { return }
        try? FileManager.default.removeItem(at: draftURL)
    }

    private func removePackageIfExists(_ packageRootURL: URL) throws {
        guard FileManager.default.fileExists(atPath: packageRootURL.path) else { return }
        try FileManager.default.removeItem(at: packageRootURL)
    }

    private static func shortSummary(for message: String) -> String {
        let singleLine = message
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(singleLine.prefix(240))
    }

    private static func contentViewURL(for tool: Tool) throws -> URL {
        try ToolPackageLayout.packageFileURL(for: tool.contentViewSourcePath, packageRootURL: tool.packageRootURL)
    }

    private static func writeAppEntry(
        layout: ToolPackageLayout,
        displayName: String,
        settings: ToolGenerationSettings
    ) throws {
        let appEntryURL = try layout.packageFileURL(for: layout.appEntrySourcePath)
        try FileManager.default.createDirectory(
            at: appEntryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try layout.fixedAppEntrySource(displayName: displayName, settings: settings)
            .write(to: appEntryURL, atomically: true, encoding: .utf8)
    }

    private static var defaultPrompt: String {
#if DEBUG
        "Make a mortgage calculator"
#else
        ""
#endif
    }
}

struct ToolLibraryDependencies {
    var generationClient: ToolGenerationClient
    var runnerClient: ToolRunnerClient
    var exportClient: ToolExportClient = .live()
    var finderClient: ToolFinderClient = .live
    var versionBackupClient: ToolVersionBackupClient = .live
    var buildClient: ToolBuildClient = .live()

    static let live = ToolLibraryDependencies(
        generationClient: .live(),
        runnerClient: .live(),
        exportClient: .live(),
        finderClient: .live,
        versionBackupClient: .live,
        buildClient: .live()
    )
}
