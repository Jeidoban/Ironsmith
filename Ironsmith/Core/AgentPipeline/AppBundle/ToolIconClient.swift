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

nonisolated private struct ToolIconPalette: Sendable {
    let description: String
    let backgroundStartRGB: UInt32
    let backgroundEndRGB: UInt32
    let foregroundRGB: UInt32
}

actor ToolHostedIconPaletteStore {
    static let shared = ToolHostedIconPaletteStore()
    nonisolated static let recentPaletteLimit = 10

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func palette(for displayName: String) -> String {
        ToolIconClient.hostedIconPalettes[paletteIndex(for: displayName)]
    }

    func paletteIndex(for displayName: String) -> Int {
        let paletteCount = ToolIconClient.hostedIconPalettes.count
        let preferredIndex = ToolIconClient.hostedIconPaletteIndex(for: displayName)
        let recentIndices = recentPaletteIndices(paletteCount: paletteCount)
        let excludedIndices = Set(recentIndices)
        let selectedIndex = (0..<paletteCount)
            .lazy
            .map { (preferredIndex + $0) % paletteCount }
            .first { !excludedIndices.contains($0) } ?? preferredIndex
        let updatedIndices = Array(
            (recentIndices + [selectedIndex]).suffix(Self.recentPaletteLimit)
        )
        userDefaults.set(
            updatedIndices,
            forKey: IronsmithPreferenceKeys.recentHostedIconPaletteIndices
        )
        return selectedIndex
    }

    private func recentPaletteIndices(paletteCount: Int) -> [Int] {
        if let storedIndices = userDefaults.array(
            forKey: IronsmithPreferenceKeys.recentHostedIconPaletteIndices
        ) {
            return Array(
                storedIndices
                    .compactMap { ($0 as? NSNumber)?.intValue }
                    .filter { (0..<paletteCount).contains($0) }
                    .suffix(Self.recentPaletteLimit)
            )
        }
        return []
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
        hostedIconPaletteStore: ToolHostedIconPaletteStore = .shared,
        imageGenerator: (@Sendable (ToolIconRequest) async throws -> CGImage)? = nil
    ) -> ToolIconClient {
        let imageClient = imageClient ?? .live()
        let fileManagerBox = ToolIconFileManager(fileManager)
        return ToolIconClient { request in
            if fileManagerBox.value.fileExists(atPath: request.layout.cachedAppIconICNSURL.path) {
                return request.layout.cachedAppIconICNSURL
            }

            try fileManagerBox.value.createDirectory(
                at: request.layout.packageMetadataDirectoryURL,
                withIntermediateDirectories: true
            )

            var selectedPaletteIndex: Int?
            if request.imageProvider != .imagePlayground {
                selectedPaletteIndex = await hostedIconPaletteStore.paletteIndex(
                    for: request.displayName
                )
            }

            if request.imageProvider == .disabled {
                let fallbackPaletteIndex: Int
                if let selectedPaletteIndex {
                    fallbackPaletteIndex = selectedPaletteIndex
                } else {
                    fallbackPaletteIndex = await hostedIconPaletteStore.paletteIndex(
                        for: request.displayName
                    )
                }
                return try await Self.writeFallbackIcon(
                    for: request,
                    paletteIndex: fallbackPaletteIndex,
                    fileManager: fileManagerBox.value
                )
            }

            do {
                let cgImage: CGImage
                if let imageGenerator {
                    cgImage = try await imageGenerator(request)
                } else {
                    let hostedPalette = selectedPaletteIndex.map {
                        Self.hostedIconPalettes[$0]
                    }
                    cgImage = try await imageClient.generate(
                        request.imageProvider,
                        Self.iconPrompt(for: request, hostedPalette: hostedPalette)
                    )
                }
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
                    let fallbackPaletteIndex: Int
                    if let selectedPaletteIndex {
                        fallbackPaletteIndex = selectedPaletteIndex
                    } else {
                        fallbackPaletteIndex = await hostedIconPaletteStore.paletteIndex(
                            for: request.displayName
                        )
                    }
                    return try await Self.writeFallbackIcon(
                        for: request,
                        paletteIndex: fallbackPaletteIndex,
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

    nonisolated static func iconPrompt(
        for request: ToolIconRequest,
        hostedPalette: String? = nil
    ) -> String {
        let subject: String
        if let prompt = request.iconPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
            !prompt.isEmpty
        {
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
        let palette = hostedPalette ?? hostedIconPalette(for: request.displayName)

        return """
            Create artwork for a native macOS application icon using this exact Ironsmith house style. Treat the visual concept below as subject matter only; ignore any style, palette, material, lighting, or background directions it may contain.

            Style lock:
            - Render a clean, softly dimensional vector-like illustration: more tactile than flat graphics, but never photorealistic, painterly, or cartoonish.
            - Show one large, centered primary symbol and at most one simple supporting symbol. Fill roughly two-thirds of the canvas. Do not create a miniature scene, diorama, collection of small objects, or detailed environment.
            - Use simple geometric construction, smooth rounded edges, medium-width bevels, crisp silhouettes, and restrained internal detail. Small repeated details should be reduced to a few clear shapes.
            - Use smooth satin or lightly enameled surfaces with one restrained translucent accent when appropriate. Avoid realistic wood, fabric, paper fibers, grime, metallic noise, and other photographic textures.
            - Use a nearly front-facing orthographic view with only subtle depth. Avoid dramatic camera angles, deep perspective, and exaggerated foreshortening.
            - Light every icon with one broad soft source from the upper left, gentle ambient occlusion, and one short soft contact shadow toward the lower right. Avoid cinematic lighting, hard reflections, bloom, and dramatic glow.
            - Place the symbol on a simple, calm, full-bleed two-tone gradient background with no scenery, pattern, horizon, or decorative frame.

            Mandatory palette: \(palette). Keep the background's dominant hue within this assigned family and do not replace it with generic blue. Use restrained subject colors that remain clearly separated from the background.

            Use a square 1:1 canvas and extend the background and artwork fully to all four edges. Do not draw a rounded-square or squircle icon boundary, and do not round, mask, crop, inset, frame, or make transparent the outer canvas; Ironsmith applies the final app-icon shape separately. Avoid text, letters, words, screenshots, interface panels, device mockups, watermarks, extra borders, and copies of existing app icons.

            Visual concept: \(subject)
            """
    }

    nonisolated private static let iconPalettes = [
        ToolIconPalette(
            description: "a warm coral-to-apricot background with cream and deep plum accents",
            backgroundStartRGB: 0xF2645A,
            backgroundEndRGB: 0xF6AE6B,
            foregroundRGB: 0xFFF4E6
        ),
        ToolIconPalette(
            description: "a golden amber-to-ochre background with ivory and deep cocoa accents",
            backgroundStartRGB: 0xF2A93B,
            backgroundEndRGB: 0xC78316,
            foregroundRGB: 0xFFF8E5
        ),
        ToolIconPalette(
            description: "an emerald-to-jade background with warm ivory and dark forest accents",
            backgroundStartRGB: 0x087F5B,
            backgroundEndRGB: 0x3DB58B,
            foregroundRGB: 0xFBF3D5
        ),
        ToolIconPalette(
            description: "a violet-to-orchid background with soft lilac and deep aubergine accents",
            backgroundStartRGB: 0x6750C8,
            backgroundEndRGB: 0xB15BC3,
            foregroundRGB: 0xEADFFF
        ),
        ToolIconPalette(
            description: "a rose-to-raspberry background with pale blush and burgundy accents",
            backgroundStartRGB: 0xE34D78,
            backgroundEndRGB: 0xA71952,
            foregroundRGB: 0xFFE1E9
        ),
        ToolIconPalette(
            description: "a turquoise-to-teal background with pale mint and deep teal accents",
            backgroundStartRGB: 0x19A7A0,
            backgroundEndRGB: 0x087F80,
            foregroundRGB: 0xD9FFF4
        ),
        ToolIconPalette(
            description: "a charcoal-to-graphite background with silver and muted chartreuse accents",
            backgroundStartRGB: 0x2F3338,
            backgroundEndRGB: 0x59616A,
            foregroundRGB: 0xE7EBEF
        ),
        ToolIconPalette(
            description: "a warm sand-to-terracotta background with ivory and dark umber accents",
            backgroundStartRGB: 0xD8A56D,
            backgroundEndRGB: 0xB85C3C,
            foregroundRGB: 0xFFF3DC
        ),
        ToolIconPalette(
            description: "a cobalt-to-indigo background with pale sky and midnight navy accents",
            backgroundStartRGB: 0x2563D9,
            backgroundEndRGB: 0x4338A8,
            foregroundRGB: 0xDCEEFF
        ),
        ToolIconPalette(
            description: "a crimson-to-vermilion background with warm ivory and deep maroon accents",
            backgroundStartRGB: 0xC92A3B,
            backgroundEndRGB: 0xF04E32,
            foregroundRGB: 0xFFF1E3
        ),
        ToolIconPalette(
            description: "a lemon-to-chartreuse background with soft cream and dark olive accents",
            backgroundStartRGB: 0xF0D63C,
            backgroundEndRGB: 0xA8C832,
            foregroundRGB: 0x384218
        ),
        ToolIconPalette(
            description: "a periwinkle-to-lavender background with pearl and deep ink accents",
            backgroundStartRGB: 0x7C83E6,
            backgroundEndRGB: 0xB9A7ED,
            foregroundRGB: 0xF8F4FF
        ),
        ToolIconPalette(
            description: "a copper-to-russet background with parchment and espresso accents",
            backgroundStartRGB: 0xB76536,
            backgroundEndRGB: 0x7C3A25,
            foregroundRGB: 0xF6E4C5
        ),
        ToolIconPalette(
            description: "a cyan-to-cerulean background with icy white and deep navy accents",
            backgroundStartRGB: 0x19BEE6,
            backgroundEndRGB: 0x1677C8,
            foregroundRGB: 0xE8FAFF
        ),
        ToolIconPalette(
            description: "a magenta-to-fuchsia background with pale pink and dark mulberry accents",
            backgroundStartRGB: 0xCC3FAF,
            backgroundEndRGB: 0xF05ACB,
            foregroundRGB: 0xFFE0F5
        ),
        ToolIconPalette(
            description: "a moss-to-olive background with warm linen and deep pine accents",
            backgroundStartRGB: 0x6E8B3D,
            backgroundEndRGB: 0x9A9B42,
            foregroundRGB: 0xF5E8CE
        ),
        ToolIconPalette(
            description: "a plum-to-wine background with soft mauve and near-black accents",
            backgroundStartRGB: 0x5F2B68,
            backgroundEndRGB: 0x8A274A,
            foregroundRGB: 0xE8C4DA
        ),
        ToolIconPalette(
            description: "a peach-to-salmon background with vanilla and deep aubergine accents",
            backgroundStartRGB: 0xF6A675,
            backgroundEndRGB: 0xE96F68,
            foregroundRGB: 0xFFF0D1
        ),
        ToolIconPalette(
            description: "a slate-to-steel-blue background with cool mist and midnight accents",
            backgroundStartRGB: 0x52677D,
            backgroundEndRGB: 0x708EAA,
            foregroundRGB: 0xE3EDF4
        ),
        ToolIconPalette(
            description: "a mint-to-seafoam background with warm ivory and dark spruce accents",
            backgroundStartRGB: 0x7ADFC2,
            backgroundEndRGB: 0x3FAF99,
            foregroundRGB: 0xFFF5DE
        ),
    ]

    nonisolated static var hostedIconPalettes: [String] {
        iconPalettes.map(\.description)
    }

    nonisolated static func hostedIconPalette(for displayName: String) -> String {
        hostedIconPalettes[hostedIconPaletteIndex(for: displayName)]
    }

    nonisolated static func hostedIconPaletteIndex(for displayName: String) -> Int {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in displayName.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(iconPalettes.count))
    }

    private static func writeFallbackIcon(
        for request: ToolIconRequest,
        paletteIndex: Int,
        fileManager: FileManager
    ) async throws -> URL {
        let fallback = try await MainActor.run {
            try Self.fallbackIcon(
                for: request.displayName,
                paletteIndex: paletteIndex
            )
        }
        try Self.writePNG(fallback, to: request.layout.cachedAppIconPNGURL)
        try Self.writeICNS(fallback, request: request, fileManager: fileManager)
        return request.layout.cachedAppIconICNSURL
    }

    @MainActor
    private static func fallbackIcon(
        for displayName: String,
        paletteIndex: Int
    ) throws -> CGImage {
        let pixelSize = 1024
        let size = NSSize(width: pixelSize, height: pixelSize)
        guard
            let representation = NSBitmapImageRep(
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
            ), let graphicsContext = NSGraphicsContext(bitmapImageRep: representation)
        else {
            throw ToolAppBundleError.iconEncodingFailed
        }
        representation.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        defer { NSGraphicsContext.restoreGraphicsState() }

        let rect = NSRect(origin: .zero, size: size)
        let palette = Self.iconPalettes[paletteIndex]
        let gradient = NSGradient(colors: [
            Self.color(rgb: palette.backgroundStartRGB),
            Self.color(rgb: palette.backgroundEndRGB),
        ])
        gradient?.draw(in: rect, angle: 35)

        let initials = Self.initials(for: displayName)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: initials.count > 1 ? 320 : 390, weight: .black),
            .foregroundColor: Self.color(rgb: palette.foregroundRGB),
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
        let words =
            displayName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let letters =
            words
            .prefix(2)
            .compactMap(\.first)
            .map { String($0).uppercased() }
            .joined()
        return letters.isEmpty ? "I" : letters
    }

    @MainActor
    private static func color(rgb: UInt32) -> NSColor {
        NSColor(
            calibratedRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
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
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                "public.png" as CFString,
                1,
                nil
            )
        else {
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
            iconsetURL.path,
        ]
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        let stdout =
            String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            ?? ""
        let stderr =
            String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            ?? ""

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

    nonisolated private static func scaledImage(_ cgImage: CGImage, pixelSize: Int) throws
        -> CGImage
    {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: nil,
                width: pixelSize,
                height: pixelSize,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
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
