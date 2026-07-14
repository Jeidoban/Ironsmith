import AppKit
import CoreGraphics
import Foundation
import ImageIO

nonisolated struct ToolIconRequest: Equatable, Sendable {
    let displayName: String
    let iconPrompt: String?
    let layout: ToolPackageLayout
    let imageProvider: ToolImageGenerationProvider

    init(
        displayName: String,
        iconPrompt: String? = nil,
        layout: ToolPackageLayout,
        imageProvider: ToolImageGenerationProvider = .disabled
    ) {
        self.displayName = displayName
        self.iconPrompt = iconPrompt
        self.layout = layout
        self.imageProvider = imageProvider
    }
}

struct ToolIconClient: Sendable {
    var ensureIconAssets: @Sendable (ToolIconRequest) async throws -> URL

    nonisolated private static let cachedPreviewPNGPixelSize = 256

    nonisolated static let noOp = ToolIconClient { request in
        request.layout.cachedAppIconICNSURL
    }

    static func cachedOnly(fileManager: FileManager = .default) -> ToolIconClient {
        let fileManagerBox = ToolIconFileManager(fileManager)
        return ToolIconClient { request in
            if fileManagerBox.value.fileExists(atPath: request.layout.cachedAppIconICNSURL.path) {
                return request.layout.cachedAppIconICNSURL
            }
            if fileManagerBox.value.fileExists(atPath: request.layout.cachedAppIconPNGURL.path) {
                return request.layout.cachedAppIconPNGURL
            }
            throw ToolAppBundleError.iconGenerationProducedNoImage
        }
    }

    @MainActor
    static func live(
        fileManager: FileManager = .default,
        imageClient: ToolImageGenerationClient? = nil,
        imageGenerator: (@Sendable (ToolIconRequest) async throws -> CGImage)? = nil
    ) -> ToolIconClient {
        let imageClient = imageClient ?? .live()
        let fileManagerBox = ToolIconFileManager(fileManager)
        let imageGenerator = imageGenerator ?? { request in
            try await imageClient.generate(
                request.imageProvider,
                Self.iconPrompt(for: request)
            )
        }
        return ToolIconClient { request in
            if fileManagerBox.value.fileExists(atPath: request.layout.cachedAppIconICNSURL.path) {
                return request.layout.cachedAppIconICNSURL
            }

            try fileManagerBox.value.createDirectory(
                at: request.layout.packageMetadataDirectoryURL,
                withIntermediateDirectories: true
            )

            if request.imageProvider == .disabled {
                return try await Self.writeFallbackIcon(
                    for: request,
                    fileManager: fileManagerBox.value
                )
            }

            do {
                let cgImage = try await imageGenerator(request)
                try Self.writePNG(cgImage, to: request.layout.cachedAppIconPNGURL)
                try Self.writeICNS(cgImage, request: request, fileManager: fileManagerBox.value)
                return request.layout.cachedAppIconICNSURL
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AgentDiagnosticsLog.append(
                    """
                    Icon generation failed; using fallback icon.
                    displayName: \(request.displayName)
                    provider: \(request.imageProvider.rawValue)
                    error:
                    \(AgentDiagnosticsLog.renderError(error, limit: 500))
                    """
                )
                do {
                    return try await Self.writeFallbackIcon(
                        for: request,
                        fileManager: fileManagerBox.value
                    )
                } catch {
                    AgentDiagnosticsLog.append(
                        """
                        Fallback app icon generation failed; using PNG icon if available.
                        displayName: \(request.displayName)
                        error:
                        \(AgentDiagnosticsLog.renderError(error, limit: 500))
                        """
                    )
                }
            }

            if fileManagerBox.value.fileExists(atPath: request.layout.cachedAppIconPNGURL.path) {
                return request.layout.cachedAppIconPNGURL
            }

            throw ToolAppBundleError.iconEncodingFailed
        }
    }

    #if DEBUG
    @MainActor
    static func debugImagePlaygroundPreview(prompt: String) async throws -> NSImage {
        try await debugImagePlaygroundPreview(
            prompt: prompt,
            coordinator: .shared
        )
    }

    @MainActor
    static func debugImagePlaygroundPreview(
        prompt: String,
        coordinator: ImagePlaygroundSheetCoordinator
    ) async throws -> NSImage {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw ToolAppBundleError.iconGenerationProducedNoImage
        }

