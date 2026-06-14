import SwiftUI

struct OllamaInstallRowView: View {
    @Environment(InferenceStore.self) private var inferenceStore
    @Environment(\.openURL) private var openURL
    @State private var isPollingAfterDownload = false

    private static let downloadURL = URL(string: "https://ollama.com/download")!

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                statusLabel
                Spacer()
                if displayedInstallationStatus == .notInstalled {
                    Button("Download Ollama") {
                        isPollingAfterDownload = true
                        openURL(Self.downloadURL)
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .task {
            inferenceStore.refreshOllamaInstallationStatus()
        }
        .task(id: isPollingAfterDownload) {
            await pollForInstallationAfterDownload()
        }
    }

    private func pollForInstallationAfterDownload() async {
        guard isPollingAfterDownload else { return }

        while !Task.isCancelled {
            guard inferenceStore.ollamaInstallationStatus != .installed else {
                isPollingAfterDownload = false
                return
            }

            inferenceStore.refreshOllamaInstallationStatus()

            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if displayedInstallationStatus == .unknown
            || displayedInstallationStatus == .checking
        {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Checking Ollama installation")
                Text(statusText)
            }
            .foregroundStyle(statusColor)
        } else {
            Label(statusText, systemImage: statusIcon)
                .foregroundStyle(statusColor)
        }
    }

    private var displayedInstallationStatus: OllamaInstallationStatus {
        if isPollingAfterDownload && inferenceStore.ollamaInstallationStatus != .installed {
            return .checking
        }

        return inferenceStore.ollamaInstallationStatus
    }

    private var statusText: String {
        switch displayedInstallationStatus {
        case .unknown, .checking:
            return "Checking"
        case .installed:
            return "Installed"
        case .notInstalled:
            return "Not Installed"
        }
    }

    private var statusIcon: String {
        switch displayedInstallationStatus {
        case .installed:
            return "checkmark.circle.fill"
        case .notInstalled:
            return "arrow.down.circle"
        default:
            return "circle.dashed"
        }
    }

    private var statusColor: AnyShapeStyle {
        switch displayedInstallationStatus {
        case .installed:
            return AnyShapeStyle(.green)
        default:
            return AnyShapeStyle(.secondary)
        }
    }
}
