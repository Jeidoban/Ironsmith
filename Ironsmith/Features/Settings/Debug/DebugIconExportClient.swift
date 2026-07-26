#if DEBUG
    import CoreGraphics
    import Foundation
    import ImageIO

    enum DebugIconImageFormat: String, CaseIterable, Identifiable {
        case png
        case jpeg
        case webP = "webp"
        case heic

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .png:
                "PNG"
            case .jpeg:
                "JPEG"
            case .webP:
                "WebP"
            case .heic:
                "HEIC"
            }
        }

        var fileExtension: String { rawValue }

        var typeIdentifier: CFString {
            switch self {
            case .png:
                "public.png" as CFString
            case .jpeg:
                "public.jpeg" as CFString
            case .webP:
                "org.webmproject.webp" as CFString
            case .heic:
                "public.heic" as CFString
            }
        }

        var supportsLossyQuality: Bool {
            self != .png
        }
    }

    struct DebugIconExportRequest {
        let image: CGImage
        let format: DebugIconImageFormat
        let quality: Double
        let masterPixelSize: Int
        let thumbnailPixelSize: Int
        let targetMasterByteCount: Int?
        let outputRootURL: URL
        let providerName: String
    }

    struct DebugIconExportResult {
        let directoryURL: URL
        let masterURL: URL
        let thumbnailURL: URL
        let masterData: Data
        let thumbnailData: Data
        let effectiveMasterQuality: Double?
        let targetMasterByteCount: Int?

        var metTargetMasterSize: Bool {
            guard let targetMasterByteCount else { return true }
            return masterData.count <= targetMasterByteCount
        }
    }

    enum DebugIconExportError: LocalizedError {
        case invalidPixelSize
        case couldNotScaleImage
        case unsupportedFormat(DebugIconImageFormat)
        case couldNotEncode(DebugIconImageFormat)

        var errorDescription: String? {
            switch self {
            case .invalidPixelSize:
                "Icon dimensions must be greater than zero."
            case .couldNotScaleImage:
                "The generated icon could not be resized."
            case .unsupportedFormat(let format):
                "\(format.displayName) encoding is unavailable on this Mac."
            case .couldNotEncode(let format):
                "The icon could not be encoded as \(format.displayName)."
            }
        }
    }

    enum DebugIconExportClient {
        private static let minimumLossyQuality = 0.05
        private static let qualityStep = 0.05

        static func supportsEncoding(_ format: DebugIconImageFormat) -> Bool {
            let supportedTypes = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
            return supportedTypes.contains(format.typeIdentifier as String)
        }

        static func export(_ request: DebugIconExportRequest) throws -> DebugIconExportResult {
            guard request.masterPixelSize > 0, request.thumbnailPixelSize > 0 else {
                throw DebugIconExportError.invalidPixelSize
            }
            guard supportsEncoding(request.format) else {
                throw DebugIconExportError.unsupportedFormat(request.format)
            }

            let masterImage = try squareImage(
                request.image,
                pixelSize: request.masterPixelSize,
                fillsOpaqueBackground: request.format == .jpeg
            )
            let thumbnailImage = try squareImage(
                request.image,
                pixelSize: request.thumbnailPixelSize,
                fillsOpaqueBackground: request.format == .jpeg
            )
            let requestedQuality = min(max(request.quality, minimumLossyQuality), 1)
            let masterEncoding = try encodeMaster(
                masterImage,
                format: request.format,
                requestedQuality: requestedQuality,
                targetByteCount: request.targetMasterByteCount
            )
            let thumbnailData = try encode(
                thumbnailImage,
                format: request.format,
                quality: request.format.supportsLossyQuality ? requestedQuality : nil
            )

            let runDirectoryURL = request.outputRootURL.appendingPathComponent(
                runDirectoryName(
                    providerName: request.providerName,
                    format: request.format
                ),
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: runDirectoryURL,
                withIntermediateDirectories: true
            )

            let masterURL = runDirectoryURL.appendingPathComponent(
                "AppIconMaster-\(request.masterPixelSize).\(request.format.fileExtension)"
            )
            let thumbnailURL = runDirectoryURL.appendingPathComponent(
                "AppIconThumbnail-\(request.thumbnailPixelSize).\(request.format.fileExtension)"
            )
            try masterEncoding.data.write(to: masterURL, options: .atomic)
            try thumbnailData.write(to: thumbnailURL, options: .atomic)

            return DebugIconExportResult(
                directoryURL: runDirectoryURL,
                masterURL: masterURL,
                thumbnailURL: thumbnailURL,
                masterData: masterEncoding.data,
                thumbnailData: thumbnailData,
                effectiveMasterQuality: masterEncoding.quality,
                targetMasterByteCount: request.targetMasterByteCount
            )
        }

        private static func encodeMaster(
            _ image: CGImage,
            format: DebugIconImageFormat,
            requestedQuality: Double,
            targetByteCount: Int?
        ) throws -> (data: Data, quality: Double?) {
            guard format.supportsLossyQuality else {
                return (try encode(image, format: format, quality: nil), nil)
            }

            var quality = requestedQuality
            var smallest = try encode(image, format: format, quality: quality)
            var effectiveQuality = quality
            guard let targetByteCount, targetByteCount > 0 else {
                return (smallest, effectiveQuality)
            }

            while smallest.count > targetByteCount,
                quality - qualityStep >= minimumLossyQuality
            {
                quality = max(minimumLossyQuality, quality - qualityStep)
                let candidate = try encode(image, format: format, quality: quality)
                if candidate.count < smallest.count {
                    smallest = candidate
                    effectiveQuality = quality
                }
            }
            return (smallest, effectiveQuality)
        }

        private static func encode(
            _ image: CGImage,
            format: DebugIconImageFormat,
            quality: Double?
        ) throws -> Data {
            let capacity = max(4_096, image.width * image.height)
            guard let data = NSMutableData(capacity: capacity),
                let destination = CGImageDestinationCreateWithData(
                    data,
                    format.typeIdentifier,
                    1,
                    nil
                )
            else {
                throw DebugIconExportError.unsupportedFormat(format)
            }

            var properties: [CFString: Any] = [:]
            if let quality {
                properties[kCGImageDestinationLossyCompressionQuality] = quality
            }
            CGImageDestinationAddImage(
                destination,
                image,
                properties.isEmpty ? nil : properties as CFDictionary
            )
            guard CGImageDestinationFinalize(destination), data.length > 0 else {
                throw DebugIconExportError.couldNotEncode(format)
            }
            return data as Data
        }

        private static func squareImage(
            _ image: CGImage,
            pixelSize: Int,
            fillsOpaqueBackground: Bool
        ) throws -> CGImage {
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
                ?? CGColorSpaceCreateDeviceRGB()
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
                throw DebugIconExportError.couldNotScaleImage
            }

            let canvas = CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
            if fillsOpaqueBackground {
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(canvas)
            }

            let scale = max(
                CGFloat(pixelSize) / CGFloat(image.width),
                CGFloat(pixelSize) / CGFloat(image.height)
            )
            let drawSize = CGSize(
                width: CGFloat(image.width) * scale,
                height: CGFloat(image.height) * scale
            )
            let drawRect = CGRect(
                x: (CGFloat(pixelSize) - drawSize.width) / 2,
                y: (CGFloat(pixelSize) - drawSize.height) / 2,
                width: drawSize.width,
                height: drawSize.height
            )
            context.interpolationQuality = .high
            context.draw(image, in: drawRect)
            guard let result = context.makeImage() else {
                throw DebugIconExportError.couldNotScaleImage
            }
            return result
        }

        private static func runDirectoryName(
            providerName: String,
            format: DebugIconImageFormat
        ) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
            let provider = providerName
                .lowercased()
                .replacingOccurrences(
                    of: "[^a-z0-9]+",
                    with: "-",
                    options: .regularExpression
                )
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            return "\(formatter.string(from: Date()))-\(provider)-\(format.rawValue)"
        }
    }
#endif
