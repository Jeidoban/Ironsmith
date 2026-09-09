//
//  CommandLineToolsOnboardingView.swift
//  Ironsmith
//

import AppKit
import SwiftUI

struct CommandLineToolsOnboardingView: View {
    let availability: CommandLineToolsAvailability
    let isChecking: Bool
    let notFoundMessageID: Int
    let onRetry: () -> Void
    @State private var didCopyInstallCommand = false
    @State private var isShowingNotFoundMessage = false
    @State private var notFoundMessageTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                Label(title, systemImage: symbolName)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)

                Spacer()

                quitButton
            }

            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if case .unavailable = availability {
                commandRow
            }

            if case .unsupported(let selection) = availability {
                Text(
                    "Selected: Swift \(selection.swiftVersion.displayName), macOS SDK \(selection.sdkVersion.displayName)"
                )
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }

            HStack {
                Button(retryButtonTitle, action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .disabled(isChecking)

                if isChecking {
                    ProgressView()
                        .controlSize(.small)
                } else if isShowingNotFoundMessage {
                    Text("Not found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }

                Spacer()
            }
        }
        .padding(24)
        .frame(width: 460, alignment: .topLeading)
        .accessibilityIdentifier("clt-onboarding-root")
        .onChange(of: notFoundMessageID) { _, newValue in
            showNotFoundMessage(for: newValue)
        }
        .onDisappear {
            notFoundMessageTask?.cancel()
        }
    }

    private var title: String {
        switch availability {
        case .unsupported:
            "Update Developer Tools"
        case .available, .unavailable:
            "Install Xcode Command Line Tools"
        }
    }

    private var symbolName: String {
        switch availability {
        case .unsupported:
            "arrow.triangle.2.circlepath"
        case .available, .unavailable:
            "terminal"
        }
    }

    private var message: String {
        switch availability {
        case .available:
            "The selected developer tools are ready."
        case .unavailable:
            "Ironsmith needs Apple’s developer tools to build apps. macOS should show an installation dialog now. Complete the installation, then return here and check again."
        case .unsupported(let selection):
            if selection.usesXcode {
                "Ironsmith requires Swift \(GeneratedToolRequirements.swiftVersion) or newer and the macOS \(GeneratedToolRequirements.sdkMajorVersion) SDK or newer. Update the selected version of Xcode, then check again."
            } else {
                "Ironsmith requires Swift \(GeneratedToolRequirements.swiftVersion) or newer and the macOS \(GeneratedToolRequirements.sdkMajorVersion) SDK or newer. Update the Command Line Tools in System Settings › General › Software Update, then check again."
            }
        }
    }

    private var retryButtonTitle: String {
        switch availability {
        case .unsupported:
            "Check again"
        case .available, .unavailable:
            "Check for installation"
        }
    }

    private var quitButton: some View {
        Button {
            NSApp.terminate(nil)
        } label: {
            Image(systemName: "rectangle.portrait.and.arrow.right")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .frame(width: 30, height: 30)
        .contentShape(Rectangle())
        .help("Quit Ironsmith")
        .accessibilityLabel("Quit Ironsmith")
        .accessibilityIdentifier("quit-ironsmith-button")
    }

    private var commandRow: some View {
        HStack(spacing: 8) {
            Text(CommandLineToolsClient.manualInstallCommand)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                copyInstallCommand()
            } label: {
                Image(systemName: didCopyInstallCommand ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(didCopyInstallCommand ? .green : .secondary)
            .contentShape(Rectangle())
            .help("Copy command")
            .accessibilityLabel(
                didCopyInstallCommand ? "Install command copied" : "Copy install command"
            )
            .accessibilityHint("Copies the Xcode Command Line Tools install command.")
            .accessibilityIdentifier("copy-command-line-tools-command-button")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func copyInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            CommandLineToolsClient.manualInstallCommand,
            forType: .string
        )
        didCopyInstallCommand = true

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            didCopyInstallCommand = false
        }
    }

    private func showNotFoundMessage(for messageID: Int) {
        guard messageID > 0 else { return }

        notFoundMessageTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) {
            isShowingNotFoundMessage = true
        }

        notFoundMessageTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }

            withAnimation(.easeOut(duration: 0.2)) {
                isShowingNotFoundMessage = false
            }
        }
    }
}

#Preview("CLT Installation") {
    CommandLineToolsOnboardingView(
        availability: .unavailable,
        isChecking: false,
        notFoundMessageID: 0,
        onRetry: {}
    )
}

#Preview("CLT Update") {
    CommandLineToolsOnboardingView(
        availability: .unsupported(
            CommandLineToolsSelection(
                developerDirectory: "/Library/Developer/CommandLineTools",
                swiftVersion: .init(major: 6, minor: 1),
                sdkVersion: .init(major: 25, minor: 4)
            )
        ),
        isChecking: false,
        notFoundMessageID: 0,
        onRetry: {}
    )
}
