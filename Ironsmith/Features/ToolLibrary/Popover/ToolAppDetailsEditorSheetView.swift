import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ToolAppDetailsEditorSheetView: View {
    let previewData: Data?
    @Binding var name: String
    @Binding var prompt: String
    let imageProvider: ToolImageGenerationProvider
    let canSave: Bool
    let isGenerating: Bool
    let isSaving: Bool
    let errorMessage: String?
    let onChooseImage: (URL) -> Void
    let onGenerate: () -> Void
    let onOpenSettings: () -> Void
    let onCancel: () -> Void
    let onSave: () -> Void

    @State private var isChoosingImage = false
    @State private var isDropTargeted = false
    @State private var isShowingGenerationPrompt = false
    @State private var shouldGenerateAfterPromptDismiss = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit App Details")
                .font(.headline)

            field("App Name") {
                TextField("App Name", text: $name)
            }

            field("App Icon") {
                HStack(spacing: 12) {
                    iconPreview
                    VStack(alignment: .leading, spacing: 5) {
                        Text("1024×1024 image")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("Choose an image or drag one here.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                    VStack(alignment: .trailing, spacing: 8) {
                        Button("Choose Image…") {
                            isChoosingImage = true
                        }
                        .disabled(isWorking)

                        Button {
                            isShowingGenerationPrompt = true
                        } label: {
                            Text(isGenerating ? "Generating…" : "Generate Image…")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isWorking || imageProvider == .disabled)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                .padding(8)
                .background(
                    isDropTargeted
                        ? Color.accentColor.opacity(0.12)
                        : Color.primary.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.15),
                            lineWidth: isDropTargeted ? 1.5 : 1
                        )
                }
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first else { return false }
                    onChooseImage(url)
                    return true
                } isTargeted: {
                    isDropTargeted = $0
                }

                if imageProvider == .disabled {
                    HStack {
                        Label(
                            "Enable an app icon generator in Settings.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)

                        Spacer()

                        Button("Open Settings", action: onOpenSettings)
                    }
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .disabled(isWorking)
                Button(action: onSave) {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Save")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave || isWorking)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 390)
        .fileImporter(
            isPresented: $isChoosingImage,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            onChooseImage(url)
        }
        .sheet(
            isPresented: $isShowingGenerationPrompt,
            onDismiss: {
                guard shouldGenerateAfterPromptDismiss else { return }
                shouldGenerateAfterPromptDismiss = false
                onGenerate()
            }
        ) {
            ToolIconGenerationPromptSheetView(
                prompt: $prompt,
                providerName: providerName,
                onCancel: {
                    shouldGenerateAfterPromptDismiss = false
                    isShowingGenerationPrompt = false
                },
                onGenerate: {
                    shouldGenerateAfterPromptDismiss = true
                    isShowingGenerationPrompt = false
                }
            )
        }
    }

    private func field<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline.weight(.medium))
            content()
        }
    }

    @ViewBuilder
    private var iconPreview: some View {
        if let previewData, let image = NSImage(data: previewData) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 11))
                .overlay {
                    RoundedRectangle(cornerRadius: 11)
                        .strokeBorder(.quaternary, lineWidth: 1)
                }
                .accessibilityLabel("App icon preview")
        } else {
            RoundedRectangle(cornerRadius: 11)
                .fill(.quaternary.opacity(0.35))
                .frame(width: 52, height: 52)
                .overlay {
                    Image(systemName: "photo")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("No app icon preview")
        }
    }

    private var isWorking: Bool {
        isGenerating || isSaving
    }

    private var providerName: String {
        switch imageProvider {
        case .automatic:
            "Automatic"
        case .imagePlayground:
            "Image Playground"
        case .gemini:
            "Gemini"
        case .openAI:
            "OpenAI"
        case .ironsmith:
            "Ironsmith"
        case .disabled:
            "Off"
        }
    }
}

private struct ToolIconGenerationPromptSheetView: View {
    @Binding var prompt: String
    let providerName: String
    let onCancel: () -> Void
    let onGenerate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Icon Description")
                    .font(.subheadline.weight(.medium))
                TextField(
                    "Describe what the app icon should be",
                    text: $prompt,
                    axis: .vertical
                )
                .lineLimit(3...5)
            }

            Text("Using \(providerName) image generation")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Generate", action: onGenerate)
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 340)
    }
}
