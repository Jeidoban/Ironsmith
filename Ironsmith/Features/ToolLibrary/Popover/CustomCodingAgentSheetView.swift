import SwiftUI

struct CustomCodingAgentSheetView: View {
    @Environment(InferenceStore.self) private var inferenceStore
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: CustomCodingAgentStore
    let startsWithNewAgent: Bool
    @State private var draft: CustomCodingAgent?
    @State private var selectedID: UUID?
    @State private var errorMessage: String?
    @State private var selectedPreset = CustomCodingAgentPreset.custom

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            editor
        }
        .frame(width: 720, height: 440)
        .onAppear {
            if startsWithNewAgent {
                beginAddingAgent()
            } else {
                selectedID = store.selectedAgentID ?? store.agents.first?.id
                loadSelectedDraft()
            }
        }
        .onChange(of: selectedID) { _, _ in loadSelectedDraft() }
    }

    private var sidebar: some View {
        VStack(spacing: 10) {
            List(store.agents, selection: $selectedID) { agent in
                Text(agent.name).tag(agent.id)
            }
            HStack {
                Button {
                    beginAddingAgent()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add coding agent")

                Button(role: .destructive) {
                    deleteSelectedAgent()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(store.agents.contains(where: { $0.id == selectedID }) == false)
                .help("Delete coding agent")
                Spacer()
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(width: 220)
    }

    @ViewBuilder
    private var editor: some View {
        if draft != nil {
            VStack(alignment: .leading, spacing: 16) {
                Text(store.agents.contains(where: { $0.id == draft?.id }) ? "Edit Agent" : "Add Agent")
                    .font(.title2.weight(.semibold))

                Picker(
                    "Preset",
                    selection: Binding(
                        get: { selectedPreset },
                        set: { preset in
                            selectedPreset = preset
                            applyPreset(preset)
                        }
                    )
                ) {
                    ForEach(CustomCodingAgentPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.segmented)

                TextField("Name", text: draftNameBinding)
                TextField("Command", text: draftCommandBinding, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(3...6)

                Picker("Send prompt", selection: draftDeliveryBinding) {
                    Text("Replace {{prompt}}").tag(CustomCodingAgent.PromptDelivery.placeholder)
                    Text("Standard input").tag(CustomCodingAgent.PromptDelivery.standardInput)
                }

                Label(
                    "This command runs with your normal shell permissions. Ironsmith does not manage its installation, login, model, sandbox, or approvals.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)

                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
                Spacer()
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                    Button("Save") { saveDraft() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(22)
        } else {
            ContentUnavailableView(
                "No Custom Agents",
                systemImage: "terminal",
                description: Text("Add a runner to use any command-line coding agent.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func applyPreset(_ preset: CustomCodingAgentPreset) {
        guard let id = draft?.id else { return }
        var replacement = preset.agent
        replacement = CustomCodingAgent(
            id: id,
            name: replacement.name,
            command: replacement.command,
            promptDelivery: replacement.promptDelivery
        )
        draft = replacement
        errorMessage = nil
    }

    private func loadSelectedDraft() {
        guard let selectedID,
              let agent = store.agents.first(where: { $0.id == selectedID })
        else { return }
        draft = agent
        selectedPreset = .custom
        errorMessage = nil
    }

    private func beginAddingAgent() {
        let newAgent = CustomCodingAgentPreset.custom.agent
        selectedID = newAgent.id
        draft = newAgent
        selectedPreset = .custom
        errorMessage = nil
    }

    private var draftNameBinding: Binding<String> {
        Binding(
            get: { draft?.name ?? "" },
            set: { draft?.name = $0 }
        )
    }

    private var draftCommandBinding: Binding<String> {
        Binding(
            get: { draft?.command ?? "" },
            set: { draft?.command = $0 }
        )
    }

    private var draftDeliveryBinding: Binding<CustomCodingAgent.PromptDelivery> {
        Binding(
            get: { draft?.promptDelivery ?? .placeholder },
            set: { draft?.promptDelivery = $0 }
        )
    }

    private func saveDraft() {
        guard let draft else { return }
        do {
            let saved = try store.save(draft)
            selectedID = saved.id
            store.selectedAgentID = saved.id
            inferenceStore.generationPreferences.codingAgentPreference = .custom
            self.draft = saved
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteSelectedAgent() {
        guard let selectedID else { return }
        let deletedSelectedRunner = store.selectedAgentID == selectedID
        store.delete(id: selectedID)
        if deletedSelectedRunner {
            inferenceStore.generationPreferences.codingAgentPreference = .automatic
        }
        self.selectedID = store.agents.first?.id
        draft = self.selectedID.flatMap { id in store.agents.first { $0.id == id } }
    }
}
