import AppKit
import Foundation
import UniformTypeIdentifiers

nonisolated struct ToolPromptAttachment: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case image
        case file
    }

    let id: UUID
    let fileName: String
    let kind: Kind
    let mediaType: String?
    let data: Data

    init(
        id: UUID = UUID(),
        fileName: String,
        kind: Kind,
        mediaType: String? = nil,
        data: Data
    ) {
        self.id = id
        self.fileName = fileName
        self.kind = kind
        self.mediaType = mediaType
        self.data = data
    }

    var isImage: Bool { kind == .image }
}

nonisolated struct ToolPersistedPromptAttachment: Equatable, Sendable {
    let fileName: String
    let url: URL
    let isImage: Bool
}

nonisolated struct ToolPromptAttachmentStorage: Sendable {
    var replaceCurrentRun: @Sendable (
        _ attachments: [ToolPromptAttachment],
        _ layout: ToolPackageLayout
    ) throws -> [UUID]
    var currentRun: @Sendable (_ layout: ToolPackageLayout) throws -> [ToolPersistedPromptAttachment]
    var removeCurrentRun: @Sendable (_ layout: ToolPackageLayout) throws -> Void

    nonisolated static let live = Self(
        replaceCurrentRun: { attachments, layout in
            let fileManager = FileManager.default
            let directoryURL = layout.currentRunAttachmentsDirectoryURL
            if fileManager.fileExists(atPath: directoryURL.path) {
                try fileManager.removeItem(at: directoryURL)
            }
            guard !attachments.isEmpty else { return [] }

            do {
                try fileManager.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true
                )
                for (index, attachment) in attachments.enumerated() {
                    let fileName = persistedFileName(
                        for: attachment.fileName,
                        index: index
                    )
                    try attachment.data.write(
                        to: directoryURL.appendingPathComponent(fileName, isDirectory: false),
                        options: .atomic
                    )
                }
                return attachments.map(\.id)
            } catch {
                try? fileManager.removeItem(at: directoryURL)
                throw error
            }
        },
        currentRun: { layout in
            let fileManager = FileManager.default
            let directoryURL = layout.currentRunAttachmentsDirectoryURL
            guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }

            return try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.contentTypeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            .compactMap { url in
                let values = try? url.resourceValues(forKeys: [
                    .contentTypeKey,
                    .isRegularFileKey,
                ])
                guard values?.isRegularFile != false else { return nil }
                let contentType = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
                return ToolPersistedPromptAttachment(
                    fileName: url.lastPathComponent,
                    url: url,
                    isImage: contentType?.conforms(to: .image) == true
                )
            }
            .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        },
        removeCurrentRun: { layout in
            let directoryURL = layout.currentRunAttachmentsDirectoryURL
            guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
            try FileManager.default.removeItem(at: directoryURL)
        }
    )

    private nonisolated static func persistedFileName(
        for proposedName: String,
        index: Int
    ) -> String {
        let safeName = proposedName.unicodeScalars
            .map { scalar in
                CharacterSet.alphanumerics.contains(scalar)
                    || ".-_".unicodeScalars.contains(scalar) ? String(scalar) : "_"
            }
            .joined()
        return "\(index + 1)-\(safeName.isEmpty ? "attachment" : safeName)"
    }
}

enum ToolPromptAttachmentError: LocalizedError, Equatable {
    case tooManyFiles
    case directoryNotSupported(String)
    case fileTooLarge(String)
    case totalFilesTooLarge
    case unreadableFile(String)
    case imageCouldNotBeNormalized(String)

    var errorDescription: String? {
        switch self {
        case .tooManyFiles:
            return "You can attach up to three files."
        case .directoryNotSupported(let name):
            return "\(name) is a folder. Choose individual files instead."
        case .fileTooLarge(let name):
            return "\(name) is larger than the 5 MB attachment limit."
        case .totalFilesTooLarge:
            return "Non-image attachments can total up to 10 MB."
        case .unreadableFile(let name):
            return "Ironsmith could not read \(name)."
        case .imageCouldNotBeNormalized(let name):
            return "Ironsmith could not resize \(name) to the image attachment limit."
        }
    }
}

