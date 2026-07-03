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
    @Binding var agentPipelineProfile: AgentPipelineProfilePreference
    let placeholder: String
    let showsSandboxControl: Bool
    let modelPickerTitle: String
    let isModelPickerEnabled: Bool
    let isSubmitEnabled: Bool
    let isSubmitting: Bool
    let isPromptFocused: FocusState<Bool>.Binding
    let onChooseModel: () -> Void
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
                .focused(isPromptFocused)
                .accessibilityIdentifier("tool-prompt-field")

            HStack {
                generationSettingsMenu

                Spacer(minLength: 6)

                modelPickerButton
                    .layoutPriority(1)

                Spacer(minLength: 6)

                submitButton
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

            Picker("Coding Agent", selection: $agentPipelineProfile) {
                Text(AgentPipelineProfilePreference.automatic.displayName)
                    .tag(AgentPipelineProfilePreference.automatic)
                Text(AgentPipelineProfilePreference.largeModel.displayName)
                    .tag(AgentPipelineProfilePreference.largeModel)
                Text(AgentPipelineProfilePreference.smallModel.displayName)
                    .tag(AgentPipelineProfilePreference.smallModel)
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

    private var modelPickerButton: some View {
        Button(action: onChooseModel) {
            HStack(spacing: 5) {
                Text(modelPickerTitle)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.86)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .frame(maxWidth: 184)
            .background(.quaternary.opacity(0.36), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .opacity(isModelPickerEnabled && !isSubmitting ? 1 : 0.55)
        .disabled(!isModelPickerEnabled || isSubmitting)
        .help("Choose AI model")
        .accessibilityLabel("Choose AI model")
        .accessibilityValue(modelPickerTitle)
        .accessibilityIdentifier("model-picker-button")
    }

    private var submitButton: some View {
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
    PromptComposerPreview(isEditing: false)
}

#Preview("Edit Prompt") {
    PromptComposerPreview(isEditing: true)
}

private struct PromptComposerPreview: View {
    let isEditing: Bool
    @FocusState private var isPromptFocused: Bool

    var body: some View {
        PromptComposerView(
            prompt: .constant(""),
            sandboxEnabled: .constant(!isEditing),
            appKind: .constant(isEditing ? .menuBar : .window),
            sandboxPermissions: .constant(.default),
            resourcePermissions: .constant(
                isEditing ? GeneratedAppResourcePermissions([.camera]) : .none
            ),
            agentPipelineProfile: .constant(.automatic),
            placeholder: isEditing
                ? "Describe changes for Clipboard Cleaner…"
                : "Describe a new app to build…",
            showsSandboxControl: isEditing,
            modelPickerTitle: "DeepSeek V4 Flash",
            isModelPickerEnabled: true,
            isSubmitEnabled: isEditing,
            isSubmitting: false,
            isPromptFocused: $isPromptFocused,
            onChooseModel: {},
            onSubmit: {},
            onCancel: {}
        )
        .padding()
        .frame(width: 360)
    }
}
