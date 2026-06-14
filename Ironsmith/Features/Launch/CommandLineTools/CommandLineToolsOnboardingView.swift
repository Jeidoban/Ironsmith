//
//  CommandLineToolsOnboardingView.swift
//  Ironsmith
//

import AppKit
import SwiftUI

struct CommandLineToolsOnboardingView: View {
    let isChecking: Bool
    let notFoundMessageID: Int
    let onRetry: () -> Void
    @State private var didCopyInstallCommand = false
    @State private var isShowingNotFoundMessage = false
    @State private var notFoundMessageTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                Label("Install Xcode Command Line Tools", systemImage: "terminal")
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)

                Spacer()

                quitButton
            }

            Text("Ironsmith needs the Xcode Command Line Tools to build apps. macOS should show an install popup now. Click “Install” or run the command below, then return here when it finishes. The tools are a 500MB download.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            commandRow

            HStack {
                Button("Check for installation", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .disabled(isChecking)

                if isShowingNotFoundMessage {
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
            .accessibilityLabel(didCopyInstallCommand ? "Install command copied" : "Copy install command")
            .accessibilityHint("Copies the Xcode Command Line Tools install command.")
            .accessibilityIdentifier("copy-command-line-tools-command-button")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func copyInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(CommandLineToolsClient.manualInstallCommand, forType: .string)
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

#Preview("CLT Onboarding") {
    CommandLineToolsOnboardingView(
        isChecking: false,
        notFoundMessageID: 0,
        onRetry: {}
    )
}
