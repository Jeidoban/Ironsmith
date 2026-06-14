import AuthenticationServices
import SwiftUI

struct IronsmithWelcomeOnboardingSheetView: View {
    @Environment(InferenceStore.self) private var inferenceStore
    @Environment(IronsmithRouteStore.self) private var routeStore
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    let onComplete: () -> Void
    @State private var isSigningIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Welcome to Ironsmith!")
                    .font(.title.weight(.semibold))

                Text("Start creating apps with one of the options below")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            optionList

            HStack {
                Button("Skip Setup") {
                    onComplete()
                }
                .buttonStyle(.link)
                .disabled(isSigningIn)

                Spacer()
            }
        }
        .padding(24)
        .frame(width: 420)
        .alert(
            "Sign In Failed",
            isPresented: errorAlertBinding
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(inferenceStore.presentedErrorMessage ?? "")
        }
    }

    private var optionList: some View {
        VStack(spacing: 0) {
            setupOptionRow(
                title: "Create with local AI models",
                subtitle: "Make apps entirely on device with Ollama.",
                action: {
                    completeWithProvider(.ollama)
                },
                icon: {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 28, weight: .medium))
                }
            )

            optionDivider

            setupOptionRow(
                title: "Create with ChatGPT, Claude, Gemini and more",
                subtitle:
                    "Sign into Ironsmith and make better apps with the latest and greatest AI models.",
                action: signInWithAppleOAuth,
                showsProgress: isSigningIn,
                icon: {
                    Image("ProviderLogoIronsmith")
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .frame(width: 40, height: 40)
                }
            )

            optionDivider

            setupOptionRow(
                title: "Add your own API key",
                subtitle:
                    "Bring your own API key and create with ChatGPT, Claude and Gemini directly.",
                action: {
                    completeWithProvider(.openAI)
                },
                icon: {
                    Image(systemName: "key")
                        .font(.system(size: 28, weight: .medium))
                }
            )
        }
    }

    private func setupOptionRow<Icon: View>(
        title: String,
        subtitle: String,
        action: @escaping () -> Void,
        showsProgress: Bool = false,
        @ViewBuilder icon: @escaping () -> Icon
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                icon()
                    .frame(width: 42, height: 42)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Signing in")
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSigningIn)
    }

    private var optionDivider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.2))
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    private func completeWithProvider(_ providerKind: ProviderKind) {
        onComplete()
        routeStore.open(.settings(.addProvider(initialKind: providerKind)))
    }

    private func signInWithAppleOAuth() {
        guard !isSigningIn else { return }
        isSigningIn = true

        Task {
            let didSignIn = await inferenceStore.signInToIronsmithWithAppleOAuth { @MainActor url in
                try await webAuthenticationSession.authenticate(
                    using: url,
                    callbackURLScheme: IronsmithOAuthRedirect.appCallbackScheme
                )
            }

            await MainActor.run {
                isSigningIn = false
                guard didSignIn else { return }
                inferenceStore.selectIronsmithModel(
                    identifier: InferenceStore.onboardingPreferredIronsmithModelIdentifier
                )
                onComplete()
            }
        }
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { inferenceStore.presentedErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    inferenceStore.clearPresentedError()
                }
            }
        )
    }
}

#Preview("Welcome Onboarding") {
    IronsmithWelcomeOnboardingSheetView(onComplete: {})
        .environment(InferenceStore())
        .environment(IronsmithRouteStore(openSettingsWindow: {}))
}
