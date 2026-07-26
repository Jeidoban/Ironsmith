#if DEBUG
    import CoreGraphics
    import Foundation
    import ImageIO
    import Testing

    @testable import Ironsmith

    @Suite("Debug icon export")
    struct DebugIconExportTests {
        @Test(
            "Exports master and thumbnail in every experimental format",
            arguments: DebugIconImageFormat.allCases
        )
        func exportsMasterAndThumbnail(format: DebugIconImageFormat) throws {
            guard DebugIconExportClient.supportsEncoding(format) else {
                #expect(format == .webP)
                return
            }

            let outputRootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: outputRootURL) }

            let result = try DebugIconExportClient.export(
                DebugIconExportRequest(
                    image: try testImage(pixelSize: 64),
                    format: format,
                    quality: 0.8,
                    masterPixelSize: 512,
                    thumbnailPixelSize: 256,
                    targetMasterByteCount: nil,
                    outputRootURL: outputRootURL,
                    providerName: "Test Provider"
                )
            )

            #expect(FileManager.default.fileExists(atPath: result.masterURL.path))
            #expect(FileManager.default.fileExists(atPath: result.thumbnailURL.path))
            #expect(try dimensions(of: result.masterData) == CGSize(width: 512, height: 512))
            #expect(try dimensions(of: result.thumbnailData) == CGSize(width: 256, height: 256))
            #expect(result.masterURL.pathExtension == format.fileExtension)
            #expect(result.thumbnailURL.pathExtension == format.fileExtension)
        }

        @Test("Reports when an intentionally tiny JPEG target cannot be reached")
        func reportsUnmetTarget() throws {
            let outputRootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: outputRootURL) }

            let result = try DebugIconExportClient.export(
                DebugIconExportRequest(
                    image: try testImage(pixelSize: 64),
                    format: .jpeg,
                    quality: 0.9,
                    masterPixelSize: 512,
                    thumbnailPixelSize: 256,
                    targetMasterByteCount: 1,
                    outputRootURL: outputRootURL,
                    providerName: "Test Provider"
                )
            )

            #expect(!result.metTargetMasterSize)
            #expect((result.effectiveMasterQuality ?? 1) < 0.9)
        }

        private func testImage(pixelSize: Int) throws -> CGImage {
            guard
                let context = CGContext(
                    data: nil,
                    width: pixelSize,
                    height: pixelSize,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else {
                throw DebugIconExportError.couldNotScaleImage
            }
            context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
            guard let image = context.makeImage() else {
                throw DebugIconExportError.couldNotScaleImage
            }
            return image
        }

        private func dimensions(of data: Data) throws -> CGSize {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
            else {
                throw DebugIconExportError.couldNotEncode(.png)
            }
            return CGSize(width: width.doubleValue, height: height.doubleValue)
        }
    }
#endif
