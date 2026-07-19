import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import Ironsmith

extension AgentPipelineTests {
    @MainActor
    @Test
    func promptAttachmentLoaderNormalizesLargeImages() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let imageURL = root.appendingPathComponent("large.png")
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 3_000,
                pixelsHigh: 1_000,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        let graphicsContext = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        NSColor.systemGreen.setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: 3_000, height: 1_000))
        NSGraphicsContext.restoreGraphicsState()
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: imageURL)

        let attachments = try ToolPromptAttachmentLoader.load(urls: [imageURL], existing: [])
        let attachment = try #require(attachments.first)
        let normalized = try #require(NSBitmapImageRep(data: attachment.data))

        #expect(attachment.isImage)
        #expect(attachment.data.count <= ToolPromptAttachmentLoader.maximumImageBytes)
        #expect(
            max(normalized.pixelsWide, normalized.pixelsHigh)
                <= ToolPromptAttachmentLoader.maximumImageDimension
        )
    }

    @MainActor
    @Test
    func promptAttachmentLoaderEnforcesCountAndFileSizeLimits() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try (0..<7).map { index in
            let url = root.appendingPathComponent("\(index).txt")
            try Data("file".utf8).write(to: url)
            return url
        }

        do {
            _ = try ToolPromptAttachmentLoader.load(urls: urls, existing: [])
            Issue.record("Expected the attachment count limit to reject seven files.")
        } catch let error as ToolPromptAttachmentError {
            #expect(error == .tooManyFiles)
        }

        let largeURL = root.appendingPathComponent("large.bin")
        #expect(FileManager.default.createFile(atPath: largeURL.path, contents: nil))
        let fileHandle = try FileHandle(forWritingTo: largeURL)
        try fileHandle.truncate(
            atOffset: UInt64(ToolPromptAttachmentLoader.maximumFileBytes + 1)
        )
        try fileHandle.close()
        do {
            _ = try ToolPromptAttachmentLoader.load(urls: [largeURL], existing: [])
            Issue.record("Expected the per-file size limit to reject the file.")
        } catch let error as ToolPromptAttachmentError {
            #expect(error == .fileTooLarge("large.bin"))
        }

        let finalByteURL = root.appendingPathComponent("final-byte.txt")
        try Data([0]).write(to: finalByteURL)
        let fullExistingAttachment = ToolPromptAttachment(
            fileName: "full.bin",
            kind: .file,
            data: Data(count: ToolPromptAttachmentLoader.maximumCombinedAttachmentBytes)
        )
        do {
            _ = try ToolPromptAttachmentLoader.load(
                urls: [finalByteURL],
                existing: [fullExistingAttachment]
            )
            Issue.record("Expected the combined attachment limit to reject the final byte.")
        } catch let error as ToolPromptAttachmentError {
            #expect(error == .totalFilesTooLarge)
        }
    }

    @MainActor
    @Test
    func promptAttachmentLoaderKeepsPDFBytesUnchanged() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pdfURL = root.appendingPathComponent("reference.pdf")
        let pdfData = Data("%PDF-1.7\nuser-provided reference\n%%EOF".utf8)
        try pdfData.write(to: pdfURL)

        let attachments = try ToolPromptAttachmentLoader.load(urls: [pdfURL], existing: [])
        let attachment = try #require(attachments.first)

        #expect(!attachment.isImage)
        #expect(attachment.fileName == "reference.pdf")
        #expect(attachment.data == pdfData)
    }

    @MainActor
    @Test
    func promptAttachmentDropReceiverMaterializesPromisedImageData() async throws {
        let imageData = Data("promised screenshot".utf8)
        let provider = NSItemProvider()
        provider.suggestedName = "Screenshot"
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.png.identifier,
            visibility: .all
        ) { completion in
            completion(imageData, nil)
            return nil
        }

        let files = await PromptAttachmentDropReceiver.receive(providers: [provider])
        let file = try #require(files.first)
        defer { PromptAttachmentDropReceiver.cleanUp(files) }

        #expect(file.requiresCleanup)
        #expect(file.url.pathExtension == "png")
        #expect(FileManager.default.fileExists(atPath: file.url.path))
        #expect(try Data(contentsOf: file.url) == imageData)
    }

    @MainActor
    @Test
    func promptAttachmentDropReceiverPreservesExistingFileURL() async throws {
        let directoryURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let fileURL = directoryURL.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: fileURL)
        let provider = try #require(NSItemProvider(contentsOf: fileURL))

        let files = await PromptAttachmentDropReceiver.receive(providers: [provider])
        let file = try #require(files.first)

        #expect(file.url == fileURL)
        #expect(!file.requiresCleanup)
        #expect(FileManager.default.fileExists(atPath: file.url.path))
    }

    @Test
    func promptAttachmentStorageUsesPackageCurrentRunAndClassifiesFiles() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = ToolPackageLayout(packageRootURL: root, executableName: "Demo")
        let imageID = UUID()
        let fileID = UUID()

        let persistedIDs = try ToolPromptAttachmentStorage.live.replaceCurrentRun(
            [
                ToolPromptAttachment(
                    id: imageID,
                    fileName: "reference image.png",
                    kind: .image,
                    data: Data("image".utf8)
                ),
                ToolPromptAttachment(
                    id: fileID,
                    fileName: "reference.pdf",
                    kind: .file,
                    data: Data("%PDF".utf8)
                ),
            ],
            layout
        )

        #expect(persistedIDs == [imageID, fileID])
        #expect(
            layout.currentRunAttachmentsDirectoryURL.path
                == root.appendingPathComponent(".ironsmith/attachments/current-run").path
        )
        let stored = try ToolPromptAttachmentStorage.live.currentRun(layout)
        #expect(stored.map(\.fileName) == ["1-reference_image.png", "2-reference.pdf"])
        #expect(stored.map(\.isImage) == [true, false])

        _ = try ToolPromptAttachmentStorage.live.replaceCurrentRun([], layout)
        #expect(!FileManager.default.fileExists(atPath: layout.currentRunAttachmentsDirectoryURL.path))
    }
}