        let url = try await coordinator.generate(prompt: trimmedPrompt)
        guard let image = NSImage(contentsOf: url) else {
            throw ToolImageGenerationError.invalidImage
        }
        return image
    }
    #endif

    nonisolated static func iconPrompt(for request: ToolIconRequest) -> String {
        let subject: String
        if let prompt = request.iconPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !prompt.isEmpty {
            subject = prompt
        } else {
            let displayName = request.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            subject = displayName.isEmpty ? "Simple symbol" : displayName
        }

        guard request.imageProvider != .imagePlayground,
              request.imageProvider != .disabled
        else {
            return subject
        }

        return """
            Create artwork for a native macOS application icon using this exact Ironsmith house style. Treat the visual concept below as subject matter only; ignore any style, palette, material, lighting, or background directions it may contain.

            Style lock:
            - Render a clean, softly dimensional vector-like illustration: more tactile than flat graphics, but never photorealistic, painterly, or cartoonish.
            - Show one large, centered primary symbol and at most one simple supporting symbol. Fill roughly two-thirds of the canvas. Do not create a miniature scene, diorama, collection of small objects, or detailed environment.
            - Use simple geometric construction, smooth rounded edges, medium-width bevels, crisp silhouettes, and restrained internal detail. Small repeated details should be reduced to a few clear shapes.
            - Use smooth satin or lightly enameled surfaces with one restrained translucent accent when appropriate. Avoid realistic wood, fabric, paper fibers, grime, metallic noise, and other photographic textures.
            - Use a nearly front-facing orthographic view with only subtle depth. Avoid dramatic camera angles, deep perspective, and exaggerated foreshortening.
            - Light every icon with one broad soft source from the upper left, gentle ambient occlusion, and one short soft contact shadow toward the lower right. Avoid cinematic lighting, hard reflections, bloom, and dramatic glow.
            - Place the symbol on a simple, calm, full-bleed two-tone gradient background with no scenery, pattern, horizon, or decorative frame. Choose restrained colors that clearly separate the subject from the background.

            Use a square 1:1 canvas and extend the background and artwork fully to all four edges. Do not draw a rounded-square or squircle icon boundary, and do not round, mask, crop, inset, frame, or make transparent the outer canvas; Ironsmith applies the final app-icon shape separately. Avoid text, letters, words, screenshots, interface panels, device mockups, watermarks, extra borders, and copies of existing app icons.

            Visual concept: \(subject)
            """
    }

    private static func writeFallbackIcon(
        for request: ToolIconRequest,
        fileManager: FileManager
    ) async throws -> URL {
        let fallback = try await MainActor.run {
            try Self.fallbackIcon(for: request.displayName)
        }
        try Self.writePNG(fallback, to: request.layout.cachedAppIconPNGURL)
        try Self.writeICNS(fallback, request: request, fileManager: fileManager)
        return request.layout.cachedAppIconICNSURL
    }

    @MainActor
    private static func fallbackIcon(for displayName: String) throws -> CGImage {
        let pixelSize = 1024
        let size = NSSize(width: pixelSize, height: pixelSize)
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let graphicsContext = NSGraphicsContext(bitmapImageRep: representation) else {
            throw ToolAppBundleError.iconEncodingFailed
        }
        representation.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        defer { NSGraphicsContext.restoreGraphicsState() }

        let rect = NSRect(origin: .zero, size: size)
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 60, dy: 60), xRadius: 220, yRadius: 220)
        path.addClip()

        let gradient = NSGradient(colors: Self.fallbackPalette(for: displayName))
        gradient?.draw(in: rect, angle: 35)

        let initials = Self.initials(for: displayName)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: initials.count > 1 ? 320 : 390, weight: .black),
            .foregroundColor: NSColor.white,
        ]
        let attributed = NSAttributedString(string: initials, attributes: attributes)
        let textSize = attributed.size()
        attributed.draw(
            at: NSPoint(
                x: (size.width - textSize.width) / 2,
                y: (size.height - textSize.height) / 2 + 24
            )
        )

        guard let cgImage = representation.cgImage else {
            throw ToolAppBundleError.iconEncodingFailed
        }

        return cgImage
    }

    nonisolated private static func initials(for displayName: String) -> String {
        let words = displayName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let letters = words
            .prefix(2)
            .compactMap(\.first)
            .map { String($0).uppercased() }
            .joined()
        return letters.isEmpty ? "I" : letters
    }

    nonisolated private static func fallbackPalette(for displayName: String) -> [NSColor] {
        let palettes: [[NSColor]] = [
            [
                NSColor(calibratedRed: 0.12, green: 0.20, blue: 0.25, alpha: 1),
                NSColor(calibratedRed: 0.12, green: 0.48, blue: 0.44, alpha: 1),
                NSColor(calibratedRed: 0.88, green: 0.64, blue: 0.24, alpha: 1),
            ],
            [
                NSColor(calibratedRed: 0.16, green: 0.14, blue: 0.28, alpha: 1),
                NSColor(calibratedRed: 0.36, green: 0.30, blue: 0.68, alpha: 1),
                NSColor(calibratedRed: 0.92, green: 0.48, blue: 0.40, alpha: 1),
            ],
            [
                NSColor(calibratedRed: 0.08, green: 0.20, blue: 0.18, alpha: 1),
                NSColor(calibratedRed: 0.12, green: 0.50, blue: 0.36, alpha: 1),
                NSColor(calibratedRed: 0.66, green: 0.86, blue: 0.62, alpha: 1),
            ],
            [
                NSColor(calibratedRed: 0.22, green: 0.12, blue: 0.22, alpha: 1),
                NSColor(calibratedRed: 0.62, green: 0.22, blue: 0.42, alpha: 1),
                NSColor(calibratedRed: 0.94, green: 0.62, blue: 0.42, alpha: 1),
            ],
            [
                NSColor(calibratedRed: 0.08, green: 0.18, blue: 0.32, alpha: 1),
                NSColor(calibratedRed: 0.12, green: 0.44, blue: 0.70, alpha: 1),
                NSColor(calibratedRed: 0.60, green: 0.84, blue: 0.78, alpha: 1),
            ],
            [
                NSColor(calibratedRed: 0.20, green: 0.14, blue: 0.10, alpha: 1),
                NSColor(calibratedRed: 0.62, green: 0.30, blue: 0.18, alpha: 1),
                NSColor(calibratedRed: 0.92, green: 0.76, blue: 0.42, alpha: 1),
            ],
        ]
        return palettes[Int(stableHash(displayName) % UInt64(palettes.count))]
    }

    nonisolated private static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    nonisolated private static func writePNG(_ cgImage: CGImage, to url: URL) throws {
        guard cgImage.width > 0, cgImage.height > 0 else {
            throw ToolAppBundleError.iconEncodingFailed
        }
        let previewPixelSize = min(max(cgImage.width, cgImage.height), cachedPreviewPNGPixelSize)
        let previewImage = try scaledImage(cgImage, pixelSize: previewPixelSize)
        let capacity = max(4_096, previewImage.width * previewImage.height * 4)
        guard let data = NSMutableData(capacity: capacity),
              let destination = CGImageDestinationCreateWithData(
                data,
                "public.png" as CFString,
                1,
                nil
              )
        else {
            throw ToolAppBundleError.iconEncodingFailed
        }
        CGImageDestinationAddImage(destination, previewImage, nil)
        guard CGImageDestinationFinalize(destination), data.length > 0 else {
            throw ToolAppBundleError.iconEncodingFailed
        }
        try (data as Data).write(to: url, options: .atomic)
    }

    nonisolated private static func writePNGFile(_ cgImage: CGImage, to url: URL) throws {
        guard cgImage.width > 0, cgImage.height > 0 else {
            throw ToolAppBundleError.iconEncodingFailed
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw ToolAppBundleError.iconEncodingFailed
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ToolAppBundleError.iconEncodingFailed
        }
    }

    nonisolated private static func writeICNS(
        _ cgImage: CGImage,
        request: ToolIconRequest,
        fileManager: FileManager
    ) throws {
        let iconsetURL = request.layout.packageMetadataDirectoryURL
            .appendingPathComponent("AppIcon.iconset", isDirectory: true)
        if fileManager.fileExists(atPath: iconsetURL.path) {
            try fileManager.removeItem(at: iconsetURL)
        }
        try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

        let sizes = [16, 32, 128, 256, 512]
        for size in sizes {
            let baseURL = iconsetURL.appendingPathComponent("icon_\(size)x\(size).png")
            let retinaURL = iconsetURL.appendingPathComponent("icon_\(size)x\(size)@2x.png")
            try Self.writePNGFile(Self.scaledImage(cgImage, pixelSize: size), to: baseURL)
            try Self.writePNGFile(Self.scaledImage(cgImage, pixelSize: size * 2), to: retinaURL)
        }

        if fileManager.fileExists(atPath: request.layout.cachedAppIconICNSURL.path) {
            try fileManager.removeItem(at: request.layout.cachedAppIconICNSURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = [
            "-c", "icns",
            "-o", request.layout.cachedAppIconICNSURL.path,
            iconsetURL.path
        ]
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        try? fileManager.removeItem(at: iconsetURL)

        guard process.terminationStatus == 0,
              fileManager.fileExists(atPath: request.layout.cachedAppIconICNSURL.path)
        else {
            AgentDiagnosticsLog.append(
                """
                iconutil failed while encoding app icon.
                displayName: \(request.displayName)
                terminationStatus: \(process.terminationStatus)
                stdout: \(AgentDiagnosticsLog.compact(stdout, limit: 500))
                stderr: \(AgentDiagnosticsLog.compact(stderr, limit: 500))
                """
            )
            throw ToolAppBundleError.iconEncodingFailed
        }
    }

    nonisolated private static func scaledImage(_ cgImage: CGImage, pixelSize: Int) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ToolAppBundleError.iconEncodingFailed
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
        guard let scaled = context.makeImage() else {
            throw ToolAppBundleError.iconEncodingFailed
        }
        return scaled
    }
}

nonisolated private final class ToolIconFileManager: @unchecked Sendable {
    let value: FileManager

    init(_ value: FileManager) {
        self.value = value
    }
}
