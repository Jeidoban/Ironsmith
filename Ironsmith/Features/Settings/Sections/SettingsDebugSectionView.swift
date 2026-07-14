#if DEBUG
    import AppKit
    import ImagePlayground
    import SwiftUI

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
        @State private var imagePlaygroundPrompt = ""
        @State private var imagePlaygroundPreview: NSImage?
        @State private var imagePlaygroundErrorMessage: String?
        @State private var isGeneratingImagePlaygroundPreview = false
        @State private var imagePlaygroundCoordinator = ImagePlaygroundSheetCoordinator()

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
    }
#endif
