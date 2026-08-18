import AppKit
import Foundation
import Observation

struct StoreSourceCodeExportRequest {
    let appName: String
    let versionNumber: Int
    let sourceCode: String
}

enum StoreSourceCodeExportError: LocalizedError {
    case couldNotOpenFile

    var errorDescription: String? {
        switch self {
        case .couldNotOpenFile:
            return "Ironsmith could not open the source file in your default editor."
        }
    }
}

struct StoreSourceCodeExportClient {
    var openSource: @MainActor (StoreSourceCodeExportRequest) throws -> Void

    static let live = Self { request in
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("Ironsmith Store Source", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileName = "\(sanitizedFileStem(request.appName))-v\(request.versionNumber).swift"
        let fileURL = directory.appendingPathComponent(fileName, isDirectory: false)
        try request.sourceCode.write(to: fileURL, atomically: true, encoding: .utf8)

        guard NSWorkspace.shared.open(fileURL) else {
            throw StoreSourceCodeExportError.couldNotOpenFile
        }
    }

    private static func sanitizedFileStem(_ value: String) -> String {
        let sanitized = value
            .replacingOccurrences(
                of: "[^A-Za-z0-9._-]+",
                with: "-",
                options: .regularExpression
            )
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        return sanitized.isEmpty ? "StoreApp" : sanitized
    }
}

@MainActor
@Observable
final class StoreAppSourceStore {
    var sourceCode: String?
    var sourceVersionID: String?
    var isLoading = false
    var loadErrorMessage: String?
    var editorErrorMessage: String?

    @ObservationIgnored private let exportClient: StoreSourceCodeExportClient
    @ObservationIgnored private var requestedVersionID: String?

    init(exportClient: StoreSourceCodeExportClient? = nil) {
        self.exportClient = exportClient ?? .live
    }

    func reset() {
        sourceCode = nil
        sourceVersionID = nil
        loadErrorMessage = nil
        editorErrorMessage = nil
        requestedVersionID = nil
    }

    func loadSource(
        for version: StoreVersionMetadata,
        using sourceLoader: @escaping () async throws -> String
    ) async throws -> String {
        let versionID = version.id
        if sourceVersionID == versionID, let sourceCode {
            return sourceCode
        }

        requestedVersionID = versionID
        isLoading = true
        loadErrorMessage = nil
        defer { isLoading = false }

        do {
            let sourceCode = try await sourceLoader()
            try Task.checkCancellation()
            guard requestedVersionID == versionID else {
                throw CancellationError()
            }
            self.sourceCode = sourceCode
            sourceVersionID = versionID
            return sourceCode
        } catch {
            if !IronsmithErrorPresentation.isCancellation(error) {
                loadErrorMessage = error.localizedDescription
            }
            throw error
        }
    }

    func openInDefaultEditor(for app: StoreAppDetail, version: StoreVersionMetadata) {
        guard sourceVersionID == version.id, let sourceCode else { return }
        do {
            try exportClient.openSource(
                StoreSourceCodeExportRequest(
                    appName: app.name,
                    versionNumber: version.versionNumber,
                    sourceCode: sourceCode
                )
            )
            editorErrorMessage = nil
        } catch {
            editorErrorMessage = error.localizedDescription
        }
    }
}
