import AppKit
import SwiftUI

struct ToolLibraryPopoverHeaderView: View {
    @Environment(\.openURL) private var openURL

    let appUpdateStore: AppUpdateStore
    let isLoadingModels: Bool
    let selectedModelStatusText: String?
    let selectedIronsmithCreditWarningText: String?
    let onOpenStore: () -> Void
    let onOpenSettings: () -> Void
    private static let issueReportURL = URL(
        string: "https://github.com/Jeidoban/Ironsmith/issues/new")!

    var body: some View {
        HStack {
            leadingContent
                .layoutPriority(1)

            Spacer()

            if appUpdateStore.shouldShowUpdateButton {
                Button("Update") {
                    appUpdateStore.openAvailableUpdate()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Open latest release")
                .accessibilityIdentifier("app-update-button")
            }

            Button(action: onOpenStore) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("App Store")
            .accessibilityLabel("App Store")
            .accessibilityIdentifier("app-store-button")

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings")
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("settings-button")

            Menu {
                Button("Browse App Store...") {
                    onOpenStore()
                }

                Divider()

                Button("About Ironsmith") {
                    IronsmithAboutWindowController.shared.show()
                }

                Button("Report an Issue") {
                    openURL(Self.issueReportURL)
                }

                Divider()

                Button("Quit Ironsmith") {
                    NSApp.terminate(nil)
                }
            } label: {
                Image(systemName: "line.3.horizontal.circle")
                    .font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Ironsmith")
            .accessibilityLabel("Ironsmith menu")
            .accessibilityHint("Opens about, issue reporting, and quit actions.")
            .accessibilityIdentifier("ironsmith-menu-button")
        }
    }

    @ViewBuilder
    private var leadingContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Ironsmith")
                .font(.headline.weight(.semibold))
                .lineLimit(1)

            if shouldShowModelStatus {
                modelStatus
                    .frame(height: 18, alignment: .topLeading)
            }

            if let selectedIronsmithCreditWarningText {
                Text(selectedIronsmithCreditWarningText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var modelStatus: some View {
        if isLoadingModels {
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .accessibilityLabel("Loading AI model")

                Text("Loading AI model…")
                    .lineLimit(1)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        } else if let selectedModelStatusText {
            Text(selectedModelStatusText)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var shouldShowModelStatus: Bool {
        isLoadingModels || selectedModelStatusText != nil
    }
}
