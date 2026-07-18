//
//  PromptComposerView.swift
//  Ironsmith
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PromptComposerView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var prompt: String
    @Binding var isExpanded: Bool
    @Binding var sandboxEnabled: Bool
    @Binding var appKind: ToolAppKind
    @Binding var sandboxPermissions: GeneratedAppSandboxPermissions
    @Binding var resourcePermissions: GeneratedAppResourcePermissions
    @Binding var codingAgentPreference: ToolCodingAgentPreference
    @Binding var reasoningEffort: ToolReasoningEffort
    let placeholder: String
    let showsSandboxControl: Bool
    let modelPickerTitle: String
    let isModelPickerEnabled: Bool
    let isSubmitEnabled: Bool
    let isSubmitting: Bool
    let isCodexAgentSupported: Bool
    let showsAttachmentControls: Bool
    let supportsAttachments: Bool
    let attachments: [ToolPromptAttachment]
    let supportedReasoningEfforts: Set<ToolReasoningEffort>
    let isPromptFocused: FocusState<Bool>.Binding
    let onChooseModel: () -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onAddAttachments: ([URL]) -> Void
    let onRemoveAttachment: (UUID) -> Void
    @State private var pendingPermission: GeneratedAppResourcePermission?
    @State private var isAttachmentDropTargeted = false
    @State private var isShowingFileImporter = false

    var body: some View {
        VStack(spacing: 12) {
            promptEditor
                .layoutPriority(isExpanded ? 1 : 0)

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
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            guard !isSubmitting else { return }
            guard case .success(let urls) = result else { return }
            onAddAttachments(urls)
        }
    }

    private var promptEditor: some View {
        VStack(spacing: 0) {
            promptTextEditor
                .frame(maxHeight: .infinity)

            promptAccessoryBar
        }
        .frame(
            height: isExpanded
                ? nil
                : PromptEditorLayout.compactTextEditorHeight
                    + PromptEditorLayout.accessoryBarHeight
        )
        .frame(maxHeight: isExpanded ? .infinity : nil)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            if isAttachmentDropTargeted {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.accentColor.opacity(0.85), lineWidth: 2)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            acceptDroppedFiles(urls)
        } isTargeted: { isTargeted in
            isAttachmentDropTargeted = isTargeted && acceptsAttachmentDrops
        }
        .animation(.easeInOut(duration: 0.12), value: isAttachmentDropTargeted)
    }

    private var promptTextEditor: some View {
        ZStack(alignment: .topLeading) {
            PromptTextEditor(
                text: $prompt,
                isFocused: isPromptFocused,
                isSubmitEnabled: isSubmitEnabled,
                onSubmit: onSubmit
            )
                .padding(.horizontal, PromptEditorLayout.textEditorHorizontalPadding)
                .padding(.top, PromptEditorLayout.textEditorTopPadding)
                .accessibilityIdentifier("tool-prompt-field")

            if prompt.isEmpty {
                Text(placeholder)
                    .font(.body)
                    .foregroundStyle(.placeholder)
                    .padding(.leading, PromptEditorLayout.placeholderLeadingPadding)
                    .padding(.top, PromptEditorLayout.placeholderTopPadding)
                    .allowsHitTesting(false)
            }
        }
    }

    private var promptAccessoryBar: some View {
        HStack(spacing: 6) {
            if showsAttachmentControls || !attachments.isEmpty {
                attachmentButton
                if !attachments.isEmpty, !supportsAttachments {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .help(ToolAttachmentSupport.unavailableMessage)
                        .accessibilityLabel(ToolAttachmentSupport.unavailableMessage)
                }
                ForEach(attachments) { attachment in
                    PromptAttachmentPreview(
                        attachment: attachment,
                        isRemovalEnabled: !isSubmitting,
                        onRemove: { onRemoveAttachment(attachment.id) }
                    )
                }
            }
            Spacer(minLength: 0)
            expansionButton
        }
        .padding(.horizontal, 8)
        .padding(.top, PromptEditorLayout.accessoryBarTopPadding)
        .padding(.bottom, PromptEditorLayout.accessoryBarBottomPadding)
        .frame(height: PromptEditorLayout.accessoryBarHeight, alignment: .top)
    }

    private var attachmentButton: some View {
        Button {
            isShowingFileImporter = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(accessoryButtonFill, in: Circle())
                .overlay {
                    Circle()
                        .stroke(accessoryButtonBorder, lineWidth: 0.75)
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(
            isSubmitting
                || !showsAttachmentControls
                || attachments.count >= ToolPromptAttachmentLoader.maximumAttachmentCount
        )
        .help(attachmentButtonHelp)
        .accessibilityLabel("Add attachments")
        .accessibilityIdentifier("prompt-attachment-button")
    }

    private var attachmentButtonHelp: String {
        if !showsAttachmentControls { return ToolAttachmentSupport.unavailableMessage }
        if attachments.count >= ToolPromptAttachmentLoader.maximumAttachmentCount {
            return "You can attach up to six files."
        }
        return "Add files"
    }

    private var acceptsAttachmentDrops: Bool {
        showsAttachmentControls
            && !isSubmitting
            && attachments.count < ToolPromptAttachmentLoader.maximumAttachmentCount
    }

    private func acceptDroppedFiles(_ urls: [URL]) -> Bool {
        guard acceptsAttachmentDrops, !urls.isEmpty else { return false }
        onAddAttachments(urls)
        return true
    }

    private var expansionButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.24)) {
                isExpanded.toggle()
            }
        } label: {
            Image(
                systemName: isExpanded
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right"
            )
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 24, height: 24)
            .background(accessoryButtonFill, in: Circle())
            .overlay {
                Circle()
                    .stroke(accessoryButtonBorder, lineWidth: 0.75)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(isExpanded ? "Collapse prompt" : "Expand prompt")
        .accessibilityLabel(isExpanded ? "Collapse prompt" : "Expand prompt")
        .accessibilityIdentifier("prompt-expansion-button")
    }

    private var accessoryButtonFill: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.07)
    }

    private var accessoryButtonBorder: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.20 : 0.10)
    }

    private var generationSettingsMenu: some View {
        Menu {
            Picker("App Type", selection: $appKind) {
                ForEach(ToolAppKind.allCases, id: \.self) { kind in
                    Label(
                        kind.displayName,
                        systemImage: kind == .menuBar ? "menubar.rectangle" : "macwindow"
                    )
                    .tag(kind)
                }
            }

            Menu("Coding Agent") {
                checkedSelectionButton(
                    .automatic,
                    selection: $codingAgentPreference,
                    displayName: ToolCodingAgentPreference.automatic.displayName
                )
                checkedSelectionButton(
                    .ironsmithSpark,
                    selection: $codingAgentPreference,
                    displayName: ToolCodingAgentPreference.ironsmithSpark.displayName
                )
                checkedSelectionButton(
                    .ironsmithFlame,
                    selection: $codingAgentPreference,
                    displayName: ToolCodingAgentPreference.ironsmithFlame.displayName
                )
                checkedSelectionButton(
                    .codex,
                    selection: $codingAgentPreference,
                    displayName: ToolCodingAgentPreference.codex.displayName,
                    isEnabled: isCodexAgentSupported
                )
            }

            if !supportedReasoningEfforts.isEmpty {
                Menu("Reasoning") {
                    checkedSelectionButton(
                        .default,
                        selection: $reasoningEffort,
                        displayName: ToolReasoningEffort.default.displayName
                    )
                    ForEach(ToolReasoningEffort.allCases.filter { $0 != .default }, id: \.self) {
                        effort in
                        checkedSelectionButton(
                            effort,
                            selection: $reasoningEffort,
                            displayName: effort.displayName,
                            isEnabled: supportedReasoningEfforts.contains(effort)
                        )
                    }
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
                        Toggle(
                            permission.displayName, isOn: resourcePermissionBinding(for: permission)
                        )
                    }
                }

                Section("Sandbox Access") {
                    ForEach(GeneratedAppSandboxPermission.allCases) { permission in
                        Toggle(
                            permission.displayName, isOn: sandboxPermissionBinding(for: permission))
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
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) {
            notification in
            guard let menu = notification.object as? NSMenu else { return }
            CodingAgentMenuHelp.apply(to: menu)
        }
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
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 24))
            } else {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(submitButtonForegroundStyle)
        .disabled(!isSubmitEnabled && !isSubmitting)
        .help(isSubmitting ? "Pause generation" : "Generate")
        .accessibilityLabel(isSubmitting ? "Pause generation" : "Generate app")
        .accessibilityHint(
            isSubmitting
                ? "Pauses the current app generation so it can be continued later."
                : "Starts generating an app from the prompt."
        )
        .accessibilityIdentifier(
            isSubmitting ? "pause-generation-button" : "submit-generation-button")
    }

    private var submitButtonForegroundStyle: some ShapeStyle {
        if isSubmitting {
            return AnyShapeStyle(.secondary)
        }

        if isSubmitEnabled {
            return AnyShapeStyle(.tint)
        }

        return AnyShapeStyle(.secondary)
    }

    private var sandboxHelpText: String {
        "Controls whether generated apps include App Sandbox entitlements."
    }

    private func checkedSelectionButton<Value: Equatable>(
        _ value: Value,
        selection: Binding<Value>,
        displayName: String,
        isEnabled: Bool = true
    ) -> some View {
        Button {
            guard isEnabled else { return }
            selection.wrappedValue = value
        } label: {
            if selection.wrappedValue == value {
                Label(displayName, systemImage: "checkmark")
            } else {
                Text(displayName)
            }
        }
        .disabled(!isEnabled)
    }

    private func resourcePermissionBinding(for permission: GeneratedAppResourcePermission)
        -> Binding<Bool>
    {
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

    private func sandboxPermissionBinding(for permission: GeneratedAppSandboxPermission) -> Binding<
        Bool
    > {
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

    private func setResourcePermission(_ permission: GeneratedAppResourcePermission, enabled: Bool)
    {
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

private enum CodingAgentMenuHelp {
    private static let tooltips: [String: String] = [
        ToolCodingAgentPreference.ironsmithSpark.displayName:
            "Best for simple apps using on-device AI.",
        ToolCodingAgentPreference.ironsmithFlame.displayName:
            "Best for moderately complex apps using cloud AI. More token-efficient than Codex for smaller apps, but less efficient for complex ones.",
        ToolCodingAgentPreference.codex.displayName:
            "Best for complex, feature-rich apps. Typically uses 1.5-2x more tokens than Flame.",
    ]

    static func apply(to menu: NSMenu) {
        for item in menu.items {
            if let tooltip = tooltips[item.title] {
                item.toolTip = tooltip
            }
            if let submenu = item.submenu {
                apply(to: submenu)
            }
        }
    }
}

private enum PromptEditorLayout {
    static let compactTextEditorHeight: CGFloat = 46
    static let accessoryBarHeight: CGFloat = 30
    static let accessoryBarTopPadding: CGFloat = 2
    static let accessoryBarBottomPadding: CGFloat = 4
    static let textEditorHorizontalPadding: CGFloat = 8
    static let textEditorTopPadding: CGFloat = 12
    static let placeholderLeadingPadding: CGFloat = 13
    static let placeholderTopPadding: CGFloat = 12
}

private struct PromptAttachmentPreview: View {
    let attachment: ToolPromptAttachment
    let isRemovalEnabled: Bool
    let onRemove: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onRemove) {
            ZStack {
                thumbnail

                if isHovering, isRemovalEnabled {
                    Color.black.opacity(0.32)

                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 24, height: 24)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(!isRemovalEnabled)
        .onHover { isHovering = $0 }
        .help("Remove \(attachment.fileName)")
        .accessibilityLabel("Remove \(attachment.fileName)")
    }

    @ViewBuilder
    private var thumbnail: some View {
        if attachment.isImage, let image = NSImage(data: attachment.data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 24, height: 24)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(.quaternary.opacity(0.5))

                Image(systemName: "doc.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 24, height: 24)
        }
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
    @State private var isExpanded = false
    @FocusState private var isPromptFocused: Bool

    var body: some View {
        PromptComposerView(
            prompt: .constant(""),
            isExpanded: $isExpanded,
            sandboxEnabled: .constant(!isEditing),
            appKind: .constant(isEditing ? .menuBar : .window),
            sandboxPermissions: .constant(.default),
            resourcePermissions: .constant(
                isEditing ? GeneratedAppResourcePermissions([.camera]) : .none
            ),
            codingAgentPreference: .constant(.automatic),
            reasoningEffort: .constant(.default),
            placeholder: isEditing
                ? "Describe changes for Clipboard Cleaner…"
                : "Describe a new app to build…",
            showsSandboxControl: isEditing,
            modelPickerTitle: "DeepSeek V4 Flash",
            isModelPickerEnabled: true,
            isSubmitEnabled: isEditing,
            isSubmitting: false,
            isCodexAgentSupported: true,
            showsAttachmentControls: true,
            supportsAttachments: true,
            attachments: [],
            supportedReasoningEfforts: [.low, .medium, .high],
            isPromptFocused: $isPromptFocused,
            onChooseModel: {},
            onSubmit: {},
            onCancel: {},
            onAddAttachments: { _ in },
            onRemoveAttachment: { _ in }
        )
        .padding()
        .frame(width: 360, height: 440)
    }
}
