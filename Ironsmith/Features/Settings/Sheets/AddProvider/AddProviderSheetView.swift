import AuthenticationServices
import SwiftUI

struct AddProviderSheetView: View {
    @Environment(InferenceStore.self) private var inferenceStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    private let initialKind: ProviderKind?
    private let onProviderAdded: (ProviderKind) -> Void

    @State private var selectedChoice: InferenceStore.ProviderChoice?
    @State private var displayName = ""
    @State private var baseURLString = ""
    @State private var apiKey = ""
    @State private var openAICompatibleAPIVariant: OpenAICompatibleAPIVariant = .chatCompletions
    @State private var isSaving = false
    @State private var isSigningInToChatGPT = false

    private var isCustomOpenAICompatible: Bool {
        selectedChoice?.kind == .customOpenAICompatible
    }

    private var isOpenAI: Bool {
        selectedChoice?.kind == .openAI
    }

    private var isIronsmith: Bool {
        selectedChoice?.kind == .ironsmith
    }

    private var isOllama: Bool {
        selectedChoice?.kind == .ollama
    }

    private var usesEditableConnection: Bool {
        isCustomOpenAICompatible || isOllama
    }

    init(
        initialKind: ProviderKind? = nil,
        onProviderAdded: @escaping (ProviderKind) -> Void = { _ in }
    ) {
        self.initialKind = initialKind
        self.onProviderAdded = onProviderAdded
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                providerPicker

                if isIronsmith {
                    IronsmithProviderIntroView(
                        isSigningIn: isSaving,
                        action: signInWithAppleOAuth
                    )
                } else {
                    providerConfigurationForm
                }
            }
            .padding(20)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    if !isIronsmith {
                        Button(isSaving ? "Adding..." : "Add") {
                            saveProvider()
                        }
                        .disabled(isAddDisabled)
                    }
                }
            }
        }
        .frame(minWidth: 540, minHeight: 420)
        .onAppear {
            selectedChoice = initialProviderChoice()
            configureFields(for: selectedChoice)
        }
        .onChange(of: selectedChoice) { _, newChoice in
            configureFields(for: newChoice)
        }
    }

    private func initialProviderChoice() -> InferenceStore.ProviderChoice? {
        guard let initialKind else {
            return inferenceStore.availableProviderChoices.first
        }
        return inferenceStore.availableProviderChoices.first { $0.kind == initialKind }
            ?? inferenceStore.availableProviderChoices.first
    }

    private var providerPicker: some View {
        HStack {
            Spacer()
            Picker("Provider", selection: $selectedChoice) {
                ForEach(inferenceStore.availableProviderChoices) { choice in
                    Text(choice.title).tag(Optional(choice))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            Spacer()
        }
        .padding(.top, 8)
    }

    private var providerConfigurationForm: some View {
        Form {
            if isOllama {
                Section {
                    OllamaInstallRowView()
                } header: {
                    Text("Installation")
                }
            }

            if isOpenAI {
                Section {
                    SecureField("API Key", text: $apiKey, prompt: Text("Optional"))
                } header: {
                    Text("API Key")
                }

                Section {
                    HStack {
                        LabeledContent("ChatGPT") {
                            Text(openAIChatGPTStatusText)
                                .foregroundStyle(inferenceStore.hasOpenAICodexCredential ? .primary : .secondary)
                        }

                        Spacer()

                        Button(openAIChatGPTButtonTitle) {
                            signInWithOpenAIChatGPT()
                        }
                        .disabled(isSaving || isSigningInToChatGPT)
                    }
                } header: {
                    Text("ChatGPT")
                }
            } else {
                Section {
                    if isCustomOpenAICompatible {
                        TextField("Display Name", text: $displayName, prompt: Text("LM Studio"))
                    }

                    if usesEditableConnection {
                        TextField(
                            isOllama ? "Server URL" : "Base URL",
                            text: $baseURLString,
                            prompt: Text(
                                isOllama ? "http://localhost:11434" : "http://localhost:1234/v1")
                        )
                    }

                    if isCustomOpenAICompatible {
                        Picker("API", selection: $openAICompatibleAPIVariant) {
                            ForEach(OpenAICompatibleAPIVariant.allCases) { variant in
                                Text(variant.displayName).tag(variant)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    SecureField(
                        "API Key",
                        text: $apiKey,
                        prompt: Text(isCustomOpenAICompatible || isOllama ? "Optional" : "Required")
                    )
                } header: {
                    Text(usesEditableConnection ? "Connection" : "Authentication")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var isAddDisabled: Bool {
        guard !isSaving else { return true }
        guard selectedChoice != nil else { return true }

        if isIronsmith {
            return true
        }

        if isCustomOpenAICompatible {
            return displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || baseURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        if isOllama {
            let trimmedBaseURLString = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedBaseURLString.isEmpty
                || (ProviderBaseURLValidator.usesLoopbackHost(trimmedBaseURLString)
                    && inferenceStore.ollamaInstallationStatus != .installed)
        }

        if isOpenAI {
            return apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !inferenceStore.hasOpenAICodexCredential
        }

        return apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func configureFields(for choice: InferenceStore.ProviderChoice?) {
        guard let choice else { return }
        openAICompatibleAPIVariant = .chatCompletions

        switch choice.kind {
        case .ironsmith:
            displayName = ""
            baseURLString = ""
            apiKey = ""
        case .customOpenAICompatible:
            displayName = ""
            baseURLString = ""
        case .ollama:
            displayName = ""
            baseURLString =
                ProviderCatalog.descriptor(for: .ollama)?.defaultBaseURLString
                ?? "http://localhost:11434"
            inferenceStore.refreshOllamaInstallationStatus()
        default:
            displayName = ""
            baseURLString = ""
        }
    }

    private var openAIChatGPTStatusText: String {
        inferenceStore.openAICodexCredential?.statusText ?? "Not signed in"
    }

    private var openAIChatGPTButtonTitle: String {
        isSigningInToChatGPT ? "Signing In..." : "Sign In"
    }

    private func signInWithAppleOAuth() {
        guard !isSaving else { return }
        isSaving = true

        Task {
            let didSignIn = await inferenceStore.signInToIronsmithWithAppleOAuth { @MainActor url in
                try await webAuthenticationSession.authenticate(
                    using: url,
                    callbackURLScheme: IronsmithOAuthRedirect.appCallbackScheme
                )
            }

            await MainActor.run {
                isSaving = false
                if didSignIn {
                    dismiss()
                }
            }
        }
    }

    private func saveProvider() {
        guard let selectedChoice else { return }
        guard selectedChoice.kind != .ironsmith else { return }

        isSaving = true
        Task {
            let didAdd = await inferenceStore.addProvider(
                choice: selectedChoice,
                apiKey: apiKey,
                displayName: displayName,
                baseURLString: baseURLString,
                openAICompatibleAPIVariant: openAICompatibleAPIVariant
            )

            await MainActor.run {
                isSaving = false
                if didAdd {
                    onProviderAdded(selectedChoice.kind)
                    dismiss()
                }
            }
        }
    }

    private func signInWithOpenAIChatGPT() {
        guard !isSaving, !isSigningInToChatGPT else { return }
        guard let selectedChoice, selectedChoice.kind == .openAI else { return }
        isSigningInToChatGPT = true

        Task {
            let didSignIn = await inferenceStore.signInToOpenAIChatGPT()

            if didSignIn {
                await MainActor.run {
                    isSaving = true
                }
                let didAdd = await inferenceStore.addProvider(
                    choice: selectedChoice,
                    apiKey: apiKey,
                    displayName: displayName,
                    baseURLString: baseURLString,
                    openAICompatibleAPIVariant: openAICompatibleAPIVariant
                )
                await MainActor.run {
                    isSaving = false
                    isSigningInToChatGPT = false
                    if didAdd {
                        onProviderAdded(.openAI)
                        dismiss()
                    }
                }
                return
            }

            await MainActor.run {
                isSigningInToChatGPT = false
            }
        }
    }
}
