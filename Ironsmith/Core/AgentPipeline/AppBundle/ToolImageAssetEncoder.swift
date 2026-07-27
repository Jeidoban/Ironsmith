import CoreGraphics
import Foundation
import ImageIO

nonisolated struct ToolJPEGIconAssets: Sendable {
    let masterData: Data
    let thumbnailData: Data
}

nonisolated struct ToolJPEGImageAsset: Sendable {
    let data: Data
    let width: Int
    let height: Int
}

nonisolated enum ToolImageAssetEncodingError: LocalizedError {
    case invalidImage
    case couldNotCreateImage
    case couldNotEncodeJPEG
    case masterTooLarge
    case thumbnailTooLarge
    case screenshotTooLarge
    case invalidJPEG

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            "The selected image could not be decoded."
        case .couldNotCreateImage:
            "Ironsmith could not resize the image."
        case .couldNotEncodeJPEG:
            "Ironsmith could not encode the image as JPEG."
        case .masterTooLarge:
            "The 1024×1024 app icon master exceeds 256 KiB."
        case .thumbnailTooLarge:
            "The 256×256 app icon thumbnail exceeds 64 KiB."
        case .screenshotTooLarge:
            "The Store screenshot could not be reduced below 512 KiB."
        case .invalidJPEG:
            "The Store image is not a valid JPEG with the expected dimensions."
        }
    }
}

