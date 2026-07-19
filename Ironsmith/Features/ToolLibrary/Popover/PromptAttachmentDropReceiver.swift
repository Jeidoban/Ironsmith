import Foundation
import UniformTypeIdentifiers

@MainActor
enum PromptAttachmentDropReceiver {
    struct ReceivedFile: Equatable {
        let url: URL
        let requiresCleanup: Bool
    }

    static let supportedTypeIdentifiers = [
        UTType.fileURL.identifier,
        UTType.image.identifier,
    ]

    static func receive(providers: [NSItemProvider]) async -> [ReceivedFile] {
        var receivedFiles: [ReceivedFile] = []
        for provider in providers {
            if let url = await existingFileURL(from: provider) {
                receivedFiles.append(ReceivedFile(url: url, requiresCleanup: false))
                continue
            }
            if let file = await materializedImage(from: provider) {
                receivedFiles.append(file)
            }
        }
        return receivedFiles
    }

    static func cleanUp(_ files: [ReceivedFile]) {
        for file in files where file.requiresCleanup {
            try? FileManager.default.removeItem(at: file.url)
        }
    }

    private static func existingFileURL(from provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier,
                options: nil
            ) { item, _ in
                let url: URL?
                if let itemURL = item as? URL {
                    url = itemURL
                } else if let itemURL = item as? NSURL {
                    url = itemURL as URL
                } else if let data = item as? Data,
                    let value = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                {
                    url = URL(string: value)
                } else {
                    url = nil
                }

                guard let url, url.isFileURL,
                    FileManager.default.fileExists(atPath: url.path)
                else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: url)
            }
        }
    }

    private static func materializedImage(from provider: NSItemProvider) async -> ReceivedFile? {
        guard
            let typeIdentifier = provider.registeredTypeIdentifiers.first(where: { identifier in
                UTType(identifier)?.conforms(to: .image) == true
            }),
            let contentType = UTType(typeIdentifier)
        else {
            return nil
        }

        let data: Data? = await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
        guard let data else { return nil }

        let fileName = materializedFileName(
            suggestedName: provider.suggestedName,
            contentType: contentType
        )
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "IronsmithAttachmentDrops",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let url = directoryURL.appendingPathComponent(
                "\(UUID().uuidString)-\(fileName)",
                isDirectory: false
            )
            try data.write(to: url, options: .atomic)
            return ReceivedFile(url: url, requiresCleanup: true)
        } catch {
            return nil
        }
    }

    private static func materializedFileName(
        suggestedName: String?,
        contentType: UTType
    ) -> String {
        var name = URL(fileURLWithPath: suggestedName ?? "Screenshot")
            .lastPathComponent
        if URL(fileURLWithPath: name).pathExtension.isEmpty,
            let fileExtension = contentType.preferredFilenameExtension
        {
            name += ".\(fileExtension)"
        }
        return name
    }
}
