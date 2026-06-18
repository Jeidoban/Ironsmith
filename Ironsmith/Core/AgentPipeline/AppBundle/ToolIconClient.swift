import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ImagePlayground

struct ToolIconRequest: Equatable, Sendable {
    let displayName: String
    let iconPrompt: String?
    let layout: ToolPackageLayout

    init(
        displayName: String,
        iconPrompt: String? = nil,
        layout: ToolPackageLayout
    ) {
        self.displayName = displayName
        self.iconPrompt = iconPrompt
        self.layout = layout
    }
}

struct ToolIconClient: Sendable {
    var ensureIconAssets: @Sendable (ToolIconRequest) async throws -> URL

    nonisolated private static let cachedPreviewPNGPixelSize = 256

    nonisolated static let noOp = ToolIconClient { request in
        request.layout.cachedAppIconICNSURL
    }

    static func live(
        fileManager: FileManager = .default,
        foregroundClient: AppForegroundClient = .live,
        imageGenerator: (@Sendable (ToolIconRequest) async throws -> CGImage)? = nil
    ) -> ToolIconClient {
        let imageGenerator = imageGenerator ?? imagePlaygroundIcon(for:)
        return ToolIconClient { request in
            if fileManager.fileExists(atPath: request.layout.cachedAppIconICNSURL.path) {
                return request.layout.cachedAppIconICNSURL
            }

            try fileManager.createDirectory(
                at: request.layout.packageMetadataDirectoryURL,
                withIntermediateDirectories: true
            )

            do {
                await foregroundClient.activate()
                let cgImage = try await imageGenerator(request)
                try Self.writePNG(cgImage, to: request.layout.cachedAppIconPNGURL)
                try Self.writeICNS(cgImage, request: request, fileManager: fileManager)
                return request.layout.cachedAppIconICNSURL
            } catch {
                AgentDiagnosticsLog.append(
                    """
                    Image Playground icon generation failed; using fallback icon.
                    displayName: \(request.displayName)
                    error:
                    \(AgentDiagnosticsLog.renderError(error, limit: 500))
                    """
                )
                do {
                    let fallback = try await MainActor.run {
                        try Self.fallbackIcon(for: request.displayName)
                    }
                    try Self.writePNG(fallback, to: request.layout.cachedAppIconPNGURL)
                    try Self.writeICNS(fallback, request: request, fileManager: fileManager)
                    return request.layout.cachedAppIconICNSURL
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

            if fileManager.fileExists(atPath: request.layout.cachedAppIconPNGURL.path) {
                return request.layout.cachedAppIconPNGURL
            }

            throw ToolAppBundleError.iconEncodingFailed
        }
    }

    private static func imagePlaygroundIcon(for request: ToolIconRequest) async throws -> CGImage {
        try await imagePlaygroundImage(for: Self.iconPrompt(for: request))
    }

    #if DEBUG
    @MainActor
    static func debugImagePlaygroundPreview(prompt: String) async throws -> NSImage {
        try await debugImagePlaygroundPreview(prompt: prompt, foregroundClient: .live)
    }

    @MainActor
    static func debugImagePlaygroundPreview(prompt: String, foregroundClient: AppForegroundClient) async throws
        -> NSImage
    {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw ToolAppBundleError.iconGenerationProducedNoImage
        }

        await foregroundClient.activate()
        let cgImage = try await imagePlaygroundImage(for: trimmedPrompt)
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }
    #endif

    private static func imagePlaygroundImage(for prompt: String) async throws -> CGImage {
        let creator = try await ImageCreator()
        let style = creator.availableStyles.contains(.illustration)
            ? ImagePlaygroundStyle.illustration
            : (creator.availableStyles.first ?? .illustration)
        let concept = ImagePlaygroundConcept.text(prompt)
        let sequence = creator.images(for: [concept], style: style, limit: 1)

        for try await image in sequence {
            return image.cgImage
        }

        throw ToolAppBundleError.iconGenerationProducedNoImage
    }

    nonisolated private static func iconPrompt(for request: ToolIconRequest) -> String {
        if let prompt = request.iconPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !prompt.isEmpty {
            return prompt
        }
        let displayName = request.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return displayName.isEmpty ? "Simple symbol" : displayName
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
