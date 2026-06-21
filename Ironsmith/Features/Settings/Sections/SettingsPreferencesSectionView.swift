import SwiftUI

struct SettingsPreferencesSectionView: View {
    @Environment(InferenceStore.self) private var inferenceStore
    @AppStorage(IronsmithPreferenceKeys.showSandboxOverride) private var showSandboxOverride = false
    @AppStorage(IronsmithPreferenceKeys.diagnosticsLoggingEnabled) private var diagnosticsLoggingEnabled = false
    @State private var isConfirmingUnsandboxedTools = false

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Toggle(
                    "Enhance app prompts",
                    isOn: binding(\.generatedPromptRefinementEnabled)
                )
                .toggleStyle(.switch)

                Text("Disabling can sometimes improve success rates of smaller AI models.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Allow unsandboxed apps", isOn: sandboxOverrideBinding)
                .toggleStyle(.switch)
                .alert(
                    "Allow Unsandboxed Apps?",
                    isPresented: $isConfirmingUnsandboxedTools
                ) {
                    Button("Cancel", role: .cancel) {}
                    Button("Allow", role: .destructive) {
                        showSandboxOverride = true
                    }
                } message: {
                    Text(
                        "Generated apps without the sandbox can access more of your "
                            + "Mac and can read, write, or change files and system resources. "
                            + "You should always read the source code of any unsandboxed app before using it."
                    )
                }

            VStack(alignment: .leading, spacing: 4) {
                Toggle(
                    "Write generation diagnostics log",
                    isOn: $diagnosticsLoggingEnabled
                )
                .toggleStyle(.switch)

                Text(
                    "Records detailed generation logs to a file on disk so you can share "
                        + "them when reporting a problem. Off by default."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } header: {
            Text("Preferences")
        }

        Section {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("General access")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    GeneratedAppResourceAccessPreferencesGrid(
                        preferences: inferenceStore.generationPreferences
                    )
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Sandbox-specific access")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    GeneratedAppSandboxAccessPreferencesGrid(
                        preferences: inferenceStore.generationPreferences
                    )
                }
            }
        } header: {
            Text("Generated app permissions")
        }
    }

    private var sandboxOverrideBinding: Binding<Bool> {
        Binding(
            get: { showSandboxOverride },
            set: { isEnabled in
                if isEnabled {
                    isConfirmingUnsandboxedTools = true
                } else {
                    showSandboxOverride = false
                }
            }
        )
    }

    private func binding<Value>(
        _ keyPath: ReferenceWritableKeyPath<GenerationPreferencesStore, Value>
    ) -> Binding<Value> {
        Binding(
            get: { inferenceStore.generationPreferences[keyPath: keyPath] },
            set: { newValue in
                inferenceStore.generationPreferences[keyPath: keyPath] = newValue
            }
        )
    }
}

private struct GeneratedAppSandboxAccessPreferencesGrid: View {
    let preferences: GenerationPreferencesStore

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
            GridRow {
                ForEach(GeneratedAppSandboxPermission.allCases) { permission in
                    Toggle(permission.displayName, isOn: binding(for: permission))
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .frame(width: 150, alignment: .leading)
                }
            }
        }
    }

    private func binding(for permission: GeneratedAppSandboxPermission) -> Binding<Bool> {
        Binding(
            get: { preferences.isGeneratedAppSandboxPermissionEnabled(permission) },
            set: { preferences.setGeneratedAppSandboxPermission(permission, enabled: $0) }
        )
    }
}

private struct GeneratedAppResourceAccessPreferencesGrid: View {
    let preferences: GenerationPreferencesStore
    @State private var pendingPermission: GeneratedAppResourcePermission?

    private static let rows: [(GeneratedAppResourcePermission, GeneratedAppResourcePermission?)] = [
        (.microphone, .camera),
        (.location, .contacts),
        (.calendar, .photoLibrary),
        (.appleEvents, nil),
    ]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
            ForEach(Self.rows, id: \.0) { leftPermission, rightPermission in
                GridRow {
                    permissionToggle(leftPermission)
                    if let rightPermission {
                        permissionToggle(rightPermission)
                    } else {
                        Color.clear
                            .frame(width: 120, height: 1)
                    }
                }
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
                    preferences.setGeneratedAppResourcePermission(pendingPermission, enabled: true)
                }
                pendingPermission = nil
            }
        } message: {
            Text(pendingPermission?.enablementWarningMessage ?? "")
        }
    }

    private func permissionToggle(_ permission: GeneratedAppResourcePermission) -> some View {
        Toggle(
            permission.displayName,
            isOn: binding(for: permission)
        )
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .frame(width: 120, alignment: .leading)
    }

    private func binding(for permission: GeneratedAppResourcePermission) -> Binding<Bool> {
        Binding(
            get: { preferences.isGeneratedAppResourcePermissionEnabled(permission) },
            set: { isEnabled in
                if isEnabled,
                    permission.enablementWarningMessage != nil
                {
                    pendingPermission = permission
                } else {
                    preferences.setGeneratedAppResourcePermission(permission, enabled: isEnabled)
                }
            }
        )
    }
}

@MainActor
private struct SettingsPreferencesPreview: View {
    @State private var inferenceStore = SettingsPreviewState.make(selectedModel: .appleFoundation)

    var body: some View {
        Form {
            SettingsPreferencesSectionView()
        }
        .formStyle(.grouped)
        .environment(inferenceStore)
        .padding(20)
        .frame(width: 620, height: 270)
    }
}

#Preview("Preferences Section") {
    SettingsPreferencesPreview()
}
