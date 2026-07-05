import Supabase
import AppKit
import SwiftUI

struct ProviderEditorSheetView: View {
    @Environment(InferenceStore.self) private var inferenceStore
    @Environment(\.scenePhase) private var scenePhase
    let provider: ProviderConfig
    @Environment(\.dismiss) private var dismiss

    @State private var apiKey = ""
    @State private var displayName = ""
    @State private var baseURLString = ""
    @State private var isConfirmingDelete = false
    @State private var isConfirmingAccountDeletion = false
    @State private var isConfirmingAccountDeletionWithCredits = false
    @State private var isShowingCreditPacks = false
    @State private var isSigningOut = false
    @State private var isSigningInToChatGPT = false
    @State private var isSigningOutOfChatGPT = false
    @State private var isDeletingAccount = false

    private var isCustomOpenAICompatible: Bool {
        provider.kind == .customOpenAICompatible
    }

    private var isIronsmith: Bool {
        provider.kind == .ironsmith
    }

    private var isOpenAI: Bool {
        provider.kind == .openAI
    }

    private var isOllama: Bool {
        provider.kind == .ollama
    }

    private var usesEditableConnection: Bool {
        isCustomOpenAICompatible || isOllama
    }

    init(
        provider: ProviderConfig,
        showsCreditPacksOnAppear: Bool = false
    ) {
        self.provider = provider
        _isShowingCreditPacks = State(initialValue: showsCreditPacksOnAppear)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    providerSummaryRow
                }
                if provider.kind == .local {
                    Section {
                        LocalModelManagementView(provider: provider)
                    } header: {
                        Text("AI Models")
                    }
                } else if isIronsmith {
                    Section {
                        ironsmithAccountRows
                    } header: {
                        Text("Account")
                    }

                    Section {
                        LabeledContent("Available Credits") {
                            Text(ironsmithBalanceText)
                        }

                        Button("Buy Credits") {
                            isShowingCreditPacks = true
                        }
                    } header: {
                        Text("Billing")
                    }
                } else if isOpenAI {
                    openAIAuthenticationSections
                } else {
                    if usesEditableConnection {
                        Section {
                            if isCustomOpenAICompatible {
                                TextField("Display Name", text: $displayName, prompt: Text("LM Studio"))
                            }
                            TextField(
                                isOllama ? "Server URL" : "Base URL",
                                text: $baseURLString,
                                prompt: Text(isOllama ? "http://localhost:11434" : "http://localhost:1234/v1")
                            )
                        } header: {
                            Text("Connection")
                        }
                    }

                    Section {
                        SecureField(
                            "API Key",
                            text: $apiKey,
                            prompt: Text(usesEditableConnection ? "Optional" : "Required")
                        )
                    } header: {
                        Text("Authentication")
                    }

                    if isOllama {
                        Section {
                            OllamaModelManagementView(provider: provider)
                        } header: {
                            Text("Recommended AI Models")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .padding(20)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                if isIronsmith {
                    Button("Delete Account", role: .destructive) {
                        isConfirmingAccountDeletion = true
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(isDeletingAccount || isSigningOut)

                    Button(isSigningOut ? "Signing Out..." : "Sign Out") {
                        signOut()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSigningOut || isDeletingAccount)
                } else if provider.isRemovable {
                    Button("Delete Provider", role: .destructive) {
                        isConfirmingDelete = true
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }

                Spacer()

                Button("Close") {
                    dismiss()
                }

                if provider.kind != .local && !isIronsmith {
                    Button("Save") {
                        Task {
                            let didSave = await inferenceStore.saveProviderEdits(
                                provider: provider,
                                apiKey: apiKey,
                                displayName: isCustomOpenAICompatible ? displayName : nil,
                                baseURLString: usesEditableConnection ? baseURLString : nil
                            )
                            await MainActor.run {
                                if didSave {
                                    dismiss()
                                }
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaveDisabled)
                }
            }
            .padding(20)
            .background(.bar)
        }
        .frame(minWidth: 540, minHeight: 430)
        .onAppear {
            apiKey = inferenceStore.apiKey(for: provider)
            displayName = provider.displayName
            baseURLString = provider.baseURLString
            if isIronsmith {
                inferenceStore.refreshIronsmithSession()
            }
            if isOpenAI {
                inferenceStore.refreshOpenAICodexCredential()
            }
        }
        .task(id: provider.identifier) {
            if isIronsmith {
                await inferenceStore.refreshIronsmithAccountSummary()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard isIronsmith, phase == .active else { return }
            Task {
                await inferenceStore.refreshIronsmithAccountSummary()
            }
        }
        .textFieldStyle(.roundedBorder)
        .sheet(isPresented: $isShowingCreditPacks, onDismiss: {
            Task {
                await inferenceStore.refreshIronsmithAccountSummary()
            }
        }) {
            IronsmithCreditPackPurchaseSheetView()
                .environment(inferenceStore)
        }
        .confirmationDialog(
            "Delete \(provider.displayName)?",
            isPresented: $isConfirmingDelete
        ) {
            Button("Delete Provider", role: .destructive) {
                inferenceStore.removeProvider(provider)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes \(provider.displayName) and all of its AI models from Ironsmith.")
        }
        .confirmationDialog(
            "Delete Ironsmith Account?",
            isPresented: $isConfirmingAccountDeletion
        ) {
            Button("Delete Account", role: .destructive) {
                if (remainingIronsmithCreditBalance ?? 0) > 0 {
                    isConfirmingAccountDeletionWithCredits = true
                } else {
                    deleteAccount()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your Ironsmith account and removes this provider from the app.")
        }
        .confirmationDialog(
            "Delete Account With Credits?",
            isPresented: $isConfirmingAccountDeletionWithCredits
        ) {
            Button("Delete Anyway", role: .destructive) {
                deleteAccount()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "You still have \(ironsmithBalanceText). Deleting your account removes access to these credits. If you purchased credits less than 30 days ago, you can get a refund by contacting support@ironsmith.app"
            )
        }
    }

    private var providerSummaryRow: some View {
        ProviderSummaryRowView(provider: provider, logoSize: 34, subtitleFont: .subheadline)
            .padding(.vertical, 2)
    }

    @ViewBuilder
    private var openAIAuthenticationSections: some View {
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

                if inferenceStore.hasOpenAICodexCredential {
                    Button(openAIChatGPTSignOutTitle) {
                        signOutOpenAIChatGPT()
                    }
                    .disabled(isSigningInToChatGPT || isSigningOutOfChatGPT)
                } else {
                    Button(openAIChatGPTSignInTitle) {
                        signInWithOpenAIChatGPT()
                    }
                    .disabled(isSigningInToChatGPT || isSigningOutOfChatGPT)
                }
            }
        } header: {
            Text("ChatGPT")
        }
    }

    @ViewBuilder
    private var ironsmithAccountRows: some View {
        if let summary = inferenceStore.ironsmithAccountSummary {
            LabeledContent("Email") {
                Text(summary.user.email ?? "Hidden")
                    .textSelection(.enabled)
            }
        } else if let session = inferenceStore.ironsmithSession {
            LabeledContent("Email") {
                Text(session.user.email ?? "Hidden")
                    .textSelection(.enabled)
            }
        } else {
            Text("Not Signed In")
                .foregroundStyle(.secondary)
        }
    }

    private var ironsmithBalanceText: String {
        guard let credits = remainingIronsmithCreditBalance else {
            return "Unknown"
        }

        return credits == 1 ? "1 credit" : "\(credits) credits"
    }

    private var remainingIronsmithCreditBalance: Int? {
        inferenceStore.ironsmithAccountSummary?.credits.balanceCredits
    }

    private var openAIChatGPTStatusText: String {
        inferenceStore.openAICodexCredential?.statusText ?? "Not signed in"
    }

    private var openAIChatGPTSignInTitle: String {
        isSigningInToChatGPT ? "Signing In..." : "Sign In"
    }

    private var openAIChatGPTSignOutTitle: String {
        isSigningOutOfChatGPT ? "Signing Out..." : "Sign Out"
    }

    private func signOut() {
        guard !isSigningOut else { return }

        isSigningOut = true
        Task {
            let didSignOut = await inferenceStore.signOutIronsmithProvider(provider)
            await MainActor.run {
                isSigningOut = false
                if didSignOut {
                    dismiss()
                }
            }
        }
    }

    private func deleteAccount() {
        guard !isDeletingAccount else { return }

        isDeletingAccount = true
        Task {
            let didDelete = await inferenceStore.deleteIronsmithAccount(provider: provider)
            await MainActor.run {
                isDeletingAccount = false
                if didDelete {
                    dismiss()
                }
            }
        }
    }

    private func signInWithOpenAIChatGPT() {
        guard !isSigningInToChatGPT, !isSigningOutOfChatGPT else { return }

        isSigningInToChatGPT = true
        Task {
            let didSignIn = await inferenceStore.signInToOpenAIChatGPT { @MainActor url in
                guard NSWorkspace.shared.open(url) else {
                    throw OpenAICodexAuthClientError.browserLaunchFailed
                }
            }

            await MainActor.run {
                isSigningInToChatGPT = false
                if didSignIn {
                    inferenceStore.refreshOpenAICodexCredential()
                }
            }
        }
    }

    private func signOutOpenAIChatGPT() {
        guard !isSigningInToChatGPT, !isSigningOutOfChatGPT else { return }

        isSigningOutOfChatGPT = true
        Task {
            let didSignOut = await MainActor.run {
                inferenceStore.signOutOpenAIChatGPT(provider: provider)
            }
            await MainActor.run {
                isSigningOutOfChatGPT = false
                if didSignOut {
                    inferenceStore.refreshOpenAICodexCredential()
                }
            }
        }
    }

    private var isSaveDisabled: Bool {
        if isCustomOpenAICompatible {
            return displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || baseURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        if isOllama {
            return baseURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        return false
    }
}
