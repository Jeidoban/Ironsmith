import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ToolIconEditorSheetView: View {
    let appName: String
    let previewData: Data?
    @Binding var prompt: String
    let imageProvider: ToolImageGenerationProvider
    let hasCandidate: Bool
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

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Change App Icon")
                    .font(.title2.weight(.semibold))
                Text("Choose your own artwork or generate a new icon for \(appName).")
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 20) {
                iconPreview

                VStack(alignment: .leading, spacing: 12) {
                    Text("Choose a 1024×1024 image")
                        .font(.headline)
                    Text("Drag an image here, or choose any format supported by macOS.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Button("Choose Image…") {
                        isChoosingImage = true
                    }
                    .disabled(isWorking)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .background(
                isDropTargeted ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 16)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.18),
                        style: StrokeStyle(
                            lineWidth: isDropTargeted ? 2 : 1,
                            dash: isDropTargeted ? [7, 5] : []
                        )
                    )
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                onChooseImage(url)
                return true
            } isTargeted: {
                isDropTargeted = $0
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Visual Concept")
                    .font(.headline)
                TextField(
                    "Describe the symbol, colors, or background you want",
                    text: $prompt,
                    axis: .vertical
                )
                .lineLimit(3...6)

                HStack {
                    if imageProvider == .disabled {
                        Label(
                            "Enable an app icon generator in Settings.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)

                        Spacer()

                        Button("Open Settings", action: onOpenSettings)
                    } else {
                        Text("Using \(providerName)")
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button(action: onGenerate) {
                            if isGenerating {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Generate New Icon")
                            }
                        }
                        .disabled(!canGenerate)
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
                .disabled(!hasCandidate || isWorking)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540)
        .fileImporter(
            isPresented: $isChoosingImage,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            onChooseImage(url)
        }
    }

    @ViewBuilder
    private var iconPreview: some View {
        if let previewData, let image = NSImage(data: previewData) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 132, height: 132)
                .clipShape(RoundedRectangle(cornerRadius: 28))
                .overlay {
                    RoundedRectangle(cornerRadius: 28)
                        .strokeBorder(.quaternary, lineWidth: 1)
                }
                .accessibilityLabel("App icon preview")
        } else {
            RoundedRectangle(cornerRadius: 28)
                .fill(.quaternary.opacity(0.35))
                .frame(width: 132, height: 132)
                .overlay {
                    Image(systemName: "photo")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("No app icon preview")
        }
    }

    private var isWorking: Bool {
        isGenerating || isSaving
    }

    private var canGenerate: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isWorking
            && imageProvider != .disabled
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
