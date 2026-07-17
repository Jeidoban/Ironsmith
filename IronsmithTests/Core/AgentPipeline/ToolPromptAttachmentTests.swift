import AppKit
import Foundation
import Testing

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
        #expect(max(normalized.pixelsWide, normalized.pixelsHigh) <= 2_048)
    }

    @MainActor
    @Test
    func promptAttachmentLoaderEnforcesCountAndFileSizeLimits() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try (0..<4).map { index in
            let url = root.appendingPathComponent("\(index).txt")
            try Data("file".utf8).write(to: url)
            return url
        }

        do {
            _ = try ToolPromptAttachmentLoader.load(urls: urls, existing: [])
            Issue.record("Expected the attachment count limit to reject four files.")
        } catch let error as ToolPromptAttachmentError {
            #expect(error == .tooManyFiles)
        }

        let largeURL = root.appendingPathComponent("large.bin")
        try Data(count: ToolPromptAttachmentLoader.maximumFileBytes + 1).write(to: largeURL)
        do {
            _ = try ToolPromptAttachmentLoader.load(urls: [largeURL], existing: [])
            Issue.record("Expected the per-file size limit to reject the file.")
        } catch let error as ToolPromptAttachmentError {
            #expect(error == .fileTooLarge("large.bin"))
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
}
