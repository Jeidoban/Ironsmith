import AuthenticationServices
import SwiftUI

struct SettingsAccountSectionView: View {
    @Environment(InferenceStore.self) private var inferenceStore
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    let onManageAccount: () -> Void
    @State private var isSigningIn = false

    var body: some View {
        Section("Account") {
            if inferenceStore.ironsmithSession == nil {
                LabeledContent("Ironsmith Account") {
                    Button(isSigningIn ? "Signing In…" : "Sign In") {
                        signIn()
                    }
                    .disabled(isSigningIn)
                }
                Text("Sign in to publish apps, manage your creator identity, and use Ironsmith credits.")
                    .foregroundStyle(.secondary)
            } else {
                if let email = inferenceStore.ironsmithAccountSummary?.user.email {
                    LabeledContent("Email", value: email)
                }
                LabeledContent("Creator Handle") {
                    Text(handleText)
                        .foregroundStyle(handle == nil ? .secondary : .primary)
                }
                Button("Manage Account…", action: onManageAccount)
            }
        }
    }

    private var handle: String? {
        inferenceStore.ironsmithAccountSummary?.profile?.handle
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
}
