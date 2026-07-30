import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class ToolAppDetailsEditorStore {
    var editingToolID: UUID?
    var name = ""
    var prompt = ""
    var currentPreviewData: Data?
    var candidate: ToolIconCandidate?
    var isShowingSheet = false
    var isGenerating = false
    var isSaving = false
    var errorMessage: String?

    @ObservationIgnored private let iconClient: ToolIconEditingClient
    @ObservationIgnored private let buildClient: ToolBuildClient

    init(
        iconClient: ToolIconEditingClient? = nil,
        buildClient: ToolBuildClient? = nil
    ) {
        self.iconClient = iconClient ?? .live()
        self.buildClient = buildClient ?? .live()
    }

    var previewData: Data? {
        candidate?.thumbnailJPEG ?? currentPreviewData
    }

    var isWorking: Bool {
        isGenerating || isSaving
    }

    func canSave(_ tool: Tool) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedName.isEmpty
            && !isWorking
            && (candidate != nil || trimmedName != tool.name)
    }

    func beginEditing(_ tool: Tool) {
        guard tool.isGenerationReady, !isWorking else { return }
        editingToolID = tool.id
        name = tool.name
        prompt = ""
        candidate = nil
        errorMessage = nil
        currentPreviewData = currentPreviewData(for: tool.packageLayout)
        isShowingSheet = true
    }

    func importIcon(from url: URL) {
        guard !isWorking else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            try importIcon(data: Data(contentsOf: url))
        } catch {
            present(error)
        }
    }

    func importIcon(data: Data) throws {
        guard !isWorking else { return }
        do {
            candidate = try iconClient.prepareSelectedImage(data)
            errorMessage = nil
        } catch {
            present(error)
            throw error
        }
    }

    func generate(for tool: Tool, provider: ToolImageGenerationProvider) async {
        guard editingToolID == tool.id, !isWorking else { return }
        let concept = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !concept.isEmpty else { return }
        guard provider != .disabled else {
            present(ToolIconEditingError.generationUnavailable)
            return
        }

        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }
        do {
            let stagedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            candidate = try await iconClient.generate(
                ToolIconRequest(
                    displayName: stagedName.isEmpty ? tool.name : stagedName,
                    iconPrompt: concept,
                    layout: tool.packageLayout,
                    imageProvider: provider
                )
            )
        } catch is CancellationError {
            return
        } catch {
            present(error)
        }
    }

    @discardableResult
    func save(
        _ tool: Tool,
        in modelContext: ModelContext,
        rename: (String) -> String?
    ) async -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard editingToolID == tool.id, canSave(tool) else {
            return false
        }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let previousUpdatedAt = tool.updatedAt
        let shouldRename = trimmedName != tool.name
        guard let candidate else {
            if let renameError = rename(trimmedName) {
                errorMessage = renameError
                return false
            }
            finish()
            return true
        }

        let request = ToolIconRequest(
            displayName: trimmedName,
            iconPrompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            layout: tool.packageLayout
        )
        var snapshot: ToolIconEditingAssetSnapshot?
        var didBuildNewIcon = false

        do {
            let installedSnapshot = try iconClient.install(candidate, request)
            snapshot = installedSnapshot
            try await buildClient.buildTool(tool)
            didBuildNewIcon = true
            tool.updatedAt = .now
            try modelContext.save()
            if shouldRename, let renameError = rename(trimmedName) {
                iconClient.restore(installedSnapshot, tool.packageLayout)
                try? await buildClient.buildTool(tool)
                tool.updatedAt = previousUpdatedAt
                try? modelContext.save()
                errorMessage = renameError
                return false
            }
            finish()
            return true
        } catch {
            if let snapshot {
                iconClient.restore(snapshot, tool.packageLayout)
                if didBuildNewIcon {
                    try? await buildClient.buildTool(tool)
                }
            }
            tool.updatedAt = previousUpdatedAt
            modelContext.rollback()
            present(error)
            return false
        }
    }

    func cancel() {
        guard !isWorking else { return }
        finish()
    }

    private func finish() {
        isShowingSheet = false
        editingToolID = nil
        name = ""
        prompt = ""
        candidate = nil
        currentPreviewData = nil
        errorMessage = nil
    }

    private func present(_ error: Error) {
        errorMessage = IronsmithErrorPresentation.message(for: error)
    }

    private func currentPreviewData(for layout: ToolPackageLayout) -> Data? {
        let candidates = [
            layout.cachedAppIconThumbnailJPEGURL,
            layout.cachedAppIconPNGURL,
            layout.cachedAppIconICNSURL,
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url) {
                return data
            }
        }
        return nil
    }
}
