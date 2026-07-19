#if DEBUG
    import AppKit
    import ImagePlayground
    import SwiftUI
    import UniformTypeIdentifiers

    struct SettingsDebugSectionView: View {
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
        @State private var imagePlaygroundPrompt = ""
        @State private var imagePlaygroundPreview: NSImage?
        @State private var imagePlaygroundErrorMessage: String?
        @State private var isGeneratingImagePlaygroundPreview = false
        @State private var imagePlaygroundCoordinator = ImagePlaygroundSheetCoordinator()
        @State private var isShowingImageDownscalerImporter = false
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

                    Toggle("App Store", isOn: $storeFeatureEnabled)
                        .toggleStyle(.switch)

                    Toggle(
                        "Spark diagnostic whole-file recovery",
                        isOn: $diagnosticWholeFileRewriteEnabled
                    )
                    .toggleStyle(.switch)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Image Playground")
                        .font(.headline)

                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        TextField(
                            "Prompt",
                            text: $imagePlaygroundPrompt,
                            prompt: Text("A friendly forge icon")
                        )
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            startImagePlaygroundGeneration()
                        }

                        Button(isGeneratingImagePlaygroundPreview ? "Generating..." : "Generate") {
                            startImagePlaygroundGeneration()
                        }
                        .disabled(isImagePlaygroundGenerateDisabled)
                    }

                    if isGeneratingImagePlaygroundPreview {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Generating image")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }

                    if let imagePlaygroundErrorMessage {
                        Text(imagePlaygroundErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if let imagePlaygroundPreview {
                        Image(nsImage: imagePlaygroundPreview)
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
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Attachment Image Downscaler")
                        .font(.headline)

                    HStack(spacing: 10) {
                        Button("Choose Image…") {
                            isShowingImageDownscalerImporter = true
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
                isPresented: $isShowingImageDownscalerImporter,
                allowedContentTypes: [.image],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                downscaleAttachmentImage(at: url)
            }
        }

        private var isImagePlaygroundGenerateDisabled: Bool {
            isGeneratingImagePlaygroundPreview
                || imagePlaygroundPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        private func startImagePlaygroundGeneration() {
            guard !isImagePlaygroundGenerateDisabled else { return }

            isGeneratingImagePlaygroundPreview = true
            imagePlaygroundErrorMessage = nil

            let prompt = imagePlaygroundPrompt
            Task {
                do {
                    imagePlaygroundPreview = try await ToolIconClient.debugImagePlaygroundPreview(
                        prompt: prompt,
                        coordinator: imagePlaygroundCoordinator
                    )
                } catch {
                    imagePlaygroundPreview = nil
                    imagePlaygroundErrorMessage = AgentDiagnosticsLog.renderError(error, limit: 300)
                }
                isGeneratingImagePlaygroundPreview = false
            }
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
#endif
