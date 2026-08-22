import AuthenticationServices
import SwiftUI

struct SettingsAccountSectionView: View {
    @Environment(InferenceStore.self) private var inferenceStore
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @AppStorage(IronsmithPreferenceKeys.featureStoreEnabled) private var isStoreFeatureEnabled =
        false
    let onManageAccount: () -> Void
    @State private var isSigningIn = false
    #if DEBUG
    @State private var email = ""
    @State private var password = ""
    #endif

    var body: some View {
        Section("Ironsmith Account") {
            if inferenceStore.ironsmithSession == nil {
                LabeledContent("Ironsmith Account") {
                    Button(isSigningIn ? "Signing In…" : "Sign In") {
                        signIn()
                    }
                    .disabled(isSigningIn)
                }
                #if DEBUG
                VStack(alignment: .leading, spacing: 8) {
                    Text("Debug email/password sign-in")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Email", text: $email)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Create Account") {
                            authenticateWithEmailPassword(createAccount: true)
                        }
                        Button("Sign In") {
                            authenticateWithEmailPassword(createAccount: false)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .disabled(isEmailPasswordAuthenticationDisabled)
                }
                #endif
                Text(accountSignInDescription)
                    .foregroundStyle(.secondary)
            } else {
                if let email = inferenceStore.ironsmithAccountSummary?.user.email {
                    LabeledContent("Email", value: email)
                }
                if isStoreFeatureEnabled {
                    LabeledContent("Display Name") {
                        Text(displayName ?? "Not set")
                            .foregroundStyle(displayName == nil ? .secondary : .primary)
                    }
                    LabeledContent("Creator Handle") {
                        Text(handleText)
                            .foregroundStyle(handle == nil ? .secondary : .primary)
                    }
                }
                Button("Manage Account…", action: onManageAccount)
            }
        }
    }

    private var accountSignInDescription: String {
        if isStoreFeatureEnabled {
            return "Sign in to publish apps, manage your creator identity, and use Ironsmith credits."
        }
        return "Sign in to use Ironsmith models and credits."
    }

    private var handle: String? {
        inferenceStore.ironsmithAccountSummary?.profile?.handle
    }

    private var displayName: String? {
        guard let displayName = inferenceStore.ironsmithAccountSummary?.profile?.displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !displayName.isEmpty
        else {
            return nil
        }
        return displayName
    }

    private var handleText: String {
        handle.map { "@\($0)" } ?? "Not set"
    }

    private func signIn() {
        guard !isSigningIn else { return }
        isSigningIn = true
        Task {
            _ = await inferenceStore.signInToIronsmithWithAppleOAuth { @MainActor url in
                try await webAuthenticationSession.authenticate(
                    using: url,
                    callbackURLScheme: IronsmithOAuthRedirect.appCallbackScheme
                )
            }
            isSigningIn = false
        }
    }

    #if DEBUG
    private var isEmailPasswordAuthenticationDisabled: Bool {
        isSigningIn
            || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || password.isEmpty
    }

    private func authenticateWithEmailPassword(createAccount: Bool) {
        guard !isEmailPasswordAuthenticationDisabled else { return }
        isSigningIn = true
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = password
        Task {
            defer {
                isSigningIn = false
                self.password = ""
            }
            if createAccount {
                _ = await inferenceStore.createIronsmithAccountWithEmailPassword(
                    email: email,
                    password: password
                )
            } else {
                _ = await inferenceStore.signInToIronsmithWithEmailPassword(
                    email: email,
                    password: password
                )
            }
        }
    }
    #endif
}
