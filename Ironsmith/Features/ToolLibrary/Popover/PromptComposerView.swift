//
//  PromptComposerView.swift
//  Ironsmith
//

import SwiftUI

struct PromptComposerView: View {
    @Binding var prompt: String
    @Binding var sandboxEnabled: Bool
    @Binding var appKind: ToolAppKind
    @Binding var sandboxPermissions: GeneratedAppSandboxPermissions
    @Binding var resourcePermissions: GeneratedAppResourcePermissions
    let placeholder: String
    let showsSandboxControl: Bool
    let isSubmitEnabled: Bool
    let isSubmitting: Bool
    let onSubmit: () -> Void
    let onCancel: () -> Void
    @State private var pendingPermission: GeneratedAppResourcePermission?

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
                generationSettingsMenu

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
        .alert(
            pendingPermission?.enablementWarningTitle ?? "Allow Access?",
            isPresented: Binding(
                get: { pendingPermission != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingPermission = nil
                    }
                }
            )
        ) {
            Button("Cancel", role: .cancel) {
                pendingPermission = nil
            }
            Button("Enable") {
                if let pendingPermission {
                    setResourcePermission(pendingPermission, enabled: true)
                }
                pendingPermission = nil
            }
        } message: {
            Text(pendingPermission?.enablementWarningMessage ?? "")
        }
    }

    private var generationSettingsMenu: some View {
        Menu {
            Picker("App Type", selection: $appKind) {
                ForEach(ToolAppKind.allCases, id: \.self) { kind in
                    Label(kind.displayName, systemImage: kind == .menuBar ? "menubar.rectangle" : "macwindow")
                        .tag(kind)
                }
            }

            if showsSandboxControl {
                Divider()
                Toggle("Sandbox Enabled", isOn: $sandboxEnabled)
                .help(sandboxHelpText)
            }

            Divider()

            Menu("Permissions") {
                Section("General Access") {
                    ForEach(GeneratedAppResourcePermission.allCases) { permission in
                        Toggle(permission.displayName, isOn: resourcePermissionBinding(for: permission))
                    }
                }

                Section("Sandbox Access") {
                    ForEach(GeneratedAppSandboxPermission.allCases) { permission in
                        Toggle(permission.displayName, isOn: sandboxPermissionBinding(for: permission))
                    }
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help("Generation settings")
        .accessibilityLabel("Generation settings")
        .accessibilityIdentifier("generation-settings-menu")
        .disabled(isSubmitting)
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

    private var sandboxHelpText: String {
        "Controls whether generated apps include App Sandbox entitlements."
    }

    private func resourcePermissionBinding(for permission: GeneratedAppResourcePermission) -> Binding<Bool> {
        Binding(
            get: { currentResourcePermissions.contains(permission) },
            set: { isEnabled in
                if isEnabled, permission.enablementWarningMessage != nil {
                    pendingPermission = permission
                } else {
                    setResourcePermission(permission, enabled: isEnabled)
                }
            }
        )
    }

    private func sandboxPermissionBinding(for permission: GeneratedAppSandboxPermission) -> Binding<Bool> {
        Binding(
            get: { currentSandboxPermissions.contains(permission) },
            set: { setSandboxPermission(permission, enabled: $0) }
        )
    }

    private var currentResourcePermissions: GeneratedAppResourcePermissions {
        resourcePermissions
    }

    private var currentSandboxPermissions: GeneratedAppSandboxPermissions {
        sandboxPermissions
    }

    private func setResourcePermission(_ permission: GeneratedAppResourcePermission, enabled: Bool) {
        var updated = resourcePermissions
        if enabled {
            updated.enabled.insert(permission)
        } else {
            updated.enabled.remove(permission)
        }
        resourcePermissions = updated
    }

    private func setSandboxPermission(_ permission: GeneratedAppSandboxPermission, enabled: Bool) {
        var updated = sandboxPermissions
        if enabled {
            updated.enabled.insert(permission)
        } else {
            updated.enabled.remove(permission)
        }
        sandboxPermissions = updated
    }
}

#Preview("Create Prompt") {
    PromptComposerView(
        prompt: .constant(""),
        sandboxEnabled: .constant(true),
        appKind: .constant(.window),
        sandboxPermissions: .constant(.default),
        resourcePermissions: .constant(.none),
        placeholder: "Describe a new app to build…",
        showsSandboxControl: false,
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
        appKind: .constant(.menuBar),
        sandboxPermissions: .constant(.default),
        resourcePermissions: .constant(GeneratedAppResourcePermissions([.camera])),
        placeholder: "Describe changes for Clipboard Cleaner…",
        showsSandboxControl: true,
        isSubmitEnabled: true,
        isSubmitting: false,
        onSubmit: {},
        onCancel: {}
    )
    .padding()
    .frame(width: 360)
}
