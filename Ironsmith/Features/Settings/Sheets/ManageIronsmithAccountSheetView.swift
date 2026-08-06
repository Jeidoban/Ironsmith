import SwiftUI

struct ManageIronsmithAccountSheetView: View {
    @Environment(InferenceStore.self) private var inferenceStore
    @Environment(\.dismiss) private var dismiss
    let onBuyCredits: () -> Void

    @State private var displayName = ""
    @State private var handle = ""
    @State private var isSaving = false
    @State private var isSigningOut = false
    @State private var isDeleting = false
    @State private var isConfirmingDeletion = false
    @State private var isConfirmingDeletionWithCredits = false
    @State private var isConfirmingHandleClaim = false
    @State private var handleAvailability: Bool?
    @State private var handleAvailabilityCheckFailed = false
    @State private var showsHandleRequirements = false

    var body: some View {
        Form {
            Section("Creator Profile") {
                TextField("Display Name", text: $displayName)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 12) {
                        Text("Handle")
                        Spacer(minLength: 12)
                        if existingHandle != nil {
                            Text("@\(normalizedHandle)")
                                .foregroundStyle(.secondary)
                        } else {
                            TextField(
                                "",
                                text: handleText,
                                prompt: Text("@your_handle")
                            )
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 220)
                        }
                    }
                    if let handleSupportingText {
                        Text(handleSupportingText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Section("Account") {
                LabeledContent("Email", value: accountEmail)
                LabeledContent("Available Credits", value: creditsText)
                Button("Buy Credits…", action: onBuyCredits)
            }

        }
        .formStyle(.grouped)
        .padding(20)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button(isSigningOut ? "Signing Out…" : "Sign Out") {
                    signOut()
                }
                .disabled(isSigningOut || isDeleting)

                Button("Delete Account", role: .destructive) {
                    isConfirmingDeletion = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isSigningOut || isDeleting)

                Spacer()
                Button("Cancel") { dismiss() }
                Button(isSaving ? "Saving…" : "Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave || isSaving)
            }
            .padding(20)
            .background(.bar)
        }
        .frame(width: 540, height: 500)
        .task {
            await loadThenRefreshProfile()
        }
        .task(id: normalizedHandle) {
            await refreshHandleAvailability()
        }
        .task(id: handle) {
            await refreshHandleRequirementsVisibility()
        }
        .confirmationDialog("Delete Ironsmith Account?", isPresented: $isConfirmingDeletion) {
            Button("Delete Account", role: .destructive) {
                if (remainingCreditBalance ?? 0) > 0 {
                    isConfirmingDeletionWithCredits = true
                } else {
                    deleteAccount()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This permanently deletes your Ironsmith account, removes its provider, and forfeits any remaining credits."
            )
        }
        .confirmationDialog(
            "Delete Account With Credits?",
            isPresented: $isConfirmingDeletionWithCredits
        ) {
            Button("Delete Anyway", role: .destructive) { deleteAccount() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "You still have \(creditsText). Deleting your account removes access to these credits. If you purchased credits less than 30 days ago, you can get a refund by contacting support@ironsmith.app."
            )
        }
        .alert("Set Creator Handle?", isPresented: $isConfirmingHandleClaim) {
            Button("Cancel", role: .cancel) {}
            Button("Set Handle") { saveProfile() }
        } message: {
            Text("@\(normalizedHandle) cannot be changed after it is claimed.")
        }
    }

    private var profile: IronsmithAccountProfile? {
        inferenceStore.ironsmithAccountSummary?.profile
    }

    private var existingHandle: String? { profile?.handle }
    private var normalizedHandle: String {
        IronsmithCreatorHandle.normalized(handle)
    }
    private var normalizedDisplayName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var handleIsValid: Bool {
        normalizedHandle.isEmpty || IronsmithCreatorHandle.isValid(normalizedHandle)
    }
    private var canSave: Bool {
        (1...80).contains(normalizedDisplayName.count)
            && (existingHandle != nil
                || handleIsValid
                    && !normalizedHandle.isEmpty
                    && (handleAvailability == true || handleAvailabilityCheckFailed))
    }
    private var accountEmail: String {
        inferenceStore.ironsmithAccountSummary?.user.email ?? "Hidden"
    }
    private var creditsText: String {
        guard let credits = remainingCreditBalance else {
            return "Unknown"
        }
        return credits == 1 ? "1 credit" : "\(credits) credits"
    }
    private var remainingCreditBalance: Int? {
        inferenceStore.ironsmithAccountSummary?.credits.balanceCredits
    }
    private var handleStatusText: String {
        guard handleIsValid else {
            return
                "Use 3–30 letters, numbers, or underscores; begin and end with a letter or number."
        }
        if handleAvailabilityCheckFailed {
            return "Couldn’t check availability. Ironsmith will verify this handle when you save."
        }
        switch handleAvailability {
        case true: return "This handle is available."
        case false: return "This handle is unavailable."
        case nil: return "Checking availability…"
        }
    }
    private var handleSupportingText: String? {
        guard existingHandle == nil else { return nil }
        guard !normalizedHandle.isEmpty else { return nil }
        if handleIsValid {
            return handleStatusText
        }
        return showsHandleRequirements
            ? "Use 3–30 letters, numbers, or underscores; begin and end with a letter or number."
            : nil
    }
    private var handleText: Binding<String> {
        Binding(
            get: { handle.isEmpty ? "" : "@\(handle)" },
            set: { value in
                handle = value.hasPrefix("@") ? String(value.dropFirst()) : value
            }
        )
    }

    private func loadProfile() {
        displayName = profile?.displayName ?? ""
        handle = profile?.handle ?? ""
    }

    private func loadThenRefreshProfile() async {
        loadProfile()
        let initialDisplayName = displayName
        let initialHandle = handle
        await inferenceStore.refreshIronsmithAccountSummary()
        if displayName == initialDisplayName {
            displayName = profile?.displayName ?? ""
        }
        if handle == initialHandle {
            handle = profile?.handle ?? ""
        }
    }

    private func refreshHandleAvailability() async {
        guard existingHandle == nil, !normalizedHandle.isEmpty, handleIsValid else {
            handleAvailability = existingHandle == nil && normalizedHandle.isEmpty ? true : nil
            handleAvailabilityCheckFailed = false
            return
        }
        let requestedHandle = normalizedHandle
        handleAvailability = nil
        handleAvailabilityCheckFailed = false
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        do {
            let availability = try await inferenceStore
                .checkIronsmithHandleAvailability(requestedHandle)
            guard !Task.isCancelled, normalizedHandle == requestedHandle else { return }
            handleAvailability = availability.available
        } catch {
            guard !Task.isCancelled, normalizedHandle == requestedHandle else { return }
            handleAvailability = nil
            handleAvailabilityCheckFailed = true
        }
    }

    private func refreshHandleRequirementsVisibility() async {
        showsHandleRequirements = false
        guard existingHandle == nil, !normalizedHandle.isEmpty, !handleIsValid else {
            return
        }
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { return }
        showsHandleRequirements = true
    }

    private func save() {
        guard canSave else { return }
        if existingHandle == nil {
            isConfirmingHandleClaim = true
            return
        }
        saveProfile()
    }

    private func saveProfile() {
        isSaving = true
        Task {
            do {
                _ = try await inferenceStore.updateIronsmithAccountProfile(
                    IronsmithAccountProfileUpdate(
                        displayName: normalizedDisplayName,
                        handle: existingHandle == nil && !normalizedHandle.isEmpty
                            ? normalizedHandle
                            : nil
                    )
                )
                dismiss()
            } catch {
                inferenceStore.presentError(error)
            }
            isSaving = false
        }
    }

    private func signOut() {
        isSigningOut = true
        Task {
            if await inferenceStore.signOutIronsmithAccount() { dismiss() }
            isSigningOut = false
        }
    }

    private func deleteAccount() {
        isDeleting = true
        Task {
            if await inferenceStore.deleteIronsmithAccount() { dismiss() }
            isDeleting = false
        }
    }
}
