import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import Ironsmith

@Suite("Tool image asset encoder")
struct ToolImageAssetEncoderTests {
    @Test
    func iconJPEGsUseRequiredDimensionsLimitsColorAndOpaqueBackground() throws {
        #expect(ToolImageAssetEncoder.iconJPEGQuality == 0.60)
        #expect(ToolImageAssetEncoder.screenshotJPEGQuality == 0.70)
        let source = try Self.transparentIconImage()

        let assets = try ToolImageAssetEncoder.iconAssets(from: source)

        let master = try Self.imageProperties(assets.masterData)
        let thumbnail = try Self.imageProperties(assets.thumbnailData)
        #expect(master.type == "public.jpeg")
        #expect(master.width == 1024)
        #expect(master.height == 1024)
        #expect(thumbnail.type == "public.jpeg")
        #expect(thumbnail.width == 256)
        #expect(thumbnail.height == 256)
        #expect(assets.masterData.count <= ToolImageAssetEncoder.iconMasterMaximumBytes)
        #expect(
            assets.thumbnailData.count
                <= ToolImageAssetEncoder.iconThumbnailMaximumBytes
        )
        #expect(!ToolImageAssetEncoder.containsForbiddenJPEGMetadata(assets.masterData))
        #expect(
            !ToolImageAssetEncoder.containsForbiddenJPEGMetadata(
                assets.thumbnailData
            )
        )

        let thumbnailImage = try ToolImageAssetEncoder.validateIconThumbnailJPEG(
            assets.thumbnailData
        )
        #expect(thumbnailImage.bitsPerComponent == 8)
        #expect(thumbnailImage.colorSpace?.name == CGColorSpace.sRGB)
        let corner = try #require(NSBitmapImageRep(cgImage: thumbnailImage).colorAt(x: 0, y: 0))
        #expect(corner.alphaComponent > 0.99)
        #expect(corner.redComponent > 0.95)
        #expect(corner.greenComponent > 0.95)
        #expect(corner.blueComponent > 0.95)
    }

    @MainActor
    @Test
    func generatedICNSKeepsOriginalTransparencyWhileJPEGsAreOpaque() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = ToolPackageLayout(
            packageRootURL: root.appendingPathComponent("OriginalIcon", isDirectory: true),
            executableName: "OriginalIcon"
        )
        let source = try Self.transparentIconImage()
        let client = ToolIconClient.live(imageGenerator: { _ in source })

        _ = try await client.ensureIconAssets(
            ToolIconRequest(
                displayName: "Original Icon",
                layout: layout,
                imageProvider: .openAI
            )
        )

        let icnsImage = try ToolImageAssetEncoder.largestImage(
            at: layout.cachedAppIconICNSURL
        )
        let icnsCorner = try #require(
            NSBitmapImageRep(cgImage: icnsImage).colorAt(x: 0, y: 0)
        )
        let thumbnailData = try Data(
            contentsOf: layout.cachedAppIconThumbnailJPEGURL
        )
        let thumbnailImage = try ToolImageAssetEncoder.validateIconThumbnailJPEG(
            thumbnailData
        )
        let thumbnailCorner = try #require(
            NSBitmapImageRep(cgImage: thumbnailImage).colorAt(x: 0, y: 0)
        )

        #expect(icnsCorner.alphaComponent < 0.1)
        #expect(thumbnailCorner.alphaComponent > 0.99)
        #expect(thumbnailCorner.redComponent > 0.95)
        #expect(thumbnailCorner.greenComponent > 0.95)
        #expect(thumbnailCorner.blueComponent > 0.95)
    }

    @MainActor
    @Test
    func legacyICNSMigrationPreservesICNSAndCreatesJPEGs() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = ToolPackageLayout(
            packageRootURL: root.appendingPathComponent("LegacyICNS", isDirectory: true),
            executableName: "LegacyICNS"
        )
        let source = try Self.transparentIconImage()
        let liveClient = ToolIconClient.live(imageGenerator: { _ in source })
        let request = ToolIconRequest(
            displayName: "Legacy ICNS",
            layout: layout,
            imageProvider: .openAI
        )
        _ = try await liveClient.ensureIconAssets(request)
        let originalICNS = try Data(contentsOf: layout.cachedAppIconICNSURL)
        try FileManager.default.removeItem(at: layout.cachedAppIconMasterJPEGURL)
        try FileManager.default.removeItem(at: layout.cachedAppIconThumbnailJPEGURL)

        _ = try await ToolIconClient.cachedOnly().ensureIconAssets(request)

        #expect(try Data(contentsOf: layout.cachedAppIconICNSURL) == originalICNS)
        #expect(
            FileManager.default.fileExists(
                atPath: layout.cachedAppIconMasterJPEGURL.path
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: layout.cachedAppIconThumbnailJPEGURL.path
            )
        )
    }

    @Test
    func legacyPNGMigrationCreatesCompleteAssetSetThenRemovesPNG() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = ToolPackageLayout(
            packageRootURL: root.appendingPathComponent("LegacyPNG", isDirectory: true),
            executableName: "LegacyPNG"
        )
        try FileManager.default.createDirectory(
            at: layout.packageMetadataDirectoryURL,
            withIntermediateDirectories: true
        )
        try Self.pngData(from: Self.transparentIconImage()).write(
            to: layout.cachedAppIconPNGURL,
            options: .atomic
        )

        _ = try await ToolIconClient.cachedOnly().ensureIconAssets(
            ToolIconRequest(displayName: "Legacy PNG", layout: layout)
        )

        #expect(
            FileManager.default.fileExists(atPath: layout.cachedAppIconICNSURL.path)
        )
        #expect(
            FileManager.default.fileExists(
                atPath: layout.cachedAppIconMasterJPEGURL.path
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: layout.cachedAppIconThumbnailJPEGURL.path
            )
        )
        #expect(!FileManager.default.fileExists(atPath: layout.cachedAppIconPNGURL.path))
    }

    @Test
    func screenshotsFitWithoutEnlargementAndStripMetadata() throws {
        let wide = try Self.solidImage(width: 2000, height: 1000)
        let small = try Self.solidImage(width: 400, height: 300)

        let wideAsset = try ToolImageAssetEncoder.screenshot(from: wide)
        let smallAsset = try ToolImageAssetEncoder.screenshot(from: small)

        #expect(wideAsset.width == 1920)
        #expect(wideAsset.height == 960)
        #expect(smallAsset.width == 400)
        #expect(smallAsset.height == 300)
        #expect(wideAsset.data.count <= ToolImageAssetEncoder.screenshotMaximumBytes)
        let properties = try Self.imageProperties(wideAsset.data)
        #expect(properties.type == "public.jpeg")
        #expect(!ToolImageAssetEncoder.containsForbiddenJPEGMetadata(wideAsset.data))
    }

    @Test
    func oversizedScreenshotShrinksDimensionsAtFixedQuality() throws {
        let noisy = try Self.noisyImage(width: 1920, height: 1440)

        let asset = try ToolImageAssetEncoder.screenshot(from: noisy)

        #expect(asset.data.count <= ToolImageAssetEncoder.screenshotMaximumBytes)
        #expect(asset.width < 1920)
        #expect(asset.height < 1440)
        #expect(
            abs(
                Double(asset.width) / Double(asset.height)
                    - Double(1920) / Double(1440)
            ) < 0.002
        )
        #expect(asset.width >= ToolImageAssetEncoder.screenshotMinimumDimension)
        #expect(asset.height >= ToolImageAssetEncoder.screenshotMinimumDimension)
    }

    @Test
    func screenshotDecodeDownsamplesLargeSourceBeforeEncoding() throws {
        let source = try Self.solidImage(width: 4000, height: 2000)
        let sourceData = try Self.pngData(from: source)

        let decoded = try ToolImageAssetEncoder.decodeImage(
            sourceData,
            applyingOrientation: true,
            maximumPixelSize: max(
                ToolImageAssetEncoder.screenshotMaximumWidth,
                ToolImageAssetEncoder.screenshotMaximumHeight
            )
        )
        let asset = try ToolImageAssetEncoder.screenshot(from: sourceData)

        #expect(decoded.width <= ToolImageAssetEncoder.screenshotMaximumWidth)
        #expect(decoded.height <= ToolImageAssetEncoder.screenshotMaximumHeight)
        #expect(asset.width == 1920)
        #expect(asset.height == 960)
    }

    private static func transparentIconImage() throws -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard
            let context = CGContext(
                data: nil,
                width: 1024,
                height: 1024,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw ToolImageAssetEncodingError.couldNotCreateImage
        }
        context.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1))
        context.fillEllipse(in: CGRect(x: 128, y: 128, width: 768, height: 768))
        return try #require(context.makeImage())
    }

    private static func solidImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw ToolImageAssetEncodingError.couldNotCreateImage
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private static func noisyImage(width: Int, height: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        var state: UInt64 = 0x1234_5678_9abc_def0
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            bytes[offset] = UInt8(truncatingIfNeeded: state >> 24)
            bytes[offset + 1] = UInt8(truncatingIfNeeded: state >> 32)
            bytes[offset + 2] = UInt8(truncatingIfNeeded: state >> 40)
            bytes[offset + 3] = 255
        }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData),
            let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.last.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )
        else {
            throw ToolImageAssetEncodingError.couldNotCreateImage
        }
        return image
    }

    private static func pngData(from image: CGImage) throws -> Data {
        guard let data = NSMutableData(capacity: image.width * image.height),
            let destination = CGImageDestinationCreateWithData(
                data,
                "public.png" as CFString,
                1,
                nil
            )
        else {
            throw ToolImageAssetEncodingError.couldNotEncodeJPEG
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ToolImageAssetEncodingError.couldNotEncodeJPEG
        }
        return data as Data
    }

    private static func imageProperties(_ data: Data) throws -> (
        type: String?,
        width: Int,
        height: Int
    ) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any]
        )
        return (
            CGImageSourceGetType(source) as String?,
            properties[kCGImagePropertyPixelWidth] as? Int ?? 0,
            properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        )
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ironsmith-image-asset-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}
