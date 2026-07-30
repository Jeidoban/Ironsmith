import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class ToolIconEditorStore {
    var editingToolID: UUID?
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

    var hasCandidate: Bool {
        candidate != nil
    }

    func beginEditing(_ tool: Tool) {
        guard tool.isGenerationReady, !isWorking else { return }
        editingToolID = tool.id
        prompt = tool.name
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
            candidate = try await iconClient.generate(
                ToolIconRequest(
                    displayName: tool.name,
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
    func save(_ tool: Tool, in modelContext: ModelContext) async -> Bool {
        guard editingToolID == tool.id,
            let candidate,
            !isWorking
        else {
            return false
        }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let previousUpdatedAt = tool.updatedAt
        let request = ToolIconRequest(
            displayName: tool.name,
            iconPrompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            layout: tool.packageLayout
        )
        var snapshot: ToolIconEditingAssetSnapshot?
        var didBuildNewIcon = false

        do {
            snapshot = try iconClient.install(candidate, request)
            try await buildClient.buildTool(tool)
            didBuildNewIcon = true
            tool.updatedAt = .now
            try modelContext.save()
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
