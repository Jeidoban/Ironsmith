//
//  PromptComposerView.swift
//  Ironsmith
//

import SwiftUI

struct PromptComposerView: View {
    @Binding var prompt: String
    @Binding var sandboxEnabled: Bool
    let placeholder: String
    let showsSandboxToggle: Bool
    let isSubmitEnabled: Bool
    let isSubmitting: Bool
    let onSubmit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            TextField(placeholder, text: $prompt, axis: .vertical)
                .submitLabel(.send)
                .onSubmit {
                    guard isSubmitEnabled else { return }
                    onSubmit()
                }
                .textFieldStyle(.plain)
                .lineLimit(3...6)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 18))
                .accessibilityIdentifier("tool-prompt-field")

            HStack {
                if showsSandboxToggle {
                    Toggle(isOn: $sandboxEnabled) {
                        HStack(spacing: 4) {
                            Image(systemName: sandboxEnabled ? "lock.fill" : "lock.open.fill")
                                .frame(width: 14, alignment: .center)
                                .accessibilityHidden(true)
                            Text(sandboxLabel)
                        }
                    }
                    .toggleStyle(.switch)
                    .font(.caption)
                    .disabled(isSubmitting)
                    .help(sandboxHelpText)
                }

                Spacer()

                Button {
                    if isSubmitting {
                        onCancel()
                    } else {
                        onSubmit()
                    }
                } label: {
                    if isSubmitting {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 24))
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 24))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(submitButtonForegroundStyle)
                .disabled(!isSubmitEnabled && !isSubmitting)
                .help(isSubmitting ? "Stop generation" : "Generate")
                .accessibilityLabel(isSubmitting ? "Stop generation" : "Generate app")
                .accessibilityHint(
                    isSubmitting
                        ? "Cancels the current app generation."
                        : "Starts generating an app from the prompt."
                )
                .accessibilityIdentifier(isSubmitting ? "stop-generation-button" : "submit-generation-button")
            }
        }
    }

    private var submitButtonForegroundStyle: some ShapeStyle {
        if isSubmitting {
            return AnyShapeStyle(.red)
        }

        if isSubmitEnabled {
            return AnyShapeStyle(.tint)
        }

        return AnyShapeStyle(.secondary)
    }

    private var sandboxLabel: String {
        sandboxEnabled ? "Sandbox On" : "Sandbox Off"
    }

    private var sandboxHelpText: String {
        sandboxEnabled
            ? "Generated apps will include App Sandbox entitlements."
            : "Generated apps will be built without App Sandbox entitlements."
    }
}

#Preview("Create Prompt") {
    PromptComposerView(
        prompt: .constant(""),
        sandboxEnabled: .constant(true),
        placeholder: "Describe a new app to build…",
        showsSandboxToggle: false,
        isSubmitEnabled: false,
        isSubmitting: false,
        onSubmit: {},
        onCancel: {}
    )
    .padding()
    .frame(width: 360)
}

#Preview("Edit Prompt") {
    PromptComposerView(
        prompt: .constant(""),
        sandboxEnabled: .constant(false),
        placeholder: "Describe changes for Clipboard Cleaner…",
        showsSandboxToggle: true,
        isSubmitEnabled: true,
        isSubmitting: false,
        onSubmit: {},
        onCancel: {}
    )
    .padding()
    .frame(width: 360)
}