@MainActor
enum ToolPromptAttachmentLoader {
    static let maximumAttachmentCount = 3
    static let maximumImageBytes = 512 * 1_024
    static let maximumImageDimension = 2_048
    static let maximumFileBytes = 5 * 1_024 * 1_024
    static let maximumCombinedFileBytes = 10 * 1_024 * 1_024

    static func load(
        urls: [URL],
        existing: [ToolPromptAttachment]
    ) throws -> [ToolPromptAttachment] {
        guard existing.count + urls.count <= maximumAttachmentCount else {
            throw ToolPromptAttachmentError.tooManyFiles
        }

        var loaded = existing
        for url in urls {
            loaded.append(try load(url: url))
        }

        let combinedFileBytes =
            loaded
            .filter { !$0.isImage }
            .reduce(0) { $0 + $1.data.count }
        guard combinedFileBytes <= maximumCombinedFileBytes else {
            throw ToolPromptAttachmentError.totalFilesTooLarge
        }
        return loaded
    }

    private static func load(url: URL) throws -> ToolPromptAttachment {
        let name = url.lastPathComponent
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        let values = try? url.resourceValues(forKeys: [
            .contentTypeKey,
            .isRegularFileKey,
            .isDirectoryKey,
            .fileSizeKey,
        ])
        guard values?.isDirectory != true, values?.isRegularFile != false else {
            throw ToolPromptAttachmentError.directoryNotSupported(name)
        }
        let contentType = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        if contentType?.conforms(to: .image) != true,
            let fileSize = values?.fileSize,
            fileSize > maximumFileBytes
        {
            throw ToolPromptAttachmentError.fileTooLarge(name)
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw ToolPromptAttachmentError.unreadableFile(name)
        }

        if contentType?.conforms(to: .image) == true {
            return try normalizedImage(data: data, originalName: name)
        }

        guard data.count <= maximumFileBytes else {
            throw ToolPromptAttachmentError.fileTooLarge(name)
        }
        return ToolPromptAttachment(
            fileName: name,
            kind: .file,
            mediaType: contentType?.preferredMIMEType,
            data: data
        )
    }

    private static func normalizedImage(
        data: Data,
        originalName: String
    ) throws -> ToolPromptAttachment {
        guard let source = NSBitmapImageRep(data: data), let sourceImage = source.cgImage else {
            throw ToolPromptAttachmentError.imageCouldNotBeNormalized(originalName)
        }

        let sourceLongestSide = max(sourceImage.width, sourceImage.height)
        var longestSide = min(sourceLongestSide, maximumImageDimension)
        let hasAlpha = source.hasAlpha

        while longestSide >= 64 {
            guard let image = resized(sourceImage, longestSide: longestSide) else { break }
            let bitmap = NSBitmapImageRep(cgImage: image)

            if hasAlpha,
                let encoded = bitmap.representation(using: .png, properties: [:]),
                encoded.count <= maximumImageBytes
            {
                return imageAttachment(
                    originalName: originalName,
                    extension: "png",
                    mediaType: "image/png",
                    data: encoded
                )
            }

            if !hasAlpha {
                for quality in stride(from: 0.9, through: 0.25, by: -0.1) {
                    if let encoded = bitmap.representation(
                        using: .jpeg,
                        properties: [.compressionFactor: quality]
                    ), encoded.count <= maximumImageBytes {
                        return imageAttachment(
                            originalName: originalName,
                            extension: "jpg",
                            mediaType: "image/jpeg",
                            data: encoded
                        )
                    }
                }
            }

            longestSide = Int(Double(longestSide) * 0.82)
        }

        throw ToolPromptAttachmentError.imageCouldNotBeNormalized(originalName)
    }

    private static func resized(_ image: CGImage, longestSide: Int) -> CGImage? {
        let scale = min(1, Double(longestSide) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func imageAttachment(
        originalName: String,
        extension fileExtension: String,
        mediaType: String,
        data: Data
    ) -> ToolPromptAttachment {
        let stem = URL(fileURLWithPath: originalName).deletingPathExtension().lastPathComponent
        return ToolPromptAttachment(
            fileName: "\(stem).\(fileExtension)",
            kind: .image,
            mediaType: mediaType,
            data: data
        )
    }
}
