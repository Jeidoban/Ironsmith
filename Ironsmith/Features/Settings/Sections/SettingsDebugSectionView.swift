#if DEBUG
    import AppKit
    import ImageIO
    import ImagePlayground
    import SwiftUI
    import UniformTypeIdentifiers

    struct SettingsDebugSectionView: View {
        @Environment(InferenceStore.self) private var inferenceStore
        @AppStorage(IronsmithPreferenceKeys.debugAlwaysShowWelcomeOnboarding)
        private var alwaysShowWelcomeOnboarding = false
        @AppStorage(IronsmithPreferenceKeys.debugAlwaysOpenOllamaEditorAfterAdd)
        private var alwaysOpenOllamaEditorAfterAdd = false
        @AppStorage(IronsmithPreferenceKeys.debugAlwaysShowAppleFoundationModelWarning)
        private var alwaysShowAppleFoundationModelWarning = false
        @AppStorage(IronsmithPreferenceKeys.debugPopoverEmptyStateMode)
        private var popoverEmptyStateModeRawValue = ToolLibraryDebugPopoverEmptyStateMode.off
            .rawValue
        @AppStorage(IronsmithPreferenceKeys.featureStoreEnabled)
        private var storeFeatureEnabled = false
        @AppStorage(IronsmithPreferenceKeys.featureDiagnosticWholeFileRewriteEnabled)
        private var diagnosticWholeFileRewriteEnabled = false
        @State private var iconLabPrompt = ""
        @State private var iconLabFormat = DebugIconImageFormat.png
        @State private var iconLabQuality = 0.8
        @State private var iconLabMasterPixelSize = 1024
        @State private var iconLabTargetMasterKilobytes = "128"
        @State private var iconLabMasterPreview: NSImage?
        @State private var iconLabThumbnailPreview: NSImage?
        @State private var iconLabResult: DebugIconExportResult?
        @State private var iconLabDescription: String?
        @State private var iconLabErrorMessage: String?
        @State private var isGeneratingIconLabImages = false
        @State private var imagePlaygroundCoordinator = ImagePlaygroundSheetCoordinator()
        @State private var isShowingImageImporter = false
        @State private var imageImporterPurpose = SettingsDebugImageImporterPurpose.iconPNG
        @State private var importedIconLabPNG: CGImage?
        @State private var importedIconLabPNGName: String?
        @State private var downscaledImagePreview: NSImage?
        @State private var downscaledImageOutputURL: URL?
        @State private var downscaledImageDescription: String?
        @State private var imageDownscalerErrorMessage: String?

        var body: some View {
            Section {
                Toggle("Always show onboarding sheet", isOn: $alwaysShowWelcomeOnboarding)
                    .toggleStyle(.switch)

                Toggle(
                    "Always open Ollama editor after adding Ollama",
                    isOn: $alwaysOpenOllamaEditorAfterAdd
                )
                .toggleStyle(.switch)

                Toggle(
                    "Always show Apple Foundation warning",
                    isOn: $alwaysShowAppleFoundationModelWarning
                )
                .toggleStyle(.switch)

                Picker("Popover empty state", selection: $popoverEmptyStateModeRawValue) {
                    ForEach(ToolLibraryDebugPopoverEmptyStateMode.allCases) { mode in
                        Text(mode.displayName)
                            .tag(mode.rawValue)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Feature Flags")
                        .font(.headline)

                    Toggle("Ironsmith Store", isOn: $storeFeatureEnabled)
                        .toggleStyle(.switch)

                    Toggle(
                        "Spark diagnostic whole-file recovery",
                        isOn: $diagnosticWholeFileRewriteEnabled
                    )
                    .toggleStyle(.switch)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("App Icon Format Lab")
                        .font(.headline)

                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        TextField(
                            "Prompt",
                            text: $iconLabPrompt,
                            prompt: Text("A friendly forge icon")
                        )
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            startIconLabGeneration()
                        }

                        Button(isGeneratingIconLabImages ? "Working..." : "Generate & Export") {
                            startIconLabGeneration()
                        }
                        .disabled(isIconLabGenerateDisabled)
                    }

                    Text(iconLabProviderDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button("Choose PNG…") {
                            presentImageImporter(for: .iconPNG)
                        }

                        if importedIconLabPNG != nil {
                            Button("Export Selected PNG") {
                                exportImportedIconLabPNG()
                            }
                            .disabled(isIconLabExportDisabled)
                        }

                        if let importedIconLabPNGName {
                            Text(importedIconLabPNGName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 16) {
                        Picker("Format", selection: $iconLabFormat) {
                            ForEach(DebugIconImageFormat.allCases) { format in
                                Text(format.displayName)
                                    .tag(format)
                            }
                        }
                        .frame(maxWidth: 180)

                        Picker("Master", selection: $iconLabMasterPixelSize) {
                            Text("512×512").tag(512)
                            Text("1024×1024").tag(1024)
                            Text("2048×2048").tag(2048)
                        }
                        .frame(maxWidth: 190)
                    }

                    HStack(spacing: 10) {
                        Text("Quality")
                        Slider(value: $iconLabQuality, in: 0.05...1, step: 0.05)
                            .disabled(!iconLabFormat.supportsLossyQuality)
                        Text(iconLabFormat.supportsLossyQuality
                            ? iconLabQuality.formatted(.number.precision(.fractionLength(2)))
                            : "Lossless")
                            .font(.caption.monospacedDigit())
                            .frame(width: 58, alignment: .trailing)
                    }

                    HStack(spacing: 10) {
                        Text("Master target")
                        TextField("Optional", text: $iconLabTargetMasterKilobytes)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Text("KB")
                            .foregroundStyle(.secondary)
                    }

                    Text(
                        "A target lowers lossy quality in 0.05 steps when necessary. "
                            + "PNG ignores quality and the target."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if !DebugIconExportClient.supportsEncoding(iconLabFormat) {
                        Text(
                            "\(iconLabFormat.displayName) can be decoded but not encoded by "
                                + "Image I/O on this Mac. A WebP codec dependency would be required."
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }

                    if isGeneratingIconLabImages {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Processing icon")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }

                    if let iconLabErrorMessage {
                        Text(iconLabErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if let iconLabMasterPreview, let iconLabThumbnailPreview {
                        HStack(alignment: .top, spacing: 18) {
                            iconLabPreview(
                                title: "Master",
                                image: iconLabMasterPreview,
                                size: 180
                            )
                            iconLabPreview(
                                title: "Thumbnail",
                                image: iconLabThumbnailPreview,
                                size: 96
                            )
                        }
                    }

                    if let iconLabDescription {
                        Text(iconLabDescription)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    if let iconLabResult {
                        Button("Show Exports in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([
                                iconLabResult.masterURL,
                                iconLabResult.thumbnailURL,
                            ])
                        }
                    }

                    Text("Writes each experiment to ~/.ironsmith/.debug/icon-format-lab.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Attachment Image Downscaler")
                        .font(.headline)

                    HStack(spacing: 10) {
                        Button("Choose Image…") {
                            presentImageImporter(for: .attachment)
                        }

                        if let downscaledImageOutputURL {
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([
                                    downscaledImageOutputURL
                                ])
                            }
                        }
                    }

                    Text("Writes the normalized attachment image to ~/.ironsmith/.debug.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let imageDownscalerErrorMessage {
                        Text(imageDownscalerErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if let downscaledImagePreview {
                        Image(nsImage: downscaledImagePreview)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 180, height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(.quaternary, lineWidth: 1)
                            }
                    }

                    if let downscaledImageDescription {
                        Text(downscaledImageDescription)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Debug")
            }
            .imagePlaygroundSheet(
                isPresented: Binding(
                    get: { imagePlaygroundCoordinator.isPresented },
                    set: { imagePlaygroundCoordinator.presentationChanged($0) }
                ),
                concept: imagePlaygroundCoordinator.prompt,
                onCompletion: imagePlaygroundCoordinator.completed(with:),
                onCancellation: imagePlaygroundCoordinator.canceled
            )
            .fileImporter(
                isPresented: $isShowingImageImporter,
                allowedContentTypes: imageImporterPurpose.allowedContentTypes,
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                switch imageImporterPurpose {
                case .iconPNG:
                    importIconLabPNG(at: url)
                case .attachment:
                    downscaleAttachmentImage(at: url)
                }
            }
        }

        private func presentImageImporter(for purpose: SettingsDebugImageImporterPurpose) {
            imageImporterPurpose = purpose
            isShowingImageImporter = true
        }

        private var isIconLabGenerateDisabled: Bool {
            isGeneratingIconLabImages
                || iconLabPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || inferenceStore.effectiveImageGenerationProvider == .disabled
                || !DebugIconExportClient.supportsEncoding(iconLabFormat)
        }

        private var isIconLabExportDisabled: Bool {
            isGeneratingIconLabImages
                || importedIconLabPNG == nil
                || !DebugIconExportClient.supportsEncoding(iconLabFormat)
        }

        private var iconLabProviderDescription: String {
            let selected = inferenceStore.generationPreferences.imageGenerationProvider
            let effective = inferenceStore.effectiveImageGenerationProvider
            if selected == .automatic {
                return "Generator: Automatic → \(effective.displayName)"
            }
            return "Generator: \(effective.displayName)"
        }

        private func startIconLabGeneration() {
            guard !isIconLabGenerateDisabled else { return }

            isGeneratingIconLabImages = true
            iconLabErrorMessage = nil
            iconLabResult = nil
            iconLabDescription = nil

            let prompt = iconLabPrompt
            let provider = inferenceStore.effectiveImageGenerationProvider
            let format = iconLabFormat
            let quality = iconLabQuality
            let masterPixelSize = iconLabMasterPixelSize
            let targetMasterByteCount = parsedIconLabTargetMasterByteCount
            Task {
                do {
                    let debugRootURL = IronsmithPaths.rootDirectory
                        .appendingPathComponent(".debug", isDirectory: true)
                        .appendingPathComponent("icon-format-lab", isDirectory: true)
                    let promptRequest = ToolIconRequest(
                        displayName: "Debug Icon",
                        iconPrompt: prompt,
                        layout: ToolPackageLayout(
                            packageRootURL: debugRootURL,
                            executableName: "DebugIcon"
                        ),
                        imageProvider: provider
                    )
                    let generatedImage = try await ToolImageGenerationClient.live(
                        imagePlayground: imagePlaygroundCoordinator
                    ).generate(
                        provider,
                        ToolIconClient.iconPrompt(for: promptRequest)
                    )
                    try exportIconLabImage(
                        generatedImage,
                        providerName: provider.displayName,
                        format: format,
                        quality: quality,
                        masterPixelSize: masterPixelSize,
                        targetMasterByteCount: targetMasterByteCount,
                        debugRootURL: debugRootURL
                    )
                } catch {
                    iconLabMasterPreview = nil
                    iconLabThumbnailPreview = nil
                    iconLabErrorMessage = AgentDiagnosticsLog.renderError(error, limit: 300)
                }
                isGeneratingIconLabImages = false
            }
        }

        private func importIconLabPNG(at sourceURL: URL) {
            iconLabErrorMessage = nil
            let didAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let data = try Data(contentsOf: sourceURL)
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                    CGImageSourceGetType(source) as String? == "public.png",
                    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
                else {
                    throw DebugIconExportError.couldNotEncode(.png)
                }
                importedIconLabPNG = image
                importedIconLabPNGName = sourceURL.lastPathComponent
            } catch {
                importedIconLabPNG = nil
                importedIconLabPNGName = nil
                iconLabErrorMessage = AgentDiagnosticsLog.renderError(error, limit: 300)
            }
        }

        private func exportImportedIconLabPNG() {
            guard let importedIconLabPNG, !isIconLabExportDisabled else { return }
            isGeneratingIconLabImages = true
            iconLabErrorMessage = nil
            iconLabResult = nil
            iconLabDescription = nil

            do {
                try exportIconLabImage(
                    importedIconLabPNG,
                    providerName: "Imported PNG",
                    format: iconLabFormat,
                    quality: iconLabQuality,
                    masterPixelSize: iconLabMasterPixelSize,
                    targetMasterByteCount: parsedIconLabTargetMasterByteCount,
                    debugRootURL: IronsmithPaths.rootDirectory
                        .appendingPathComponent(".debug", isDirectory: true)
                        .appendingPathComponent("icon-format-lab", isDirectory: true)
                )
            } catch {
                iconLabMasterPreview = nil
                iconLabThumbnailPreview = nil
                iconLabErrorMessage = AgentDiagnosticsLog.renderError(error, limit: 300)
            }
            isGeneratingIconLabImages = false
        }

        private func exportIconLabImage(
            _ image: CGImage,
            providerName: String,
            format: DebugIconImageFormat,
            quality: Double,
            masterPixelSize: Int,
            targetMasterByteCount: Int?,
            debugRootURL: URL
        ) throws {
            let result = try DebugIconExportClient.export(
                DebugIconExportRequest(
                    image: image,
                    format: format,
                    quality: quality,
                    masterPixelSize: masterPixelSize,
                    thumbnailPixelSize: 256,
                    targetMasterByteCount: targetMasterByteCount,
                    outputRootURL: debugRootURL,
                    providerName: providerName
                )
            )
            iconLabResult = result
            iconLabMasterPreview = NSImage(data: result.masterData)
            iconLabThumbnailPreview = NSImage(data: result.thumbnailData)
            iconLabDescription = iconLabResultDescription(result)
        }

        private var parsedIconLabTargetMasterByteCount: Int? {
            guard iconLabFormat.supportsLossyQuality else { return nil }
            let trimmed = iconLabTargetMasterKilobytes
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let kilobytes = Double(trimmed), kilobytes > 0 else { return nil }
            return Int(kilobytes * 1_024)
        }

        @ViewBuilder
        private func iconLabPreview(title: String, image: NSImage, size: CGFloat) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.quaternary, lineWidth: 1)
                    }
            }
        }

        private func iconLabResultDescription(_ result: DebugIconExportResult) -> String {
            let masterSize = ByteCountFormatter.string(
                fromByteCount: Int64(result.masterData.count),
                countStyle: .file
            )
            let thumbnailSize = ByteCountFormatter.string(
                fromByteCount: Int64(result.thumbnailData.count),
                countStyle: .file
            )
            var components = [
                "Master \(masterSize)",
                "Thumbnail \(thumbnailSize)",
            ]
            if let quality = result.effectiveMasterQuality {
                components.append(
                    "Master quality "
                        + quality.formatted(.number.precision(.fractionLength(2)))
                )
            }
            if result.targetMasterByteCount != nil, !result.metTargetMasterSize {
                components.append("Target not reached")
            }
            return components.joined(separator: " • ")
        }

        private func downscaleAttachmentImage(at sourceURL: URL) {
            imageDownscalerErrorMessage = nil
            downscaledImagePreview = nil
            downscaledImageOutputURL = nil
            downscaledImageDescription = nil

            do {
                let attachment = try ToolPromptAttachmentLoader.load(
                    urls: [sourceURL],
                    existing: []
                ).first
                guard let attachment, attachment.isImage,
                    let image = NSImage(data: attachment.data)
                else {
                    throw ToolPromptAttachmentError.imageCouldNotBeNormalized(
                        sourceURL.lastPathComponent
                    )
                }

                let debugDirectory = IronsmithPaths.rootDirectory
                    .appendingPathComponent(".debug", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: debugDirectory,
                    withIntermediateDirectories: true
                )
                let outputURL = debugDirectory.appendingPathComponent(
                    "normalized-\(attachment.fileName)",
                    isDirectory: false
                )
                try attachment.data.write(to: outputURL, options: .atomic)

                downscaledImagePreview = image
                downscaledImageOutputURL = outputURL
                downscaledImageDescription = normalizedImageDescription(
                    data: attachment.data,
                    outputURL: outputURL
                )
            } catch {
                imageDownscalerErrorMessage = AgentDiagnosticsLog.renderError(error, limit: 300)
            }
        }

        private func normalizedImageDescription(data: Data, outputURL: URL) -> String {
            let byteCount = ByteCountFormatter.string(
                fromByteCount: Int64(data.count),
                countStyle: .file
            )
            let dimensions: String
            if let bitmap = NSBitmapImageRep(data: data) {
                dimensions = "\(bitmap.pixelsWide)×\(bitmap.pixelsHigh)"
            } else {
                dimensions = "Unknown dimensions"
            }
            return "\(dimensions) • \(byteCount) • \(outputURL.lastPathComponent)"
        }
    }

    private enum SettingsDebugImageImporterPurpose {
        case iconPNG
        case attachment

        var allowedContentTypes: [UTType] {
            switch self {
            case .iconPNG:
                [.png]
            case .attachment:
                [.image]
            }
        }
    }
#endif
