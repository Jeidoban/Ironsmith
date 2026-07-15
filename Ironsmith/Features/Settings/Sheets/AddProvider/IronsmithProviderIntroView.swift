import SwiftUI

struct IronsmithProviderIntroView: View {
    let isSigningIn: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .center, spacing: 24) {
            VStack(alignment: .center, spacing: 10) {
                Text("Create the Best Apps")
                    .font(.title.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text(
                    "Add Ironsmith as a provider to support the project and access ChatGPT, Claude, Gemini and more. "
                        + "New users get 20 free credits to get started."
                )
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 520)

            HStack(spacing: 10) {
                providerBadge(kind: .openAI, title: "OpenAI")
                providerBadge(kind: .anthropic, title: "Anthropic")
                providerBadge(kind: .gemini, title: "Gemini")
            }

            Spacer(minLength: 0)

            VStack(alignment: .center, spacing: 10) {
                if isSigningIn {
                    signingInStatus
                }

                IronsmithAppleSignInButton(
                    isSigningIn: isSigningIn,
                    action: action
                )

                Text("Sign in above to get started.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 8)
    }

    private var signingInStatus: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Signing in")
            Text("Signing In")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private func providerBadge(kind: ProviderKind, title: String) -> some View {
        HStack(spacing: 8) {
            ProviderLogoView(kind: kind, size: 26)
            Text(title)
                .font(.subheadline.weight(.medium))
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(.quaternary.opacity(0.36), in: RoundedRectangle(cornerRadius: 8))
    }
}