nonisolated enum ToolImageAssetEncoder {
    static let iconMasterPixelSize = 1024
    static let iconThumbnailPixelSize = 256
    static let iconJPEGQuality = 0.60
    static let iconMasterMaximumBytes = 256 * 1024
    static let iconThumbnailMaximumBytes = 64 * 1024
    static let screenshotMaximumWidth = 1920
    static let screenshotMaximumHeight = 1440
    static let screenshotMaximumBytes = 512 * 1024
    static let screenshotMinimumDimension = 64
    static let screenshotJPEGQuality = 0.70

    static func iconAssets(from image: CGImage) throws -> ToolJPEGIconAssets {
        let master = try jpeg(
            image: try squareImage(
                image,
                pixelSize: iconMasterPixelSize,
                opaque: true
            ),
            quality: iconJPEGQuality
        )
        guard master.count <= iconMasterMaximumBytes else {
            throw ToolImageAssetEncodingError.masterTooLarge
        }

        let thumbnail = try jpeg(
            image: try squareImage(
                image,
                pixelSize: iconThumbnailPixelSize,
                opaque: true
            ),
            quality: iconJPEGQuality
        )
        guard thumbnail.count <= iconThumbnailMaximumBytes else {
            throw ToolImageAssetEncodingError.thumbnailTooLarge
        }
        return ToolJPEGIconAssets(masterData: master, thumbnailData: thumbnail)
    }

    static func screenshot(from data: Data) throws -> ToolJPEGImageAsset {
        let image = try decodeImage(data, applyingOrientation: true)
        return try screenshot(from: image)
    }

    static func screenshot(from image: CGImage) throws -> ToolJPEGImageAsset {
        let initialScale = min(
            1,
            CGFloat(screenshotMaximumWidth) / CGFloat(image.width),
            CGFloat(screenshotMaximumHeight) / CGFloat(image.height)
        )
        var width = max(1, Int((CGFloat(image.width) * initialScale).rounded(.down)))
        var height = max(1, Int((CGFloat(image.height) * initialScale).rounded(.down)))
        let minimumDimension = min(screenshotMinimumDimension, width, height)

        for _ in 0..<10 {
            let resized = try resizedImage(
                image,
                width: width,
                height: height,
                opaque: true
            )
            let encoded = try jpeg(image: resized, quality: screenshotJPEGQuality)
            if encoded.count <= screenshotMaximumBytes {
                return ToolJPEGImageAsset(data: encoded, width: width, height: height)
            }

            let reduction = min(
                0.9,
                sqrt(CGFloat(screenshotMaximumBytes) / CGFloat(encoded.count)) * 0.95
            )
            let minimumScale = max(
                CGFloat(minimumDimension) / CGFloat(width),
                CGFloat(minimumDimension) / CGFloat(height)
            )
            let nextScale = max(reduction, minimumScale)
            let nextWidth = max(1, Int((CGFloat(width) * nextScale).rounded(.down)))
            let nextHeight = max(1, Int((CGFloat(height) * nextScale).rounded(.down)))
            guard nextWidth < width || nextHeight < height else { break }
            width = nextWidth
            height = nextHeight
        }
        throw ToolImageAssetEncodingError.screenshotTooLarge
    }

    static func validateIconMasterJPEG(_ data: Data) throws -> CGImage {
        try validateJPEG(
            data,
            width: iconMasterPixelSize,
            height: iconMasterPixelSize,
            maximumBytes: iconMasterMaximumBytes
        )
    }

    static func validateIconThumbnailJPEG(_ data: Data) throws -> CGImage {
        try validateJPEG(
            data,
            width: iconThumbnailPixelSize,
            height: iconThumbnailPixelSize,
            maximumBytes: iconThumbnailMaximumBytes
        )
    }

    static func decodeImage(_ data: Data, applyingOrientation: Bool = false) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) == 1
        else {
            throw ToolImageAssetEncodingError.invalidImage
        }
        if applyingOrientation {
            let properties =
                CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any]
            let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
            let maximumDimension = max(width, height)
            guard maximumDimension > 0,
                let image = CGImageSourceCreateThumbnailAtIndex(
                    source,
                    0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
                        kCGImageSourceShouldCacheImmediately: true,
                    ] as CFDictionary
                )
            else {
                throw ToolImageAssetEncodingError.invalidImage
            }
            return image
        }
        guard
            let image = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            )
        else {
            throw ToolImageAssetEncodingError.invalidImage
        }
        return image
    }

    static func largestImage(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            CGImageSourceGetCount(source) > 0
        else {
            throw ToolImageAssetEncodingError.invalidImage
        }
        let index =
            (0..<CGImageSourceGetCount(source)).max { lhs, rhs in
                pixelArea(source: source, index: lhs) < pixelArea(source: source, index: rhs)
            } ?? 0
        guard
            let image = CGImageSourceCreateImageAtIndex(
                source,
                index,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            )
        else {
            throw ToolImageAssetEncodingError.invalidImage
        }
        return image
    }

    static func squareImage(
        _ image: CGImage,
        pixelSize: Int,
        opaque: Bool
    ) throws -> CGImage {
        let scale = max(
            CGFloat(pixelSize) / CGFloat(image.width),
            CGFloat(pixelSize) / CGFloat(image.height)
        )
        let drawWidth = CGFloat(image.width) * scale
        let drawHeight = CGFloat(image.height) * scale
        return try renderedImage(
            image,
            width: pixelSize,
            height: pixelSize,
            drawRect: CGRect(
                x: (CGFloat(pixelSize) - drawWidth) / 2,
                y: (CGFloat(pixelSize) - drawHeight) / 2,
                width: drawWidth,
                height: drawHeight
            ),
            opaque: opaque
        )
    }

    static func resizedImage(
        _ image: CGImage,
        width: Int,
        height: Int,
        opaque: Bool
    ) throws -> CGImage {
        try renderedImage(
            image,
            width: width,
            height: height,
            drawRect: CGRect(x: 0, y: 0, width: width, height: height),
            opaque: opaque
        )
    }

    private static func validateJPEG(
        _ data: Data,
        width: Int,
        height: Int,
        maximumBytes: Int
    ) throws -> CGImage {
        guard !data.isEmpty, data.count <= maximumBytes,
            !containsForbiddenJPEGMetadata(data),
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) == 1,
            CGImageSourceGetType(source) as String? == "public.jpeg",
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            properties[kCGImagePropertyPixelWidth] as? Int == width,
            properties[kCGImagePropertyPixelHeight] as? Int == height,
            let image = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            )
        else {
            throw ToolImageAssetEncodingError.invalidJPEG
        }
        return image
    }

    private static func jpeg(image: CGImage, quality: Double) throws -> Data {
        guard
            let data = NSMutableData(
                capacity: max(4_096, image.width * image.height)
            )
        else {
            throw ToolImageAssetEncodingError.couldNotEncodeJPEG
        }
        guard
            let destination = CGImageDestinationCreateWithData(
                data,
                "public.jpeg" as CFString,
                1,
                nil
            )
        else {
            throw ToolImageAssetEncodingError.couldNotEncodeJPEG
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [
                kCGImageDestinationLossyCompressionQuality: min(max(quality, 0), 1)
            ] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination), data.length > 0 else {
            throw ToolImageAssetEncodingError.couldNotEncodeJPEG
        }
        return try strippingForbiddenJPEGMetadata(data as Data)
    }

    static func containsForbiddenJPEGMetadata(_ data: Data) -> Bool {
        guard let segments = try? jpegSegments(in: data) else {
            return true
        }
        return segments.contains { $0.marker == 0xe1 || $0.marker == 0xed }
    }

    private static func strippingForbiddenJPEGMetadata(_ data: Data) throws -> Data {
        let segments = try jpegSegments(in: data)
        var result = data
        for segment in segments.reversed()
        where segment.marker == 0xe1 || segment.marker == 0xed {
            result.removeSubrange(segment.range)
        }
        return result
    }

    private static func jpegSegments(in data: Data) throws -> [(
        marker: UInt8, range: Range<Data.Index>
    )] {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0xff, bytes[1] == 0xd8 else {
            throw ToolImageAssetEncodingError.invalidJPEG
        }
        var segments: [(marker: UInt8, range: Range<Data.Index>)] = []
        var index = 2
        while index < bytes.count {
            guard bytes[index] == 0xff else {
                throw ToolImageAssetEncodingError.invalidJPEG
            }
            let markerStart = index
            while index < bytes.count, bytes[index] == 0xff {
                index += 1
            }
            guard index < bytes.count else {
                throw ToolImageAssetEncodingError.invalidJPEG
            }
            let marker = bytes[index]
            index += 1
            if marker == 0xda || marker == 0xd9 {
                break
            }
            if marker == 0x01 || (0xd0...0xd7).contains(marker) {
                segments.append((marker, markerStart..<index))
                continue
            }
            guard index + 1 < bytes.count else {
                throw ToolImageAssetEncodingError.invalidJPEG
            }
            let length = Int(bytes[index]) << 8 | Int(bytes[index + 1])
            guard length >= 2, index + length <= bytes.count else {
                throw ToolImageAssetEncodingError.invalidJPEG
            }
            let segmentEnd = index + length
            segments.append((marker, markerStart..<segmentEnd))
            index = segmentEnd
        }
        return segments
    }

    private static func renderedImage(
        _ image: CGImage,
        width: Int,
        height: Int,
        drawRect: CGRect,
        opaque: Bool
    ) throws -> CGImage {
        guard width > 0, height > 0 else {
            throw ToolImageAssetEncodingError.couldNotCreateImage
        }
        let colorSpace =
            CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
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
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        if opaque {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(canvas)
        }
        context.interpolationQuality = .high
        context.draw(image, in: drawRect)
        guard let rendered = context.makeImage() else {
            throw ToolImageAssetEncodingError.couldNotCreateImage
        }
        return rendered
    }

    private static func pixelArea(source: CGImageSource, index: Int) -> Int {
        let properties =
            CGImageSourceCopyPropertiesAtIndex(source, index, nil)
            as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        return width * height
    }
}
