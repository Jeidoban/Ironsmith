import CoreGraphics
import Foundation
import ImageIO

nonisolated struct ToolIconCandidate: @unchecked Sendable {
    let image: CGImage
    let thumbnailJPEG: Data
}

nonisolated struct ToolIconEditingAssetSnapshot: Sendable {
    let masterJPEG: Data?
    let thumbnailJPEG: Data?
    let icns: Data?
    let legacyPNG: Data?
}

nonisolated enum ToolIconEditingError: LocalizedError, Equatable {
    case invalidDimensions(width: Int, height: Int)
    case generationUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidDimensions(let width, let height):
            return "Choose a 1024×1024 image. The selected image is \(width)×\(height)."
        case .generationUnavailable:
            return "Enable an app icon generator in Settings before generating a new icon."
        }
    }
}

nonisolated struct ToolIconEditingClient: Sendable {
    var prepareSelectedImage: @Sendable (Data) throws -> ToolIconCandidate
    var generate: @Sendable (ToolIconRequest) async throws -> ToolIconCandidate
    var install:
        @Sendable (ToolIconCandidate, ToolIconRequest) throws -> ToolIconEditingAssetSnapshot
    var restore: @Sendable (ToolIconEditingAssetSnapshot, ToolPackageLayout) -> Void

    @MainActor
    static func live(
        fileManager: FileManager = .default,
        imageClient: ToolImageGenerationClient? = nil,
        hostedIconPaletteStore: ToolHostedIconPaletteStore = .shared
    ) -> Self {
        let imageClient = imageClient ?? .live()
        let fileManagerBox = ToolIconEditingFileManager(fileManager)
        return Self(
            prepareSelectedImage: { data in
                let image = try ToolImageAssetEncoder.decodeImage(
                    data,
                    applyingOrientation: true
                )
                guard image.width == ToolImageAssetEncoder.iconMasterPixelSize,
                    image.height == ToolImageAssetEncoder.iconMasterPixelSize
                else {
                    throw ToolIconEditingError.invalidDimensions(
                        width: image.width,
                        height: image.height
                    )
                }
                return try Self.candidate(from: image)
            },
            generate: { request in
                guard request.imageProvider != .disabled,
                    request.imageProvider != .automatic
                else {
                    throw ToolIconEditingError.generationUnavailable
                }
                let hostedPalette: String?
                if request.imageProvider == .imagePlayground {
                    hostedPalette = nil
                } else {
                    hostedPalette = await hostedIconPaletteStore.palette(
                        for: request.displayName
                    )
                }
                let prompt = ToolIconClient.iconPrompt(
                    for: request,
                    hostedPalette: hostedPalette
                )
                let image = try await imageClient.generate(request.imageProvider, prompt)
                let normalized = try ToolImageAssetEncoder.squareImage(
                    image,
                    pixelSize: ToolImageAssetEncoder.iconMasterPixelSize,
                    opaque: false
                )
                return try Self.candidate(from: normalized)
            },
            install: { candidate, request in
                let fileManager = fileManagerBox.value
                try fileManager.createDirectory(
                    at: request.layout.packageMetadataDirectoryURL,
                    withIntermediateDirectories: true
                )
                let snapshot = try Self.snapshot(
                    layout: request.layout,
                    fileManager: fileManager
                )
                do {
                    try ToolIconClient.writeOriginalIconAssets(
                        candidate.image,
                        request: request,
                        fileManager: fileManager
                    )
                    return snapshot
                } catch {
                    Self.restore(snapshot, layout: request.layout, fileManager: fileManager)
                    throw error
                }
            },
            restore: { snapshot, layout in
                Self.restore(snapshot, layout: layout, fileManager: fileManagerBox.value)
            }
        )
    }

    private static func candidate(from image: CGImage) throws -> ToolIconCandidate {
        let assets = try ToolImageAssetEncoder.iconAssets(from: image)
        return ToolIconCandidate(
            image: image,
            thumbnailJPEG: assets.thumbnailData
        )
    }

    private static func snapshot(
        layout: ToolPackageLayout,
        fileManager: FileManager
    ) throws -> ToolIconEditingAssetSnapshot {
        ToolIconEditingAssetSnapshot(
            masterJPEG: try existingData(
                at: layout.cachedAppIconMasterJPEGURL,
                fileManager: fileManager
            ),
            thumbnailJPEG: try existingData(
                at: layout.cachedAppIconThumbnailJPEGURL,
                fileManager: fileManager
            ),
            icns: try existingData(
                at: layout.cachedAppIconICNSURL,
                fileManager: fileManager
            ),
            legacyPNG: try existingData(
                at: layout.cachedAppIconPNGURL,
                fileManager: fileManager
            )
        )
    }

    private static func existingData(at url: URL, fileManager: FileManager) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private static func restore(
        _ snapshot: ToolIconEditingAssetSnapshot,
        layout: ToolPackageLayout,
        fileManager: FileManager
    ) {
        restore(snapshot.masterJPEG, at: layout.cachedAppIconMasterJPEGURL, fileManager: fileManager)
        restore(
            snapshot.thumbnailJPEG,
            at: layout.cachedAppIconThumbnailJPEGURL,
            fileManager: fileManager
        )
        restore(snapshot.icns, at: layout.cachedAppIconICNSURL, fileManager: fileManager)
        restore(snapshot.legacyPNG, at: layout.cachedAppIconPNGURL, fileManager: fileManager)
    }

    private static func restore(_ data: Data?, at url: URL, fileManager: FileManager) {
        if let data {
            try? data.write(to: url, options: .atomic)
        } else {
            try? fileManager.removeItem(at: url)
        }
    }
}

nonisolated private final class ToolIconEditingFileManager: @unchecked Sendable {
    let value: FileManager

    init(_ value: FileManager) {
        self.value = value
    }
}
